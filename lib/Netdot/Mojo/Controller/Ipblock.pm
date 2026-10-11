package Netdot::Mojo::Controller::Ipblock;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Model::Interface;
use Netdot::Model::PhysAddr;
use Netdot::UI;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;
use NetAddr::IP;

# Detail page for an IP block: hierarchical navigation, view-format
# (list | block | tree), section tabs, and the individual-address view.
# (Dedicated controller: the only browsable type with custom detail logic.)
sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Ipblock->retrieve($id) };
    return $c->reply->not_found unless $o;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    # In-place edit form: scalar + FK "soft" fields only. Identity fields
    # (address / prefix / version / parent) are EXCLUDED — editing them in place
    # would break the block hierarchy (a network/prefix change needs a REBLOCK, a
    # distinct not-yet-migrated operation; see TODO).
    my $can_edit = $c->perm( 'edit', $o );
    my $fields   = [];
    my $api_path = '';
    if ($can_edit) {
        my %identity = ( address => 1, prefix => 1, version => 1, parent => 1 );
        my @f = grep { !$identity{ $_->{name} } }
                @{ Netdot::Mojo::Detail::build_edit_fields( $o, 'Ipblock' ) };
        # Restrict the `status` field to the values valid for this block type
        # (Model::Ipblock::_validate): an address -> Static / Dynamic / Discovered /
        # Reserved (Dynamic only under a Subnet parent that has DHCP); a Subnet or
        # Container -> Subnet / Container / Reserved. "Available" is a deletion /
        # free-space indication, not a manual option. The model's update() re-checks
        # these rules, so the API also rejects an invalid status change.
        my $is_addr = eval { $o->is_address } ? 1 : 0;
        my @allowed = $is_addr ? qw(Static Discovered Reserved)
                               : qw(Subnet Container Reserved);
        if ($is_addr) {
            my $parent = eval { $o->parent };
            my $pname  = eval { $parent && $parent->status && $parent->status->name } // '';
            my $dhcp   = eval { $parent && $parent->dhcp_scopes } ? 1 : 0;
            push @allowed, 'Dynamic' if ( $pname eq 'Subnet' && $dhcp );
        }
        # Keep the current status selectable even if it is not in the editable set
        # (e.g. an address currently "Available"), so the <select> is never empty.
        my $cur_st = eval { $o->status && $o->status->name } // '';
        push @allowed, $cur_st if ( $cur_st && !grep { $_ eq $cur_st } @allowed );
        my %ok = map { $_ => 1 } @allowed;
        for my $e (@f) {
            next unless $e->{name} eq 'status' && $e->{kind} eq 'fk'
                  && ref $e->{options} eq 'ARRAY';
            $e->{options} = [ grep { $ok{ $_->{label} } } @{ $e->{options} } ];
        }
        $fields   = \@f;
        $api_path = $c->web_prefix . '/api/ipblock/' . $id;
    }

    # An individual address (/32 or /128) has no children: show its
        # attributes and DNS records instead of the block views.
        if ( eval { $o->is_address } ) {
            my @ancs   = $o->get_ancestors;
            my @crumbs = ( { label => 'Roots', id => 0 } );
            push @crumbs, map { { label => $_->get_label, id => $_->id } } ( reverse @ancs );

            my $stname = eval { $o->status->name } // '';
            my @attrs;
            push @attrs, [ 'Address',      $o->address // '' ];
            push @attrs, [ 'Status',       "<strong>$stname</strong>" ];
            push @attrs, [ 'Description',  eval { $o->description } // '' ];
            push @attrs, [ 'First Seen',   eval { $o->first_seen }  // '' ];
            push @attrs, [ 'Last Seen',    eval { $o->last_seen }   // '' ];
            push @attrs, [ 'Owner',        _fk_link( eval { $o->owner } ) ];
            push @attrs, [ 'Used by',      _fk_link( eval { $o->used_by } ) ];
            push @attrs, [ 'Monitored?',   $o->monitored ? 'Yes' : 'No' ];

            my $iid  = eval { $o->interface->id };
            my $ilbl = eval { $o->interface->get_label };
            push @attrs, [ 'Interface', $iid ? "<a href=\"" . Netdot::Mojo::Registry::set_uri( "/management/interface/$iid" ) . "\">$ilbl</a>" : '' ];

            my $dev = eval { $o->interface && $o->interface->device };
            $dev   ||= eval { ( $o->snmp_devices )[0] };
            my $did = eval { $dev->id };
            push @attrs, [ 'Device', $did ? "<a href=\"" . Netdot::Mojo::Registry::set_uri( "/management/device/$did" ) . "\">" . _obj_label($dev) . "</a>" : '' ];

            # Related objects (read-only; no add/edit links — those need the
            # not-yet-migrated edit interface).
            my @services = _ip_services( $o );
            my @attributes = _ip_attributes( $o );
            my @dhcp   = _ip_dhcp_scopes( $o );
            my @arp    = _ip_last_arp( $o );
            my @audit  = _ip_audit_records( $o );

            # Option lists for the "Add a record" box (below) and the section
            # visibility — mirrors legacy ip.html (ADD_A_RECORD /
            # edit.html?table=RRPTR|IpService|IpblockAttr / VIEW_ADD_DHCP). Only
            # computed when the user may edit; the API re-checks permissions on create.
            #
            # A record: the zone <select> offers the FORWARD (non-arpa) zones the user
            # may edit — a User only their own (the API re-enforces can('edit',$zone) at
            # write time, mirroring Browse#list's "New name" box); an Admin sees all.
            # The default is this IP's forward zone (forward_zone()/dns_zones() already
            # walks up to the nearest ancestor holding a zone), else the first editable.
            # PTR record: the zone is FIXED to this IP's reverse zone (the only one
            # matching its address) — rendered read-only, hidden from the submit.
            my ( @a_zones, $a_def_id, $ptr_zone, @services_list, @contactlists_list, @attr_names_list );
            my $dhcp_add = { enabled => 0, container => 0 };
            if ( $can_edit ) {
                # CDBI list-context: assign INSIDE the eval (the `eval {...} || ()`
                # trap degrades wantarray -> retrieve_all yields an iterator).
                my @zones;
                eval { @zones = sort { $a->name cmp $b->name } Zone->retrieve_all };
                @zones = () if $@;
                # Forward zones the user may edit (a User only their own; Admin all).
                my %zone_edit;
                my $person = $c->current_person;
                if ( defined $person && Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
                    my $access = Netdot::Mojo::Permissions->allowed_objects( $person );
                    %zone_edit = map { $_ => 1 } grep {
                        my $a = $access->{Zone}{$_};
                        ref $a && !exists $a->{none} && exists $a->{edit};
                    } keys %{ $access->{Zone} || {} };
                }
                my @fwd_zones = grep { !$_->is_dot_arpa } @zones;
                @fwd_zones = grep { $zone_edit{ $_->id } } @fwd_zones if keys %zone_edit;
                push @a_zones, map { { id => $_->id, name => $_->get_label } } @fwd_zones;
                # Default = this IP's forward zone (or nearest ancestor's) if it is
                # editable; else the first editable forward zone.
                my $fwd = eval { $o->forward_zone };
                for my $z (@a_zones) { $a_def_id = $z->{id}, last if $fwd && $z->{id} == $fwd->id; }
                $a_def_id = $a_zones[0]{id} unless $a_def_id;
                # PTR: fixed to this IP's reverse zone (none -> not offered).
                $ptr_zone = eval { $o->reverse_zone };
                $ptr_zone = undef unless $ptr_zone && $ptr_zone->id;
                my @svcs; eval { @svcs = Service->retrieve_all }; @svcs = () if $@;
                push @services_list, map { { id => $_->id, name => $_->name } } @svcs;
                my @cls; eval { @cls = ContactList->retrieve_all }; @cls = () if $@;
                push @contactlists_list, map { { id => $_->id, name => $_->name } } @cls;
                my @ans; eval { @ans = IpblockAttrName->retrieve_all }; @ans = () if $@;
                push @attr_names_list, map { { id => $_->id, name => $_->name } } @ans;
                my $parent = eval { $o->parent };
                my @pscopes;
                eval { @pscopes = $parent->dhcp_scopes };
                @pscopes = () if $@;
                if ( @pscopes ) {
                    my $cont = eval { $pscopes[0]->container };
                    $dhcp_add = { enabled => 1, container => eval { $cont->id } || 0 };
                }
            }

            # "Add a record" box (RR-page style): one pre-rendered form per type,
            # revealed by a type <select> and submitted via initForms (collect + POST).
            # Mirrors legacy ip.html (ADD_A_RECORD / edit.html?table=RRPTR|IpService|
            # IpblockAttr / VIEW_ADD_DHCP). Each entry follows the _rel_add_fields shape:
            # { type => <api resource>, label, add => { hidden => {hash}, fields => [...] } }.
            # Select/hidden ids are marked data-nd-int in the template; collect() coerces
            # purely-numeric values to integers (FK ids) while names/addresses stay strings.
            my @a_opt   = map { [ $_->{id}, $_->{name} ] } @a_zones;
            my @svc_opt = map { [ $_->{id}, $_->{name} ] } @services_list;
            my @cl_opt  = map { [ $_->{id}, $_->{name} ] } @contactlists_list;
            my @att_opt = map { [ $_->{id}, $_->{name} ] } @attr_names_list;
            my @add_types;
            push @add_types, {
                type  => 'rr',
                label => 'DNS A Record',
                add   => {
                    hidden => { type => 'A', ipblock => $o->id },
                    fields => [
                        { tag => 'Name', kind => 'text',   name => 'name', value => '' },
                        { tag => 'Zone', kind => 'select', name => 'zone', value => $a_def_id, options => \@a_opt },
                    ],
                },
            } if @a_opt;
            if ( $ptr_zone ) {
                push @add_types, {
                    type  => 'rrptr',
                    label => 'DNS PTR Record',
                    add   => {
                        hidden => { ipblock => $o->id, zone => $ptr_zone->id },
                        fields => [
                            { tag => 'Zone',       kind => 'readonly', value => $ptr_zone->get_label },
                            { tag => 'PTR target', kind => 'text',     name => 'ptrdname', value => '' },
                        ],
                    },
                };
            }
            push @add_types, {
                type  => 'ipservice',
                label => 'Service',
                add   => {
                    hidden => { ip => $o->id },
                    fields => [
                        { tag => 'Service',      kind => 'select', name => 'service',     value => '', options => \@svc_opt },
                        { tag => 'Contact list', kind => 'select', name => 'contactlist', value => '', options => \@cl_opt },
                    ],
                },
            } if @svc_opt && @cl_opt;
            push @add_types, {
                type  => 'ipblockattr',
                label => 'Custom Attribute',
                add   => {
                    hidden => { ipblock => $o->id },
                    fields => [
                        { tag => 'Attribute', kind => 'select', name => 'name',  value => '', options => \@att_opt },
                        { tag => 'Value',     kind => 'text',   name => 'value', value => '' },
                    ],
                },
            } if @att_opt;
            if ( $dhcp_add->{enabled} ) {
                my $dfield = ( $o->version == 6 )
                    ? { tag => 'DUID',           kind => 'text', name => 'duid',     value => '' }
                    : { tag => 'Ethernet (MAC)', kind => 'text', name => 'physaddr', value => '' };
                push @add_types, {
                    type  => 'dhcpscope',
                    label => 'DHCP Host',
                    add   => {
                        hidden => { type => 'host', name => $o->address, ipblock => $o->id,
                                    container => $dhcp_add->{container} },
                        fields => [ $dfield ],
                    },
                };
            }

            # Page-level delete (address). An address has no children, so the modal
            # offers no "delete children" choice (nd_children=0). After the delete,
            # go to the parent's page (or the roots list when parentless).
            my $can_delete = $c->perm( 'delete', $o );
            my $parent     = eval { $o->parent };
            my $pid        = eval { $parent && $parent->id };
            my $del_path   = $can_delete ? $c->web_prefix . '/api/ipblock/' . $o->id : '';
            my $del_goto   = $can_delete
                ? Netdot::Mojo::Registry::set_uri( $pid ? '/management/ipblock/' . $pid : '/management/ipblock' )
                : '';

            $c->render(
                template    => 'management/ipaddress',
                layout      => 'default',
                title       => "Ip " . $o->get_label,
                current     => $o,
                can_edit    => $can_edit,
                can_delete  => $can_delete,
                del_path    => $del_path,
                del_goto    => $del_goto,
                nd_children => 0,
                fields      => $fields,
                api_path    => $api_path,
                breadcrumb  => \@crumbs,
                attrs       => \@attrs,
                comments    => ( eval { $o->info } // '' ),
                a_records   => [ _ip_dns_records( $o, 'a_records' ) ],
                ptr_records => [ _ip_dns_records( $o, 'ptr_records' ) ],
                services    => \@services,
                attributes  => \@attributes,
                dhcp        => \@dhcp,
                arp         => \@arp,
                audit       => \@audit,
                ip_version  => $o->version,
                add_types   => \@add_types,
            );
            return;
        }

        my $cfg    = Netdot->config;
        my $status = eval { $o->status->name } // '';
        my $prefix = $o->prefix;
        my $v4     = ( $o->version == 4 );

        # Section tabs (view=Children|Sites|Zones|DHCP|Attributes|Comments|Audit|All),
        # orthogonal to the children view_format (list|block|tree). Default Children.
        # Access Rights is deferred. DHCP tab only for Subnets (like ip.html).
        my $view = $c->param('view') // '';
        $view = 'Children' unless $view =~ /^(Children|Sites|Zones|DHCP|Attributes|Comments|Audit|All)$/;
        my @tabs = ( [ 'Children', 'Children' ], [ 'Sites', 'Sites' ], [ 'Zones', 'Zones' ] );
        push @tabs, [ 'DHCP', 'DHCP' ] if $status eq 'Subnet';
        push @tabs, [ 'Attributes', 'Attributes' ], [ 'Comments', 'Comments' ],
                     [ 'Audit', 'Audit' ], [ 'All', 'All' ];
        my $show = sub { my $s = shift; $view eq $s || $view eq 'All' ? 1 : 0 };

        # Children display (list/block/tree via view_format), shown on Children & All.
        my ( @blocks, $tree_html, $grid, $container_grid, @modes );
        my $viewtype = 'block';   # set to 'address' only in the Children list view
        my $vfmt     = 'list';
        if ( $show->('Children') ) {
            # View modes available for this block (rules from ip.html):
            #   list always; block and tree for v4 when prefix >= MAX.
            my $max = $status eq 'Subnet' ? $cfg->get('SUBNET_BLOCK_VIEW_MAX_PREFIX')
                      : ( $status eq 'Container' ? $cfg->get('CONTAINER_BLOCK_VIEW_MAX_PREFIX') : undef );
            @modes = ( 'list' );
            if ( $v4 && $max && $prefix >= $max ) {
                push @modes, 'block';
                # The tree view shows the block hierarchy (get_descendants, no addresses);
                # a Subnet's children are individual addresses, so a tree is meaningless —
                # only Containers get the tree mode.
                push @modes, 'tree' unless $status eq 'Subnet';
            }

            # Effective view_format: requested (sanitized), defaulting to the config
            # value, forced to an available mode (v6 / too-large -> list).
            my $f = $c->param('view_format');
            $f = $cfg->get('DEFAULT_IPBLOCK_VIEW') || 'block' unless $f;
            $f = 'list' unless $f =~ /^(list|block|tree)$/;
            $f = 'list' unless grep { $_ eq $f } @modes;
            $vfmt = $f;

            if ( $vfmt eq 'list' ) {
                if ( $status eq 'Subnet' ) {
                    @blocks   = $o->get_addresses_by('Address');   # individual addresses
                    $viewtype = @blocks ? 'address' : 'block';
                } else {
                    @blocks   = _ipblock_children( $o );            # contained IP blocks
                    $viewtype = @blocks && eval { $blocks[0]->is_address } ? 'address' : 'block';
                }
            } elsif ( $vfmt eq 'tree' ) {
                $viewtype  = 'block';
                my $ref    = eval { $o->get_descendants( no_addresses => 1 ) };
                my $ui     = eval { Netdot::UI->new() };
                $tree_html = ( $ui && $ref ) ? eval { $ui->build_ip_tree_graph_html( id => $o->id, list => $ref, web_path => $c->web_root ) } : undef;
            } else {  # block view
                $viewtype = 'block';
                if ( $status eq 'Subnet' ) {
                    $grid = _build_subnet_grid( $o );               # the address grid
                } else {
                    # Container: the proportional usage visualization (port of container.mhtml).
                    # Free-partition cells carry data-nd-create so clicking one opens the
                    # "create block" modal (Mason ADD_BLOCK).
                    $container_grid = _build_container_grid_html(
                        $o,
                        rowsize => $c->param('rowsize'),
                        divide  => $c->param('dividefreespace'),
                    );
                }
            }
        }

        my @ancs   = $o->get_ancestors;
        my @crumbs = ( { label => 'Roots', id => 0 } );
        push @crumbs, map { { label => $_->get_label, id => $_->id } } ( reverse @ancs );
        my $devs   = $viewtype eq 'address' ? ( eval { Device->get_ips_from_all() } || {} ) : undef;

        # DNS names for the address LIST view ("Name" column). ONE query to rraddr
        # (like legacy subnet.mhtml) maps each child address -> all its A-record
        # names, each linked to its RR object, joined by ", ". (The template used
        # to call $o->a_records per row: N+1, and `eval { ... } // ()` tripped
        # Class::DBI's scalar-context iterator so the names came out empty.)
        my %dns_name;   # id => html: <a href="/management/rr/<rid>">fqdn</a>, ...
        if ( $viewtype eq 'address' ) {
            my $rows = Netdot::Model->db_Main()->selectall_arrayref(
                q{ SELECT i.id, rr.id AS rid, CONCAT( rr.name, '.', z.name ) AS name
                   FROM   rraddr ra
                   JOIN   rr      ON ra.rr = rr.id
                   JOIN   zone    z ON rr.zone = z.id
                   JOIN   ipblock i ON ra.ipblock = i.id
                   WHERE  i.parent = ? },
                { Slice => {} }, $o->id );
            my %links;
            push @{ $links{ $_->{id} } },
                '<a href="' . Netdot::Mojo::Registry::set_uri( '/management/rr/' . $_->{rid} ) . '">'
                . _esc( $_->{name} ) . '</a>'
                for @$rows;
            $dns_name{ $_ } = join( ', ', @{ $links{$_} } ) for keys %links;
        }

        # Per-tab section data (gathered lazily, only for the active view).
        # fzones/rzones are arrayrefs (forward / reverse zones, kept separate).
        my ( @sites, $fzones, $rzones, @dhcp, @attributes, @audit, $comments );
        @sites      = _block_sites( $o )      if $show->('Sites');
        ( $fzones, $rzones ) = _block_zones( $o ) if $show->('Zones');
        $fzones ||= [];
        $rzones ||= [];
        @dhcp       = _ip_dhcp_scopes( $o )   if $show->('DHCP');
        @attributes = _ip_attributes( $o )    if $show->('Attributes');
        $comments   = eval { $o->info } // '' if $show->('Comments');
        @audit      = _ip_audit_records( $o ) if $show->('Audit');

        my @block_attrs = _block_attributes( $o );

        # Page-level delete (Mason ip.html:442-481): shown when the user may delete
        # this block. The JSON API threads `recursive` (default off): when set, the
        # block AND all its children are removed; otherwise _tree_delete() re-attaches
        # the children to this block's parent. The children-count is passed to the UI
        # so it offers the "also delete children?" choice only when children exist.
        my $can_delete = $c->perm( 'delete', $o );
        my @children   = $can_delete ? _ipblock_children( $o ) : ();
        my $parent     = eval { $o->parent };
        my $pid        = eval { $parent && $parent->id };
        my $del_path   = $can_delete ? $c->web_prefix . '/api/ipblock/' . $id : '';
        my $del_goto   = $can_delete
            ? Netdot::Mojo::Registry::set_uri( $pid ? '/management/ipblock/' . $pid : '/management/ipblock' )
            : '';

        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => "Ipblock " . $o->get_label,
            view       => $view,
            tabs       => \@tabs,
            block_attrs => \@block_attrs,
            can_delete => $can_delete,
            del_path   => $del_path,
            del_goto   => $del_goto,
            nd_children => scalar @children,
            viewtype   => $viewtype,
            viewformat => $vfmt,
            modes      => \@modes,
            tree_html  => $tree_html,
            grid       => $grid,
            container_grid => $container_grid,
            blocks     => \@blocks,
            current    => $o,
            can_edit   => $can_edit,
            fields     => $fields,
            api_path   => $api_path,
            breadcrumb => \@crumbs,
            devs       => $devs,
            dns_name   => \%dns_name,
            sites      => \@sites,
            fzones     => $fzones,
            rzones     => $rzones,
            dhcp       => \@dhcp,
            attributes => \@attributes,
            comments   => $comments,
            audit      => \@audit,
        );
        return;
}

# Address Space search (port of address_tasks.html "search"). Three criteria:
#   - IP[/prefix]: exact lookup; if not found, offer the closest covering block.
#   - IP regex:    regular-expression match on the address (Ipblock->search_like).
#   - Keywords:    text match across description, info, related sites/entities.
sub search ($c) {
    my $sa = _trim( $c->param('search_address') );
    my $sr = $c->param('search_regex');
    my $so = _trim( $c->param('search_other') );

    my $search;
    my @list;
    my $covering;
    my $error;

    if ( $sa ) {
        $search = $sa;
        my $it = eval { Ipblock->search( address => $sa ) };
        if ( my $e = $@ ) {
            $error = $e;
        }
        else {
            @list = _ipblock_list( $it );
            $covering = eval { Ipblock->get_covering_block( address => $sa ) } if ! @list;
        }
    }
    elsif ( defined $sr && $sr ne '' ) {
        ( my $pat = $sr ) =~ s/\s+//g;
        eval { qr/$pat/i; 1 };
        if ( my $e = $@ ) {
            $error = "Your regular expression doesn't seem valid: $e";
        }
        else {
            $search = $sr;
            eval { @list = Ipblock->search_like( address => $pat ); 1 };
            $error = $@ if $@;
        }
    }
    elsif ( $so ) {
        $search = $so;
        eval { @list = Ipblock->keyword_search( $so ); 1 };
        $error = $@ if $@;
    }
    else {
        return $c->redirect_to( $c->url_for( 'ipblock_list' ) );
    }

    if ( $error ) {
        $c->render(
            template   => 'management/search_results',
            layout     => 'default',
            title      => 'Address Space Search',
            search     => $search // '',
            error      => $error,
            headers    => [],
            rows       => [],
            search_url => $c->url_for( 'ipblock_search' ),
        );
        return;
    }

    my @headers = map { Netdot::Mojo::Registry::column_tag( 'Ipblock', $_ ) }
                  qw(address prefix status used_by);
    my @rows = map {
        { href  => Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $_->id ),
          label => $_->cidr // '',
          cells => [ $_->prefix // '',
                     Netdot::Mojo::Registry::format_value( $_->status ),
                     Netdot::Mojo::Registry::format_value( $_->used_by ) ] }
    } @list;

    $c->render(
        template   => 'management/search_results',
        layout     => 'default',
        title      => 'Address Space Search',
        search     => $search,
        headers    => \@headers,
        rows       => \@rows,
        covering   => $covering ? { id => $covering->id, label => $covering->cidr } : undef,
        search_url => $c->url_for( 'ipblock_search' ),
    );
}

# Slurp a CDBI search iterator into a plain list (->search returns a
# Class::DBI::Iterator; calling it in scalar context then dereferencing loses
# wantarray, so iterate explicitly).
sub _ipblock_list {
    my ($it) = @_;
    return () unless $it && ref $it;
    if ( $it->isa( 'Class::DBI::Iterator' ) ) {
        my @out;
        while ( my $o = $it->next ) { push @out, $o; }
        return @out;
    }
    return @$it;
}

# Trim leading/trailing whitespace.
sub _trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

# The block's own attribute table (port of ip.html's block attribute_table), as a
# list of [label, value_html] rows. Read-only; the [edit] links are deferred with
# the write functionality. Handles Subnet vs Container conditionals and renders
# the utilization progress bars.
sub _block_attributes {
    my ($o) = @_;
    my @rows;
    my $status = $o->status ? $o->status->name : '';
    my $v4     = $o->version == 4;
    my $maxips = Netdot->config->get('SHOW_COUNT_THRESHOLD') || 65536;
    my $ui     = Netdot::UI->new;
    my $T      = sub { Netdot::Mojo::Registry::column_tag( 'Ipblock', $_[0] ) };

    push @rows, [ $T->('address'), _esc( $o->address . '/' . $o->prefix ) ];
    push @rows, [ $T->('status'), "<strong>" . _esc($status) . "</strong>" ] if length $status;
    push @rows, [ $T->('description'), _esc($o->description) ]
        if defined $o->description && length $o->description;
    push @rows, [ $T->('use_network_broadcast'), $o->use_network_broadcast ? 'Yes' : 'No' ]
        if $status eq 'Subnet';
    push @rows, [ $T->('first_seen'), _esc($o->first_seen) ]
        if defined $o->first_seen && length $o->first_seen;
    push @rows, [ $T->('last_seen'), _esc($o->last_seen) ]
        if defined $o->last_seen && length $o->last_seen;
    push @rows, [ $T->('vlan'), _fk_link( $o->vlan ) ]
        if $status eq 'Subnet' && $o->vlan;
    if ( $status eq 'Container' ) {
        push @rows, [ $T->('rir'), _esc($o->rir) ] if defined $o->rir && length $o->rir;
        push @rows, [ $T->('asn'), _fk_link( $o->asn ) ] if $o->asn;
    }
    for my $col ( qw(owner used_by) ) {
        my $ent = $o->$col;
        push @rows, [ $T->($col), _fk_link($ent) ] if $ent;
    }

    # Netmask / broadcast + usable address range (NetAddr::IP, like ip.html).
    my $ip = NetAddr::IP->new( $o->address, $o->prefix );
    push @rows, [ 'Netmask', $v4 ? _esc( $ip->mask ) : ( '/' . $o->prefix ) ];
    push @rows, [ 'Broadcast', $v4 ? _esc( $ip->broadcast->addr ) : 'n/a' ];
    my ( $num, $first, $last );
    if ( $v4 ) {
        if ( $o->prefix == 31 ) {
            ( $num, $first, $last ) = ( 2, $ip->addr, $ip->broadcast->addr );
        }
        else {
            ( $num, $first, $last ) = ( $o->num_addr, $ip->first->addr, $ip->last->addr );
        }
    }
    else {
        ( $num, $first, $last ) = ( $o->num_addr, $ip->network->canon, $ip->broadcast->canon );
    }
    push @rows, [ 'Usable Addresses', "$num ($first - $last)" ];

    if ( $status eq 'Subnet' ) {
        my $used  = $o->address_usage;
        my $total = $o->num_addr;
        my $avail = $total - $used;
        my $percent = $total ? ( $used * 100 / $total ) : 0;
        my $text = "Used: $used";
        $text .= " of $total" if $total <= $maxips;
        $text .= "   Available: ";
        $text .= "$avail (" if $avail <= $maxips;
        $text .= $ui->friendly_percent( value => $avail, total => $total );
        $text .= ")" if $avail <= $maxips;
        push @rows, [ 'Utilization', $ui->percent_bar( percent => $percent )
            . qq{<div class="small">$text</div>} ];
    }
    elsif ( $status eq 'Container' ) {
        my $total  = $o->num_addr;
        my $used_a = $o->address_usage;
        my $avail_a = $total - $used_a;
        my $used_s = $o->subnet_usage;
        my $avail_s = $total - $used_s;
        my $address_percent = $total ? ( $used_a * 100 / $total ) : 0;
        my $subnet_percent  = $total ? ( $used_s * 100 / $total ) : 0;

        my $a_text;
        if ( $used_a <= $maxips ) {
            $a_text = "Used: $used_a";
            $a_text .= " of $total" if $total <= $maxips;
            $a_text .= "   Available: ";
            $a_text .= "$avail_a (" if $total <= $maxips;
            $a_text .= $ui->friendly_percent( value => $avail_a, total => $total );
            $a_text .= ")" if $total <= $maxips;
        }
        else {
            $a_text = $avail_a <= $maxips
                ? "Available: $avail_a (" . ( 100 - $address_percent ) . "%)"
                : "Available: " . ( 100 - $address_percent ) . "%";
        }
        push @rows, [ 'Address Utilization', $ui->percent_bar( percent => $address_percent )
            . qq{<div class="small">$a_text</div>} ];

        my $s_text = "Available: " . $ui->friendly_percent( value => $avail_s, total => $total );
        push @rows, [ 'Space Allocated', $ui->percent_bar( percent => $subnet_percent )
            . qq{<div class="small">$s_text</div>} ];
    }

    return @rows;
}

# Direct children of an ipblock. ->children returns a Class::DBI::Iterator, so it
# must be iterated (a plain list assignment via eval() degrades to the iterator).
sub _ipblock_children {
    my ($o) = @_;
    my @kids;
    my $it = eval { $o->children };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $k = $it->next ) {
            push @kids, $k;
        }
    }
    return @kids;
}

