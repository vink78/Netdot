package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Model::Interface;
use Netdot::Model::PhysAddr;
use Netdot::UI;
use Netdot::Mojo::Registry;
use NetAddr::IP;

# Read-only detail page for one object: every non-empty, non-sensitive attribute.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    # ipblock: hierarchical detail with a view-format flag (list | block | tree).
    if ( $type eq 'ipblock' ) {
        my $o = eval { $class->retrieve( $id ) };
        return $c->reply->not_found unless $o;

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
            push @attrs, [ 'Interface', $iid ? "<a href=\"/management/interface/$iid\">$ilbl</a>" : '' ];

            my $dev = eval { $o->interface && $o->interface->device };
            $dev   ||= eval { ( $o->snmp_devices )[0] };
            my $did = eval { $dev->id };
            push @attrs, [ 'Device', $did ? "<a href=\"/management/device/$did\">" . _obj_label($dev) . "</a>" : '' ];

            # Related objects (read-only; no add/edit links — those need the
            # not-yet-migrated edit interface).
            my @services = _ip_services( $o );
            my @attributes = _ip_attributes( $o );
            my @dhcp   = _ip_dhcp_scopes( $o );
            my @arp    = _ip_last_arp( $o );
            my @audit  = _ip_audit_records( $o );

            $c->render(
                template    => 'management/ipaddress',
                layout      => 'default',
                title       => "Ip " . $o->get_label,
                current     => $o,
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
        my ( @blocks, $viewtype, $tree_html, $grid, $container_grid, @modes );
        my $vfmt = 'list';
        if ( $show->('Children') ) {
            # View modes available for this block (rules from ip.html):
            #   list always; block and tree for v4 when prefix >= MAX.
            my $max = $status eq 'Subnet' ? $cfg->get('SUBNET_BLOCK_VIEW_MAX_PREFIX')
                      : ( $status eq 'Container' ? $cfg->get('CONTAINER_BLOCK_VIEW_MAX_PREFIX') : undef );
            @modes = ( 'list' );
            if ( $v4 && $max && $prefix >= $max ) {
                push @modes, 'block';
                push @modes, 'tree';
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
                $tree_html = ( $ui && $ref ) ? eval { $ui->build_ip_tree_graph_html( id => $o->id, list => $ref, web_path => '/' ) } : undef;
            } else {  # block view
                $viewtype = 'block';
                if ( $status eq 'Subnet' ) {
                    $grid = _build_subnet_grid( $o );               # the address grid
                } else {
                    # Container: the proportional usage visualization (port of container.mhtml).
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

        # Per-tab section data (gathered lazily, only for the active view).
        my ( @sites, @fzones, @rzones, @dhcp, @attributes, @audit, $comments );
        @sites      = _block_sites( $o )      if $show->('Sites');
        ( @fzones, @rzones ) = _block_zones( $o ) if $show->('Zones');
        @dhcp       = _ip_dhcp_scopes( $o )   if $show->('DHCP');
        @attributes = _ip_attributes( $o )    if $show->('Attributes');
        $comments   = eval { $o->info } // '' if $show->('Comments');
        @audit      = _ip_audit_records( $o ) if $show->('Audit');

        my @block_attrs = _block_attributes( $o );

        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => "Ipblock " . $o->get_label,
            view       => $view,
            tabs       => \@tabs,
            block_attrs => \@block_attrs,
            viewtype   => $viewtype,
            viewformat => $vfmt,
            modes      => \@modes,
            tree_html  => $tree_html,
            grid       => $grid,
            container_grid => $container_grid,
            blocks     => \@blocks,
            current    => $o,
            breadcrumb => \@crumbs,
            devs       => $devs,
            sites      => \@sites,
            fzones     => \@fzones,
            rzones     => \@rzones,
            dhcp       => \@dhcp,
            attributes => \@attributes,
            comments   => $comments,
            audit      => \@audit,
        );
        return;
    }

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;

    my @attrs;
    for my $col ( $class->columns ) {
        next if $col eq 'id';
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        next if $@;
        next unless defined $v;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        next if !defined $text || $text eq '';
        push @attrs, [ $col, $text, $href ];
    }

    $c->render(
        template => 'management/detail',
        layout   => 'default',
        title    => ucfirst($type) . " #$id",
        type     => $type,
        id       => $id,
        attrs    => \@attrs,
    );
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

    push @rows, [ 'Address', _esc( $o->address . '/' . $o->prefix ) ];
    push @rows, [ 'Status', "<strong>" . _esc($status) . "</strong>" ] if length $status;
    push @rows, [ 'Description', _esc($o->description) ]
        if defined $o->description && length $o->description;
    push @rows, [ 'Use Network Broadcast', $o->use_network_broadcast ? 'Yes' : 'No' ]
        if $status eq 'Subnet';
    push @rows, [ 'First Seen', _esc($o->first_seen) ]
        if defined $o->first_seen && length $o->first_seen;
    push @rows, [ 'Last Seen', _esc($o->last_seen) ]
        if defined $o->last_seen && length $o->last_seen;
    push @rows, [ 'VLAN', _fk_link( $o->vlan ) ]
        if $status eq 'Subnet' && $o->vlan;
    if ( $status eq 'Container' ) {
        push @rows, [ 'RIR', _esc($o->rir) ] if defined $o->rir && length $o->rir;
        push @rows, [ 'ASN', _fk_link( $o->asn ) ] if $o->asn;
    }
    for my $pair ( [ owner => 'Owner' ], [ used_by => 'Used by' ] ) {
        my ( $col, $label ) = @$pair;
        my $ent = $o->$col;
        push @rows, [ $label, _fk_link($ent) ] if $ent;
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

# Block view for a Container: a proportional usage visualization (port of
# container.mhtml). Rendered as a CSS grid: one row = a /rowsize (config
# DEFAULT_IPBLOCK_ROWSIZE), divided into $COLS base columns; each contained block /
# free partition spans 2^(base_prefix-prefix) columns, so a /23 is exactly 2x a /24.
# A leading column holds the row's starting address. CIDR blocks are aligned to their
# prefix, so no cell crosses a row boundary at a mid-cell offset. Returns HTML.
sub _build_container_grid_html {
    my ( $o, %opt ) = @_;
    my $rowsize = $opt{rowsize} || ( Netdot->config->get('DEFAULT_IPBLOCK_ROWSIZE') || 22 );
    my $divide  = $opt{divide}  || 'max';
    $rowsize    = int( $rowsize );
    my $v4      = ( $o->version == 4 );
    my $bits    = $v4 ? 32 : 128;
    $rowsize    = 32  if ( $v4 && $rowsize > 32 );
    $rowsize    = 128 if ( ! $v4 && $rowsize > 128 );
    my $COLS        = 16;                  # base columns per row
    my $base_prefix = $rowsize + 4;        # one row = a /rowsize, split into 16=2^4 columns
    my $base_size   = 2 ** ( $bits - $base_prefix );   # addresses per base column

    # Contained blocks (sorted) and free space (sorted), merged by address.
    my @ch;
    my $it = eval { $o->children };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $k = $it->next ) { push @ch, $k; }
    }
    @ch = sort { $a->address_numeric <=> $b->address_numeric } @ch;
    my @fs = $o->free_space( $divide );
    @fs   = sort { $a->numeric <=> $b->numeric } @fs;

    my @cells;
    while ( @ch || @fs ) {
        if ( ! @ch || ( @fs && $fs[0]->numeric < $ch[0]->address_numeric ) ) {
            my $f = shift @fs;
            push @cells, {
                width => 2 ** ( $base_prefix - $f->masklen ), class => 'ipaddr_available',
                title => "$f", link => '',
            };
        } elsif ( ! @fs || $fs[0]->numeric > $ch[0]->address_numeric ) {
            my $c     = shift @ch;
            my $st    = $c->status->name;
            my $title = $c->cidr;
            $title   .= ' (' . $c->description . ')' if $c->description;
            push @cells, {
                width => 2 ** ( $base_prefix - $c->prefix ), class => 'ipaddr_' . lc($st),
                title => $title, link => '/management/ipblock/' . $c->id,
            };
        } else {
            last;   # inconsistent state; stop rather than loop forever
        }
    }

    # Row headers: the starting address of each /rowsize row.
    my $total_units = 2 ** ( $base_prefix - $o->prefix );
    my $num_rows    = int( $total_units / $COLS );
    my $start_num   = $o->address_numeric;
    my $base_url    = '/management/ipblock/' . $o->id . '?view_format=block';

    my $html = '<table style="width:100%"><tr>';
    $html .= '<td style="text-align:right;vertical-align:middle">Zoom: Set one row equal to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=\'+this.value">';
    for my $i ( $o->prefix .. ( $v4 ? 32 : 128 ) ) {
        $html .= '<option value="' . $i . '"' . ( $rowsize == $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td><td style="text-align:right;vertical-align:middle">Partition: Set max free space size to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=' . $rowsize . '&dividefreespace=\'+this.value">';
    $html .= '<option value="max"' . ( $divide eq 'max' ? ' selected' : '' ) . '>unlimited</option>';
    for my $i ( $o->prefix .. ( $v4 ? 32 : 128 ) ) {
        $html .= '<option value="' . $i . '"' . ( $divide eq $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td></tr></table>';

    $html .= '<div class="ipcontainergrid" style="display:grid;grid-template-columns:110px repeat('
           . $COLS . ',1fr);grid-auto-rows:15px;gap:1px;width:100%">';
    for my $r ( 0 .. $num_rows - 1 ) {
        my $n    = $start_num + $r * $COLS * $base_size;
        my $addr = eval { NetAddr::IP->new( $n )->addr } // '';
        $html   .= '<div class="ipcontainergrid-rowheader" style="grid-column:1 / 2;grid-row:' . ( $r + 1 )
                 . ' / span 1">' . $addr . '</div>';
    }
    my $g = 0;
    for my $cell (@cells) {
        my $W         = $cell->{width};
        my $start_row = int( $g / $COLS );
        my $start_col = $g % $COLS;
        my ( $spanC, $spanR ) = $W <= $COLS ? ( $W, 1 ) : ( $COLS, int( $W / $COLS ) );
        $html .= '<div class="' . $cell->{class} . '" title="' . $cell->{title}
               . '" style="grid-column:' . ( $start_col + 2 ) . ' / span ' . $spanC
               . ';grid-row:' . ( $start_row + 1 ) . ' / span ' . $spanR . '">'
               . '<a href="' . ( $cell->{link} || '#' ) . '" style="display:block;height:100%"></a></div>';
        $g += $W;
    }
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
                $cell = ( exists $used{ $net->numeric } && $aid )
                    ? qq{<a href="/management/ipblock/$aid" class="ipaddr">$inner</a>}
                    : $inner;
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

# Forward + reverse DNS zones of a block. Forward: SubnetZone join -> Zone.
# Reverse: dot-arpa names that match an existing Zone. Returns (forward, reverse).
sub _block_zones {
    my ($o) = @_;
    my @fwd;
    my @rel = eval { $o->zones };
    unless ($@) {
        for my $sz (@rel) {
            my $zone = eval { $sz->zone };
            push @fwd, _fk_link( $zone ) if $zone;   # Zone -> /management/zone/<id>
        }
    }
    my @rev;
    my %zones;
    my $it = eval { Zone->retrieve_all };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $z = $it->next ) { $zones{ $z->name } = $z; }
    }
    my @names = eval { $o->get_dot_arpa_names };
    unless ($@) {
        for my $n (@names) {
            push @rev, _fk_link( $zones{$n} ) if $zones{ $n };
        }
    }
    return ( @fwd, @rev );
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
            zone_href => $zid ? "/management/zone/$zid" : undef,
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
            # physaddr is a FK to PhysAddr, shown via its config-formatted MAC.
            type          => eval { $s->type->name } // '',
            name          => eval { $s->name }       // '',
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

1;