# Block view for a Container: a proportional usage visualization. Faithful port of
# container.mhtml: one row holds one /rowsize of the container, and contained blocks
# and free partitions are drawn to scale (a /23 is exactly 2x a /24) using the
# original integer-width scheme (a /32 is the base unit, so every block width is an
# integer number of pixels). Cells flow left-to-right and wrap at $cellsperrow px.
# IPv6 is not supported (the original template aborts for v6); the "add block" and
# "create blocks from free space" write actions are omitted (edit interface not
# yet migrated), so free-space cells carry no link. Returns HTML.
sub _build_container_grid_html {
    my ( $o, %opt ) = @_;
    my $rowsize = $opt{rowsize} || ( Netdot->config->get('DEFAULT_IPBLOCK_ROWSIZE') || 22 );
    my $divide  = $opt{divide}  || 'max';

    my $mask = $o->prefix;
    my $v4   = ( $o->version == 4 );
    return '<div style="padding:1em">This view cannot currently handle IPv6 blocks.</div>'
        unless $v4;

    # set the visual size of the table on the screen (from container.mhtml)
    $rowsize = int( $rowsize );
    $rowsize = 32 if ( $rowsize > 32 );
    $rowsize = ( $rowsize > $mask ) ? $rowsize : $mask;    # never more /32s per row than the block has
    my $cellsperrow = ( $rowsize >= 22 ) ? 1024 : 2 ** ( 32 - $rowsize );

    my @children  = sort { $a->address_numeric <=> $b->address_numeric } _ipblock_children( $o );
    my @freespace = $opt{freespace} ? @{ $opt{freespace} }
                    : sort { $a->numeric <=> $b->numeric } $o->free_space( $divide );

    my $base_url = Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $o->id . '?view_format=block' );
    my $html     = '';
    $html .= '<table style="width:100%"><tr>';
    $html .= '<td style="text-align:right;vertical-align:middle">Zoom: Set one row equal to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=\'+this.options[this.selectedIndex].value+\'&dividefreespace=' . $divide . '\'">';
    for my $i ( $mask .. 32 ) {
        $html .= '<option value="' . $i . '"' . ( $rowsize == $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td>';
    $html .= '<td style="text-align:right;vertical-align:middle">Partition: Set max free space size to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=' . $rowsize . '&dividefreespace=\'+this.options[this.selectedIndex].value">';
    $html .= '<option value="max"' . ( $divide eq 'max' ? ' selected' : '' ) . '>unlimited</option>';
    for my $i ( $mask .. 32 ) {
        $html .= '<option value="' . $i . '"' . ( $divide eq $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td></tr></table>';

    $html .= '<div class="tablescroll">';
    $html .= '<table class="ipcontainertable" style="width:' . ( $cellsperrow + 100 ) . 'px" cellpadding="0" cellspacing="0"><tr class="outerrow"><td><table cellpadding="0" cellspacing="0" border="0">';

    my $count     = 0;
    my $prevclass = '';
    my $needtr    = 1;
    while ( @children || @freespace ) {
        my ( $class, $rowtitle, $title, $width, $link, $data );
        if ( ! @children || ( @freespace && $freespace[0]->numeric < $children[0]->address_numeric ) ) {
            my $child = shift @freespace;
            $class = 'ipaddr_available';
            $class .= '_2' if $prevclass eq $class;
            $rowtitle = $child->addr;
            $title    = $child;
            $link     = '#';
            # Clicking a free partition opens the "create block" modal (Mason ADD_BLOCK);
            # the cell carries the partition CIDR. The API auto-attaches the new block
            # to the smallest containing parent, so no parent id is posted.
            $data     = 'data-nd-create="' . $child->addr . '/' . $child->masklen . '"';
            $width = ( $rowsize >= 22 ) ? ( 2 ** ( 32 - $child->masklen ) ) * ( 2 ** ( $rowsize - 22 ) ) : 2 ** ( 32 - $child->masklen );
            $count += $width;
            $prevclass = $class;
        }
        elsif ( ! @freespace || $freespace[0]->numeric > $children[0]->address_numeric ) {
            my $child  = shift @children;
            my $status = $child->status->name;
            $class = 'ipaddr_' . lc( $status );
            $class .= '_2' if $prevclass eq $class;
            $rowtitle = $child->address;
            $title    = $child->cidr;
            $title   .= ' (' . $child->description . ')' if $child->description;
            $width = ( $rowsize >= 22 ) ? ( 2 ** ( 32 - $child->prefix ) ) * ( 2 ** ( $rowsize - 22 ) ) : 2 ** ( 32 - $child->prefix );
            $count += $width;
            $link      = Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $child->id );
            $data      = '';
            $prevclass = $class;
        }
        else {
            last;    # inconsistent state; stop rather than loop forever
        }

        if ( $needtr ) {
            $needtr = 0;
            $html .= '<tr class="outerrow"><td width="100">' . _esc( $rowtitle ) . '</td><td><table cellpadding="0" cellspacing="0"><tr>';
        }

        # one cell of $width px; a block wider than a row is drawn as a taller cell
        if ( $width > $cellsperrow ) {
            my $height = $width / $cellsperrow * 15;
            $html .= '<td title="' . _esc( $title ) . '"><a href="' . $link . '" class="' . $class
                   . '" ' . $data . ' style="display:block;width:' . $cellsperrow . 'px;border:0;height:' . $height . 'px"><table>';
            for ( my $i = 0; $i < $width / $cellsperrow; $i++ ) {
                $html .= '<tr><td></td></tr>';
            }
            $html .= '</table></a></td>';
        }
        else {
            $html .= '<td title="' . _esc( $title ) . '"><a href="' . $link . '" class="' . $class
                   . '" ' . $data . ' style="display:block;width:' . $width . 'px;border:0;height:15px"></a></td>';
        }

        if ( $count >= $cellsperrow ) {
            $needtr = 1;
            $count  = 0;
            $html .= '</tr></table></td></tr>';
        }
    }
    $html .= '</tr></table></td></tr></table>';
    $html .= '</div>';
    return $html;
}

# Block view for a Subnet: a grid of every individual address (port of subnet.mhtml).
# Returns an arrayref of rows, each row an arrayref of ready-to-print HTML cell strings.
sub _build_subnet_grid {
    my ($o) = @_;

    my %classes = (
        Static => 'ipaddr_static', Dynamic => 'ipaddr_dynamic', Reserved => 'ipaddr_reserved',
        Container => 'ipaddr_container', Discovered => 'ipaddr_discovered', Available => 'ipaddr_available',
    );

    # Used addresses in this subnet (id, numeric address, description, status, dns, device).
    my $id  = $o->id;
    # "Dynamic" is a valid status for a new address only if this (Subnet) parent has DHCP
    # scopes (Model::Ipblock::_validate). The create modal offers it when this is true.
    my $has_dhcp = eval { $o->dhcp_scopes } ? 1 : 0;
    my $dbh = Netdot::Model->db_Main();
    my $q   = "SELECT ipblock.id, ipblock.address, ipblock.description, ipblockstatus.name, rr.name, device.id
               FROM ipblockstatus, ipblock
               LEFT JOIN (rr CROSS JOIN rraddr) ON (ipblock.id = rraddr.ipblock AND rraddr.rr = rr.id)
               LEFT JOIN (device CROSS JOIN interface) ON (ipblock.interface = interface.id AND interface.device = device.id)
               WHERE ipblock.parent = $id AND ipblock.status = ipblockstatus.id
               ORDER BY ipblock.address";
    my $results = $dbh->selectall_arrayref($q);
    my ( %used, %names, %status, %ids );
    for my $r ( @$results ) {
        my ( $ipid, $address, $description, $st, $dnsname, $device ) = @$r;
        $used{ $address }   = 1;
        $names{ $address }  = $st;
        if ( $st eq 'Static' ) {
            $names{ $address } = $dnsname if $dnsname;
        } elsif ( $device ) {
            my $lbl = eval { Device->retrieve($device)->get_label };
            $names{ $address } = $lbl if $lbl;
        }
        $names{ $address } = $description if ( $st ne 'Static' && $description );
        $status{ $address } = $st;
        $ids{ $address }    = $ipid;
    }

    my $net   = $o->netaddr->network;
    my $mask  = $net->masklen;
    my $bits  = ( $o->version == 4 ) ? 32 : 128;
    my $total = 2 ** ( $bits - $mask );
    my $cols  = ( $total < 16 ) ? $total : 16;
    my $rows  = int( $total / $cols );

    my @out;
    for ( my $i = 0; $i < $rows; $i++ ) {
        my @row;
        for ( my $j = 0; $j < $cols; $j++ ) {
            my $disp     = $net->addr;
            my $stn      = $status{ $net->numeric } // '';
            my $divclass = $classes{ $stn } || 'ipaddr_available';
            my $divtitle = $names{ $net->numeric } || $net->addr;
            # Hide the insignificant (network) octets for v4.
            if ( $o->version == 4 ) {
                $disp =~ s/^\d+\.\d+\.\d+\.(\d+)$/$1/o if $mask >= 24;
                $disp =~ s/^\d+\.\d+\.(\d+\.\d+)$/$1/o    if $mask >= 16 && $mask < 24;
                $disp =~ s/^\d+\.(\d+\.\d+\.\d+)$/$1/o    if $mask >= 8  && $mask < 16;
            }
            my $cell;
            if ( $mask != 31 && $net->numeric == $net->network->numeric && !$o->use_network_broadcast ) {
                $cell = qq{<div class="ipaddr_disabled" title="Network">$disp</div>};
            } elsif ( $mask != 31 && $net->numeric == $net->broadcast->numeric && !$o->use_network_broadcast ) {
                $cell = qq{<div class="ipaddr_disabled" title="Broadcast">$disp</div>};
            } else {
                my $inner = qq{<div class="$divclass" title="$divtitle" width="100%">$disp</div>};
                my $aid   = $ids{ $net->numeric };
                if ( exists $used{ $net->numeric } && $aid ) {
                    $cell = qq{<a href="} . Netdot::Mojo::Registry::set_uri( "/management/ipblock/$aid" ) . qq{" class="ipaddr">$inner</a>};
                } else {
                    # Unassigned address: clickable to create it (Mason ADD_BLOCK for an IP).
                    # The cell carries the /32 (or /128) CIDR; the API auto-attaches it to
                    # this subnet. data-nd-dhcp lets the modal offer the Dynamic status.
                    my $cidr  = $net->addr . '/' . $bits;
                    my $attrs = qq{data-nd-create="$cidr"};
                    $attrs .= ' data-nd-dhcp="1"' if $has_dhcp;
                    $cell = qq{<a class="ipaddr" href="#" $attrs>$inner</a>};
                }
            }
            push @row, $cell;
            $net++;
        }
        push @out, \@row;
    }
    return \@out;
}

# Label of a related object (owner, used_by, device), or '' if empty.
sub _obj_label {
    my ($o) = @_;
    return '' unless $o;
    return eval { $o->get_label } // '';
}

# Minimal HTML escaping for text values emitted from Perl (the template's <%= %>
# auto-escapes, but values built in controllers -- e.g. _block_attributes -- are
# inserted raw and must be escaped explicitly before being marked safe).
sub _esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Display an FK object as a link to its detail page (when a route exists).
# $obj may be undef. An optional display text overrides the object's label
# (e.g. a PhysAddr shown via its config-formatted MAC).
sub _fk_link {
    my ( $obj, %opt ) = @_;
    return '' unless $obj;
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for( $obj ) };
    $text = $opt{text} if defined $opt{text};
    return $href ? "<a href=\"$href\">$text</a>" : $text;
}

# Sites associated with a block (SiteSubnet join -> Site).
sub _block_sites {
    my ($o) = @_;
    my @rel = eval { $o->sites };
    return () if $@;
    my @out;
    for my $ss (@rel) {
        push @out, _fk_link( eval { $ss->site } );   # Site -> /management/site/<id>
    }
    return @out;
}

# Forward + reverse DNS zones of a block. Returns two arrayrefs:
# [forward links], [reverse links] (each zone rendered as a link to /management/zone/<id>).
# Forward: model's forward_zone() (linked zones, in-addr.arpa/ip6.arpa excluded).
# Reverse: every dot-arpa name the block maps to -- a /23 spans two /24s, so there
# can be more than one -- matched against the existing zones.
sub _block_zones {
    my ($o) = @_;
    my @fwd = eval { $o->forward_zone };

    my %all_zones;
    my $it = eval { Zone->retrieve_all };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $z = $it->next ) { $all_zones{ $z->name } = $z; }
    }
    my %reverse_zones;
    my @names = eval { $o->get_dot_arpa_names };
    for my $n (@names) {
        $reverse_zones{ $n } = $all_zones{ $n } if exists $all_zones{ $n };
    }
    my @rev = values %reverse_zones;

    return (
        [ map { _fk_link( $_ ) } @fwd ],
        [ map { _fk_link( $_ ) } @rev ],
    );
}

# DNS records (A or PTR) attached to an address. Each record is wrapped in a
# joiner object; ->rr yields the RR (name), ->rr->zone the owning zone.
sub _ip_dns_records {
    my ( $o, $method ) = @_;
    my @out;
    my @rel = eval { $o->$method };      # list context; no "//()" (it degrades wantarray)
    return @out if $@;
    for my $r (@rel) {
        my $rr   = eval { $r->rr } or next;
        my $name = eval { $rr->name } // '';
        my $zid  = eval { $rr->zone->id };
        my $zl   = eval { $rr->zone->get_label } // '';
        push @out, {
            # name shown as the bare record name, linked to the RR object.
            name_html => _fk_link( $rr, text => $name ),
            zone      => $zl,
            zone_href => $zid ? Netdot::Mojo::Registry::set_uri( "/management/zone/$zid" ) : undef,
        };
    }
    return @out;
}

# Services attached to an address (IpService -> Service, ContactList).
sub _ip_services {
    my ($o) = @_;
    my @out;
    my @rel = eval { $o->services };
    return @out if $@;
    for my $s (@rel) {
        my $svc = eval { $s->service };
        my $cl  = eval { $s->contactlist };
        push @out, {
            service_html => _fk_link( $svc ),   # Service    -> /management/service/<id>
            contact_html => _fk_link( $cl ),    # ContactList -> /management/contactlist/<id>
        };
    }
    return @out;
}

# Custom attributes of an address (IpblockAttr -> IpblockAttrName, value).
sub _ip_attributes {
    my ($o) = @_;
    my @out;
    my @rel = eval { $o->attributes };
    return @out if $@;
    for my $a (@rel) {
        my $nm = eval { $a->name->name } // eval { $a->name->get_label } // '';
        push @out, { name => $nm, value => eval { $a->value } // '' };
    }
    return @out;
}

# DHCP host scopes bound to this address (DhcpScope).
sub _ip_dhcp_scopes {
    my ($o) = @_;
    my @rel = eval { $o->dhcp_scopes };
    return () if $@;
    my @out;
    for my $s (@rel) {
        my $pa  = eval { $s->physaddr };
        my $mac = eval { $pa && $pa->format_address } // '';
        push @out, {
            # type is a FK to DhcpScopeType (enum value, not linked);
            # the scope name links to its DhcpScope detail page;
            # physaddr is a FK to PhysAddr, shown via its config-formatted MAC.
            type          => eval { $s->type->name } // '',
            name_html     => _fk_link( $s ),
            ethernet_html => _fk_link( $pa, text => $mac ),
            duid          => eval { $s->duid }       // '',
            active        => eval { $s->active },
        };
    }
    return @out;
}

# Last ARP entries for this address, grouped by (tstamp, mac).
sub _ip_last_arp {
    my ( $o, $limit ) = @_;
    $limit ||= 10;
    my $arp = eval { $o->get_last_n_arp( $limit ) };
    return () unless $arp && ref( $arp ) eq 'ARRAY';
    my %tstamps;
    for my $row ( @$arp ) {
        my ( $iid, $macid, $tstamp ) = @$row;
        next unless defined $iid;
        my $lbl = eval { Interface->retrieve( $iid )->get_label } // '';
        # Each interface is a link to its detail page.
        push @{ $tstamps{ $tstamp }{ $macid } },
            _fk_link( eval { Interface->retrieve( $iid ) }, text => $lbl );
    }
    my @out;
    for my $tstamp ( reverse sort keys %tstamps ) {
        for my $macid ( sort keys %{ $tstamps{ $tstamp } } ) {
            my $pa  = eval { PhysAddr->retrieve( $macid ) };
            my $mac = eval { $pa && $pa->format_address } // '';
            push @out, {
                tstamp     => $tstamp,
                mac_html   => _fk_link( $pa, text => $mac ),   # PhysAddr link, formatted MAC
                interfaces => $tstamps{ $tstamp }{ $macid },   # arrayref of link HTML
            };
        }
    }
    return @out;
}

# Audit log entries for this address.
sub _ip_audit_records {
    my ($o) = @_;
    my @rel = eval { $o->get_audit_records };
    return () if $@;
    my @out;
    for my $r (@rel) {
        push @out, {
            tstamp    => eval { $r->tstamp }    // '',
            username  => eval { $r->username }  // '',
            tablename => eval { $r->tablename } // '',
            label     => eval { $r->label }     // '',
            operation => eval { $r->operation } // '',
        };
    }
    return @out;
}

=head1 AUTHOR

Vincent Magnin, C<< <Vincent.Magnin at unil.ch> >>

This code was written with the assistance of the Qwen 3.8-27b large
language model.

=head1 COPYRIGHT & LICENSE

Copyright 2026 University of Lausanne, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

# Make sure to return 1
1;