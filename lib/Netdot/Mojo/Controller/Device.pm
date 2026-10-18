package Netdot::Mojo::Controller::Device;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;
use Netdot::Mojo::Permissions;
use Netdot::Model::Device;
use Netdot::Util::Log;
use Log::Log4perl;
use GraphViz;
use File::Temp qw(tempfile);
use Mojo::Util  qw(b64_encode);

# Device detail page (port of the legacy device.html): Basics, Interfaces,
# IP, BGP, Hosted, Circuits, STP, Topology, ARP, FWT, Modules, Audit,
# Rights, and the All view (every section on one page). Display/validation
# only: all writes go through the JSON API.

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Device - Device detail page + SNMP discovery / re-poll

    Read-only detail page (Basics / Interfaces views, port of the legacy
    device.html) plus the SNMP discovery wizard and the re-poll page, both
    display/validation only: the actual writes go through the API
    (POST /api/device, POST /api/device/<id>/update).

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->any('/management/device/discover')->to('device#discover')
    #   ->get('/management/device/:id/update')->to('device#update')
    #   ->get('/management/device/:id')->to('device#show', type => 'device')

=head1 INSTANCE METHODS

=cut

=head2 show - Device detail page

Arguments:  Controller (params: id, view)
Returns:    Renders the management/device template
Description: Port of the legacy device.html. Valid views: Basics,
            Interfaces, IP, BGP, Hosted, Circuits, STP, Topology, ARP,
            FWT, Modules, Audit, Rights. Basics shows the device attributes
            (meta "all" view) + custom attributes and the in-place edit
            form (written via PATCH /api/device/<id>). Topology renders the
            Layer-2 topology as a GraphViz graph (on the fly, embedded as a
            data: URI with the clickable image map); ARP and FWT list the
            device's ARP caches / forwarding tables (the tabs are only
            shown when the device has data, as in Mason). The page also
            offers a delete action (API, with the optional remove-IPs/DNS
            choice) and, for Admins only, the SNMP re-poll entry point
            (discover wizard).

=cut

sub show {
    my $c  = shift;
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Device->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $view = $c->param('view') || 'Basics';
    my %views = map { $_ => 1 }
        qw(Basics Interfaces IP BGP Hosted Circuits STP Topology ARP FWT
           Modules Audit Rights All);
    $view = 'Basics' unless $views{$view};

    my ($name, $fqdn) = ('', '');
    my $rr = eval { $o->name };
    if ($rr) {
        $name = eval { $rr->name } // '';
        my $zone = eval { $rr->zone->name } // '';
        $fqdn   = ( $name && $zone ) ? "$name.$zone" : $name;
    }
    $fqdn = "Device #$id" unless length $fqdn;

    # In-place edit form (Basics view only): scalar + FK fields, written via the
    # JSON API (PATCH). Computed only on Basics so the other views stay cheap.
    my $can_edit = $c->perm( 'edit', $o );
    # Page-level delete (all views): shown when the user may delete this device.
    # Device delete is special (see Device::delete) — the JS offers the
    # default-off choice to also remove the device's IPs / DNS A/AAAA records
    # (delete_ips), which cascades to the name RR once it has no sub_records.
    my $can_delete = $c->perm( 'delete', $o );
    # SNMP re-poll (wizard step 1, pre-filled with this device): admin only,
    # as in Mason (access_admin_section).
    my $can_discover = Netdot::Mojo::Permissions->user_type( $c->current_person ) eq 'Admin';
    # Access Rights tab (Mason: visible to access_section 'device.html:edit_rights').
    my $show_rights = $c->perm( 'access_section', 'device.html:edit_rights' );
    # ARP / FWT tabs (as in Mason): only shown when the device has data.
    my (@arp_caches, @fwt);
    eval { @arp_caches = $o->arp_caches };
    eval { @fwt        = $o->forwarding_tables };
    my %stash = (
        id       => $id,
        view     => $view,
        fqdn     => $fqdn,
        title    => "Device $fqdn",
        can_edit => $can_edit,
        can_delete => $can_delete,
        del_path   => $can_delete ? $c->web_prefix . '/api/device/' . $id : '',
        del_goto   => $can_delete ? Netdot::Mojo::Registry::set_uri( '/management/device' ) : '',
        can_discover => $can_discover,
        show_rights  => $show_rights,
        has_arp      => @arp_caches ? 1 : 0,
        has_fwt      => @fwt ? 1 : 0,
    );

    # Per-section data (each section's rows/sort/… keys, computed by the
    # section builder). A single view computes its section only; the All view
    # (port of the legacy device.html view=All — every section on one page)
    # computes them all. The data is namespaced under $stash{sections}{$name}
    # so the sections' conflicting rows/sort/… keys don't collide: the section
    # partials (management/device/*.html.ep, one per section) read their own
    # hash via the `sec` render_to_string argument. ARP/FWT are included only
    # when the
    # device has data (same gate as the tabs); Rights only for users who may
    # view the section (same gate as the tab).
    my @names = $view eq 'All'
        ? ( 'Basics', 'Interfaces', 'Modules', 'IP', 'BGP', 'STP', 'Topology',
            ( $stash{has_arp} ? 'ARP' : () ),
            ( $stash{has_fwt} ? 'FWT' : () ),
            'Audit', 'Circuits', 'Hosted',
            ( $show_rights ? 'Rights' : () ) )
        : ( $view );
    my %sections;
    for my $name (@names) {
        $sections{$name} =
            _section_data( $name, $o, $c, $id, can_edit => $can_edit,
                           arp => \@arp_caches, fwt => \@fwt );
    }
    $stash{sections} = \%sections;

    $c->render( template => 'management/device', layout => 'default', %stash );
}

# Per-section data hash for the device detail page: dispatches to the section
# builder and (for Basics) bundles the in-place edit form fields + the
# custom-attributes "Add" form spec (Detail::relation_adds, the port of the
# legacy device.html [add] link on the Custom Attributes section, rendered
# through the shared _edit_form partial: POST /api/deviceattr). Returns the
# hash the section partial reads via its `sec` argument.
sub _section_data {
    my ( $name, $o, $c, $id, %a ) = @_;
    my $d;
    if ( $name eq 'Basics' ) {
        $d = { sections => _basics( $o ) };
        $d->{attr_add} =
            ( grep { $_->{rel} eq 'attributes' }
              @{ Netdot::Mojo::Detail::relation_adds( $o, $c->current_person ) } )[0];
        if ( $a{can_edit} ) {
            $d->{fields}   = Netdot::Mojo::Detail::build_edit_fields( $o, 'Device' );
            $d->{api_path} = $c->web_prefix . '/api/device/' . $id;
        } else {
            $d->{fields}   = [];
            $d->{api_path} = '';
        }
    }
    elsif ( $name eq 'Interfaces' ) { $d = _interfaces( $o, $c, $id ); }
    elsif ( $name eq 'Topology'   ) { $d = _topology_view( $o, $c, $id ); }
    elsif ( $name eq 'ARP' || $name eq 'FWT' ) {
        $d = _cache_view( $o, $c, $name, $name eq 'ARP' ? $a{arp} : $a{fwt} );
    }
    else { $d = _table_view( $name, $o, $c, $id ); }
    return $d;
}

# ---------------------------------------------------------------------------
# SNMP discovery wizard (port of the legacy device_tasks.html "Discover
# Device" + updatedevice.html) — ADMIN ONLY (Mason: access_admin_section).
#
# Display / validation only: all DB writes go through the API
# (POST /api/device {discover: true, ...} or /api/device/<id>/update).
#
# Two routes:
#   /management/device/discover
#       GET (no host)      -> redirect: a bare GET goes to the device list
#                            (the « Discover Device » box is the entry point);
#                            ?device=<id> goes to the direct re-poll URL.
#       POST action=discover
#                            step 1: Device->get_snmp_info(...) (read-only).
#                            On success the review form (step 2) is rendered
#                            with the guessed Owner / Used by / Site /
#                            Contacts; on failure the step-1 form is
#                            re-rendered with the error. Confirming the review
#                            calls the API from the browser (netdot.js
#                            initDiscRun) and renders the captured log.
#   /management/device/<id>/update
#       GET                 re-poll page: stored credentials, dry-run choice;
#                            the actual re-poll is POST /api/device/<id>/update.
#
# The confirm step is stateless: the SNMP info hash is too large for a
# signed-cookie session, so the review form re-sends the original query
# arguments and the API re-runs the query.

=head2 discover - SNMP discovery wizard

Arguments:  Controller (params: action, host, version, community / v3
            security args; ?device=<id> for a direct re-poll)
Returns:    Renders the management/device_discover template
Description: Admin-only port of the legacy device_tasks.html "Discover
            Device" + updatedevice.html. Display/validation only: every DB
            write goes through the API (POST /api/device {discover: 1}).
            A POST with action=discover runs the read-only SNMP query
            (Device->get_snmp_info) and renders the review form (step 2)
            with the guessed Owner / Used by / Site / Contacts; the confirm
            step calls the API from the browser (netdot.js) and renders the
            captured model log.

=cut

sub discover {
    my $c = shift;
    my $p = $c->current_person;
    unless ( $p && Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin' ) {
        return $c->render( template => 'error_403', layout => 'default',
                           title => 'Access denied', status => 403 );
    }
    return _disc_step1( $c ) if ( $c->param( 'action' ) // '' ) eq 'discover';
    return _disc_form( $c );
}

# SNMP re-poll page for an existing device (admin-only, display only):
# the actual re-poll is performed by the UI via POST /api/device/<id>/update
# (all DB writes go through the API). The page shows the stored-credentials
# re-poll with the dry-run choice; netdot.js renders the result (captured
# model log + link to the device page) from the API response.
=head2 update - SNMP re-poll page for an existing device

Arguments:  Controller (stash: id)
Returns:    Renders the management/device_discover template (mode=repoll)
Description: Admin-only, display only: the actual re-poll is performed by
            the UI via POST /api/device/<id>/update (all DB writes go
            through the API). The page shows the stored-credentials re-poll
            with the dry-run choice; the UI renders the captured model log
            and a link to the device page from the API response.

=cut

sub update {
    my ($c) = @_;
    my $p = $c->current_person;
    unless ( $p && Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin' ) {
        return $c->render( template => 'error_403', layout => 'default',
                           title => 'Access denied', status => 403 );
    }
    my $id = $c->stash('id');
    my $o  = eval { Device->retrieve( $id ) };
    return $c->render( template => 'error_404', layout => 'default',
                       title => 'Not found', status => 404 )
        if $@ || ! $o;
    $c->render(
        template => 'management/device_discover',
        layout    => 'default',
        title     => 'SNMP update: ' . ( $o->fqdn // $o->id ),
        mode      => 'repoll',
        dev       => $o,
    );
}

# Run the SNMP query described by the form (shared by step 1 and step 2):
# returns ( $info, $host, $device_id, $error ). For a ?device=<id> re-poll the
# device's stored credentials are used; otherwise the form's host + version +
# community (v1/v2) or security args (v3) are passed to get_snmp_info.
sub _disc_snmp_query {
    my ( $c, $echo ) = @_;
    my $device = $c->param( 'device' ) // '';
    my $host   = $c->param( 'host' )   // '';
    $host =~ s/\s//g;

    my $info;
    if ( $device =~ /^\d+$/ ) {
        my $o = eval { Device->retrieve($device) };
        return ( undef, $device, $device, 'Could not retrieve device #' . $device )
            unless $o && !$@;
        $host = $o->fqdn;
        $info = eval { $o->get_snmp_info() };
        $info = undef if $@;
    }
    elsif ( length $host ) {
        my %q = ( host => $host, version => $c->param( 'version' ) );
        if ( ( $q{version} || 2 ) == 3 ) {
            for my $k ( qw(sec_name sec_level auth_proto auth_pass priv_proto priv_pass) ) {
                $q{$k} = $c->param($k) if defined $c->param($k) && length $c->param($k);
            }
        } else {
            my $comm = $c->param( 'comstr' ) // '';
            if ( $comm eq 'Other' ) {
                $q{communities} = [ $c->param( 'other_comstr' ) ]
                    if length( $c->param( 'other_comstr' ) // '' );
            }
            elsif ( length $comm ) {
                $q{communities} = [ $comm ];
            }
        }
        $info = eval { Device->get_snmp_info( %q ) };
        $info = undef if $@;
    }
    return ( undef, $host, $device, 'SNMP session failed (host unreachable or bad credentials)' )
        unless $info;
    return ( $info, $host, $device, undef );
}

# Step-1 form (GET, or step-1 error). $err is optional; the submitted values
# are echoed so a failed query can be retried without retyping.
sub _disc_form {
    my ( $c, $err ) = @_;
    my $cfg = Netdot->config;
    my %echo = map { $_ => $c->param($_) }
        qw(host version comstr other_comstr sec_name sec_level auth_proto auth_pass priv_proto priv_pass);
    my $raw_device = $c->param( 'device' ) // '';

    # There is no standalone discovery form page: the device list's
    # « Discover Device » box is the entry point (it POSTs here with a host).
    # A bare GET redirects to the list; a ?device=<id> re-poll redirects to
    # the direct re-poll URL. (A failed POST still has a host: the form is
    # re-rendered below with the error and the echoed fields.)
    unless ( length( $echo{host} // '' ) ) {
        if ( $raw_device =~ /^\d+$/ ) {
            my $o = eval { Device->retrieve( $raw_device ) };
            if ( $o && !$@ ) {
                return $c->redirect_to(
                    Netdot::Mojo::Registry::set_uri( "/management/device/$raw_device/update" ) );
            }
        }
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/device' ) );
    }
    $echo{device} = $raw_device;
    $c->render(
        template => 'management/device_discover',
        layout    => 'default',
        title     => 'Device discovery',
        mode      => 'form',
        error     => $err // '',
        echo      => \%echo,
        defver    => $cfg->get('DEFAULT_SNMPVERSION') || 2,
        comms     => [ @{ $cfg->get('DEFAULT_SNMPCOMMUNITIES') || ['public'] } ],
        v3def     => {
            sec_name   => $cfg->get('DEFAULT_SNMP_SECNAME')   // '',
            sec_level  => $cfg->get('DEFAULT_SNMP_SECLEVEL')  // 'authPriv',
            auth_proto => $cfg->get('DEFAULT_SNMP_AUTHPROTO') // 'SHA',
            auth_pass  => $cfg->get('DEFAULT_SNMP_AUTHPASS')  // '',
            priv_proto => $cfg->get('DEFAULT_SNMP_PRIVPROTO') // 'AES',
            priv_pass  => $cfg->get('DEFAULT_SNMP_PRIVPASS')  // '',
        },
    );
}

# Step 1: run the query, then render the review form (or the step-1 form on
# error). For a brand-new device the Owner / Used by / Site are guessed as in
# Mason: used_by from the first IP's subnet, site from that entity (or the
# SNMP location), owner from the DEFAULT_DEV_OWNER config; the default
# contactlist from DEFAULT_CONTACTLIST.
sub _disc_step1 {
    my ($c) = @_;
    my ( $info, $host, $device, $err ) = _disc_snmp_query($c);
    return _disc_form( $c, $err ) if $err || !$info;

    my $is_existing = $device ne '';
    my $ex_id = $device;
    my ( $g_owner, $g_used, $g_site );
    unless ( $is_existing ) {
        # existing device with this name? (Mason: search name=>$host)
        my $ex = eval { Device->search( name => $host )->first };
        if ( $ex && !$@ ) {
            $is_existing = 1;
            $ex_id = $ex->id;
        }
    }
    unless ( $is_existing ) {
        # Guesses (new device): used_by from the first IP found on any
        # interface (Mason's LOOP), then site from that entity or the SNMP
        # location.
        my $ifaces = $info->{interface} || {};
        GUESS: for my $int ( sort keys %$ifaces ) {
            my $ips = $ifaces->{$int}{ips} || {};
            for my $ip ( sort keys %$ips ) {
                my $mask = $ips->{$ip}{mask};
                # get_snmp_info stores the reported prefix as {subnet}
                # ("address/len", from the device's ipNetToMedia table);
                # {mask} is kept as a fallback (Mason referenced it, but
                # current get_snmp_info never sets it).
                if ( ! defined $mask && ( $ips->{$ip}{subnet} // '' ) =~ m{ /\d+ $ }x ) {
                    $mask = ( $ips->{$ip}{subnet} =~ m{ ^ [^/]+ / (\d+) $ }x )[0];
                }
                next unless defined $mask;
                my $subnetaddr = eval { Ipblock->get_subnet_addr( address => $ip, prefix => $mask ) };
                my $subnet = eval { $subnetaddr ? Ipblock->search( address => $subnetaddr )->first : undef };
                if ( $subnet && $subnet->used_by ) {
                    $g_used = $subnet->used_by;
                    my $it = eval { $g_used->sites };
                    if ( ref $it eq 'ARRAY' && @$it ) {
                        $g_site = $it->[0]->site;
                    }
                    last GUESS;
                }
            }
        }
        unless ( $g_site ) {
            my $loc = $info->{syslocation};
            if ( $loc && length $loc ) {
                my $s = eval { Site->search_like( name => "%$loc%" )->first };
                $g_site = $s if $s && !$@;
            }
        }
        my $conf_owner = Netdot->config->get('DEFAULT_DEV_OWNER');
        $g_owner = eval { Entity->search( name => $conf_owner )->first };
        $g_owner = undef if $@ || !$g_owner;
    }

    my $def_cl_id;
    my $conf_cl = Netdot->config->get('DEFAULT_CONTACTLIST');
    my $def_cl  = eval { ContactList->search( name => $conf_cl )->first };
    $def_cl_id = $def_cl->id if $def_cl && !$@;

    # Review-form option lists (Mason: retrieve_all, sorted by name).
    my @entities = eval { Entity->retrieve_all };      @entities = () if $@;
    my @sites    = eval { Site->retrieve_all };        @sites    = () if $@;
    my @cls      = eval { ContactList->retrieve_all }; @cls      = () if $@;

    $c->render(
        template => 'management/device_discover',
        layout    => 'default',
        title     => 'Device discovery',
        mode      => 'review',
        host      => $host,
        device    => $device,
        ex_id     => $ex_id,
        # echoed query args: the review form re-sends them to the API (the
        # confirm re-runs the same SNMP query there — the info hash is too
        # large for a signed-cookie session, so the flow is stateless)
        query     => { map { $_ => $c->param($_) } qw(version comstr other_comstr sec_name sec_level auth_proto auth_pass priv_proto priv_pass) },
        sysdescription => $info->{sysdescription} // '',
        ipforwarding   => $info->{ipforwarding} ? 1 : 0,
        is_existing    => $is_existing ? 1 : 0,
        def_addsubnets   => Netdot->config->get('ADDSUBNETS') ? 1 : 0,
        def_subsinherit  => Netdot->config->get('SUBNET_INHERIT_DEV_INFO') ? 1 : 0,
        entities     => [ sort { $a->name cmp $b->name } @entities ],
        sites        => [ sort { $a->name cmp $b->name } @sites ],
        contactlists => [ sort { $a->name cmp $b->name } @cls ],
        sel_owner    => $g_owner ? $g_owner->id : '',
        sel_used     => $g_used  ? $g_used->id   : '',
        sel_site     => $g_site  ? $g_site->id   : '',
        sel_cl       => $def_cl_id // '',
    );
}

# Basics view: grouped, multi-column sections (General 2, Location 2,
# Management 4, Comments 1, Custom 1), mirroring the old Mason device.html so
# the whole page fits without scrolling. Each cell is [ tag, text, href ].
sub _basics {
    my ($o) = @_;

    my @general;
    push @general, map { _kv($o, $_) }
        qw(name aliases host_device sysname sysdescription asset_id);
    if ( my $asset = eval { $o->asset_id } ) {
        my ( $ptext, $phref ) =
            @{ Netdot::Mojo::Registry::link_for( eval { $asset->product_id->type } ) };
        push @general, [ 'Type', $ptext // '', $phref ];
        if ( my $phy = eval { $asset->physaddr } ) {
            my ( $mtext, $mhref ) = @{ Netdot::Mojo::Registry::link_for($phy) };
            push @general, [ 'Base MAC', $mtext // '', $mhref ];
        }
        push @general, [ 'Custom S/N', _val( $asset, 'custom_serial' ), undef ];
        push @general, [ 'Inventory',  _val( $asset, 'inventory_number' ), undef ];
    }
    my $osv    = _kv( $o, 'os' );
    my $latest = eval { $o->product->latest_os };
    $osv->[1] .= sprintf( ' (Recommended OS: %s)', $latest )
        if $latest && defined $o->os && $o->os ne $latest;
    push @general, $osv;
    push @general, _kv( $o, 'extension' );

    my @location;
    push @location, map { _kv($o, $_) } qw(owner used_by site room rack syslocation);
    my @contacts;
    eval { @contacts = $o->contacts };
    my @clinks;
    for my $dc (@contacts) {
        my $cl = eval { $dc->contactlist };
        next unless $cl;
        my ( $t, $h ) = @{ Netdot::Mojo::Registry::link_for($cl) };
        push @clinks, [ $t // '', $h ];
    }
    push @location, [ 'Contacts', @clinks ? \@clinks : '', undef ];

    my @management;
    push @management, map { _kv($o, $_) }
        qw(date_installed last_updated oobname oobname_2 oobnumber oobnumber_2 power_outlet power_outlet_2 monitored);
    push @management, _kv( $o, 'monitoring_template' ) if $o->monitored;
    push @management, map { _kv($o, $_) }
        qw(monitoring_path_cost customer_managed monitor_config monitor_config_group down_from down_until snmp_managed auto_dns);
    my @layers;
    eval { @layers = $o->list_layers };
    push @management, [ 'Layers', join( ', ', @layers ), undef ];
    push @management, _kv( $o, 'ipforwarding' );
    if ( $o->snmp_managed ) {
        push @management, _kv( $o, 'snmp_version' );
        push @management, map { _kv($o, $_) }
            qw(snmp_bulk canautoupdate snmp_polling collect_arp collect_fwt collect_stp snmp_conn_attempts snmp_down last_arp last_fwt);
        if ( $o->snmp_version eq '3' ) {
            push @management, map { _kv($o, $_) }
                qw(snmp_authkey snmp_authprotocol snmp_privkey snmp_privprotocol snmp_securitylevel snmp_securityname);
        }
        else {
            push @management, _kv( $o, 'community' );
        }
        push @management, _kv( $o, 'snmp_target' );
    }

    my @comments = ( [ '', _val( $o, 'info' ), undef ] );

    my @sections = (
        { title => 'General',             cols => 2, list => \@general },
        { title => 'Location / Contacts', cols => 2, list => \@location },
        { title => 'Management',          cols => 4, list => \@management },
        { title => 'Comments',            cols => 1, list => \@comments },
        { title => 'Custom Attributes',   cols => 1, list => _custom_attrs($o) },
    );
    for my $s (@sections) {
        $s->{rows} = _chunk( $s->{list}, $s->{cols} );
        delete $s->{list};
    }
    return \@sections;
}

# Chunk a flat list of cells into rows of up to $n cells (for the multi-column
# layout). The last row may be short; the template pads it.
sub _chunk {
    my ( $list, $n ) = @_;
    $n = 1 unless $n && $n > 0;
    my @rows;
    my $last = @$list - 1;
    for ( my $i = 0; $i < @$list; $i += $n ) {
        my $end = $i + $n - 1;
        $end = $last if $end > $last;
        push @rows, [ @$list[ $i .. $end ] ];
    }
    return \@rows;
}

# Friendly label for a column (from the meta tag).
sub _tag {
    my ($col) = @_;
    return Netdot::Mojo::Registry::column_tag( 'Device', $col );
}

# [ tag, text, href ] for a device column. Sensitive columns are masked.
sub _kv {
    my ( $o, $col ) = @_;
    if ( Netdot::Mojo::Registry::is_sensitive($col) ) {
        return [ _tag($col), '\x{2022}\x{2022}\x{2022}\x{2022}\x{2022}', undef ];
    }
    my $v = eval { $o->$col };
    $v    = undef if $@;
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::attr_display( 'Device', $col, $v ) };
    return [ _tag($col), $text, $href ];
}

# Raw scalar value (no link) of a column.
sub _val {
    my ( $obj, $col ) = @_;
    my $v = eval { $obj->$col };
    return '' if $@ || !defined $v;
    return $v;
}

# Custom attributes (DeviceAttr) as [ name, value ] rows.
sub _custom_attrs {
    my ($o) = @_;
    my @out;
    my @attrs;
    eval { @attrs = $o->attributes };
    for my $a (@attrs) {
        my ( $ntext ) = @{ Netdot::Mojo::Registry::link_for( eval { $a->name } ) };
        $ntext = '' unless defined $ntext;
        my $val = eval { $a->value };
        push @out, [ $ntext, $val // '', undef ];
    }
    return \@out;
}

# Interfaces table data. Each cell is an arrayref of [ text, href ] segments.
sub _interfaces {
    my ( $o, $c, $id ) = @_;

    my %sort_keys = map { $_ => 1 }
        qw(number name speed vlan jack descr monitored snmp oper_status);
    my $ifsort   = $c->param('ifsort') || 'number';
    $ifsort      = 'number' unless $sort_keys{$ifsort};
    my $showvlan = $c->param('showvlan') || 'all';
    # Edit mode (Mason's ?editints=1): display only — the mutations go through
    # the JSON API (PATCH /api/interface/<id>, DELETE /api/interface?id=…).
    my $editints = $c->param('editints') ? 1 : 0;

    my $ifs = eval { $o->interfaces_by($ifsort) };
    $ifs = [] if $@ || !ref($ifs);
    my @ifs = @$ifs;

    # vlan map: iface_id => { vid => Vlan object }; plus the set of all vids.
    my ( %ifvlans, %allvids );
    my @allifs;
    eval { @allifs = $o->interfaces };
    for my $if (@allifs) {
        my @ifv;
        eval { @ifv = $if->vlans };
        for my $ifv (@ifv) {
            my $vobj = eval { $ifv->vlan };
            my $vid  = eval { $vobj->vid };
            next unless $vobj && defined $vid;
            $ifvlans{ $if->id }{$vid} = $vobj;
            $allvids{$vid} = 1;
        }
    }

    my $connected = eval { $o->get_connected_devices() } // {};

    my %present;
    for my $if (@ifs) {
        $present{jack} = 1 if defined eval { $if->jack };
        $present{desc} = 1 if defined eval { $if->description };
    }

    # Edit mode: the Jack cell is a <select> fed by the device room's closet
    # jacks when that list is small enough (Mason's select_lookup defaults);
    # otherwise a keyword search (nd-fk-search, target horizontalcable).
    my ( $jack_opts, $jack_kw );
    if ($editints) {
        my @closet_jacks;
        my $room = eval { $o->room };
        if ($room) {
            my @closets = eval { $room->closets } || ();
            for my $cl (@closets) {
                my @hc = @{ ( eval { $cl->horizontalcables } || [] ) };
                push @closet_jacks, @hc;
            }
        }
        @closet_jacks = sort { ( eval { $a->get_label } // '' ) cmp ( eval { $b->get_label } // '' ) } @closet_jacks;
        my $max = Netdot->config->get('DEFAULT_SELECTMAX') || 100;
        if ( @closet_jacks && @closet_jacks <= $max ) {
            $jack_opts = [ map { [ $_->id, eval { $_->get_label } // '' ] } @closet_jacks ];
        } else {
            $jack_kw = 1;
        }
    }

    my @rows;
    for my $if (@ifs) {
        my $i = $if->id;
        next if $showvlan ne 'all' && !exists $ifvlans{$i}{$showvlan};
        my $ihref = Netdot::Mojo::Registry::set_uri( "/management/interface/$i" );

        my @vp;
        if ( exists $ifvlans{$i} ) {
            for my $vid ( sort { $a <=> $b } keys %{ $ifvlans{$i} } ) {
                push @vp, Netdot::Mojo::Registry::link_for( $ifvlans{$i}{$vid} );
            }
        }
        # >1 VLAN => a <select> dropdown (simpler display); else a plain link.
        my $nvp = scalar @vp;
        my $vcell =
           $nvp > 1 ? { select => 1, options => \@vp }
         : $nvp == 1 ? [ $vp[0] ]
         : [ [ '', '' ] ];

        my @conn;
        my $nbr = eval { $if->neighbor };
        if ($nbr) {
            push @conn, Netdot::Mojo::Registry::link_for($nbr);
        } elsif ( my $cd = $connected->{$i} ) {
            my %seen;
            for my $mac_id ( sort keys %$cd ) {
                my $e = $cd->{$mac_id};
                if ( $e->{ip} ) {
                    for my $ip_id ( sort keys %{ $e->{ip} } ) {
                        my $ip = $e->{ip}{$ip_id};
                        my ( $t, $h );
                        if ( $ip->{rrid} ) { $t = $ip->{fqdn};  $h = Netdot::Mojo::Registry::set_uri( "/management/rr/$ip->{rrid}" ); }
                        else               { $t = $ip->{address}; $h = Netdot::Mojo::Registry::set_uri( "/management/ipblock/$ip_id" ); }
                        next if $seen{$t}++;
                        push @conn, [ $t, $h ];
                    }
                } else {
                    push @conn, [ $e->{mac}, Netdot::Mojo::Registry::set_uri( "/management/physaddr/$mac_id" ) ];
                }
            }
        }

        my $style = '';
        my $ds    = eval { $if->doc_status };
        $style = 'background-color: #cccccc;' if $ds eq 'manual';
        $style = 'background-color: #ff8e8e;' if $ds eq 'removed';

        my $jack = Netdot::Mojo::Registry::link_for( eval { $if->jack } );

        # Edit-mode values (Mason's form_field echo): the JS sends back only the
        # fields that differ from these (data-nd-orig), via PATCH /api/interface/<id>.
        my %edit;
        if ($editints) {
            $edit{number}      = $if->number // '';
            $edit{name}        = $if->name // '';
            $edit{description} = $if->description // '';
            my $jackid = eval { $if->jack->id };
            $edit{jack} = defined $jackid ? $jackid : undef;
            $edit{jack_label} = eval { $if->jack->get_label } // '#' . $jackid
                if defined $jackid;
            # Connected Device picker: current neighbor id + label (the JS
            # compares against data-nd-orig and PATCHes `neighbor: <id|null>`).
            $edit{neighbor} = $nbr ? $nbr->id : undef;
            $edit{neighbor_label} = eval { $nbr->get_label } // '#' . $nbr->id
                if $nbr;
        }

        push @rows, {
            id     => $i,
            edit   => \%edit,
            number => [ [ $if->number // '', $ihref ] ],
            name   => [ [ $if->name   // '', $ihref ] ],
            speed  => [ [ $if->speed_pretty // '', undef ] ],
            vlans  => $vcell,
            status => [ [ $if->oper_status // '', undef ] ],
            jack   => [ $jack ],
            descr  => [ [ $if->description // '', undef ] ],
            conn   => \@conn,
            style  => $style,
        };
    }

    return {
        ifsort    => $ifsort,
        showvlan  => $showvlan,
        rows      => \@rows,
        vids      => [ sort { $a <=> $b } keys %allvids ],
        # Mason shows the Jack / Descr. columns in edit mode even when no
        # interface has a value yet.
        show_jack => ( $present{jack} || $editints ) ? 1 : 0,
        show_desc => ( $present{desc} || $editints ) ? 1 : 0,
        editints  => $editints,
        jack_opts => $jack_opts,
        jack_kw   => $jack_kw ? 1 : 0,
        sort_base => Netdot::Mojo::Registry::set_uri( "/management/device/$id?view=Interfaces" ),
    };
}

############################################################################
# Generic "table" views: IP, BGP, Hosted, Circuits, STP, Modules, Audit.
# Each returns { view, cols => [[label, sortcode]], rows => [ [cell, ...] ],
#                info => [[label, text, href]], sort_base, sort_param, sort,
#                filter_param, filter_vids, filter_val, empty_msg }.
# A "cell" is an arrayref of [ text, href ] segments (joined by ", " in the
# template); pass several segments for a multi-link cell (e.g. DNS names).
############################################################################

sub _table_view {
    my ( $view, $o, $c, $id ) = @_;
    if    ($view eq 'IP')       { return _ip_view( $o, $c, $id ); }
    elsif ($view eq 'BGP')      { return _bgp_view( $o, $c, $id ); }
    elsif ($view eq 'Hosted')   { return _hosted_view( $o, $c, $id ); }
    elsif ($view eq 'Circuits') { return _circuits_view( $o, $c, $id ); }
    elsif ($view eq 'STP')      { return _stp_view( $o, $c, $id ); }
    elsif ($view eq 'Modules')  { return _modules_view( $o, $c, $id ); }
    elsif ($view eq 'Audit')    { return _audit_view( $o, $c, $id ); }
    elsif ($view eq 'Rights')   { return _rights_view( $o, $c, $id ); }
    return { view => $view, cols => [], rows => [] };
}

# [text, href] from a value via the registry (falls back to plain text).
sub _lk {
    my ($v) = @_;
    my ( $t, $h ) = @{ Netdot::Mojo::Registry::link_for($v) };
    return [ $t // '', $h // '' ];
}

# Format a scalar (dates become readable strings).
sub _fmt {
    my ($v) = @_;
    return '' unless defined $v;
    my $f = Netdot::Mojo::Registry::format_value($v);
    return defined $f ? $f : $v;
}

# Multi-link cell: arrayref of [ text, href ] segments.
sub _ml {
    my ( @pairs ) = @_;
    return \@pairs if @pairs;
    return [ [ '', '' ] ];
}

sub _ip_view {
    my ( $o, $c, $id ) = @_;
    my %ok       = map { $_ => 1 } qw(address interface);
    my $ipsort   = $c->param('ipsort') || 'address';
    $ipsort      = 'address' unless $ok{$ipsort};
    my $showvlan = $c->param('showvlan') || 'all';
    my $editips  = $c->param('editips') ? 1 : 0;
    my $add_ip   = $c->param('add_ip')  ? 1 : 0;
    my $can_edit = $c->perm( 'edit', $o );

    my $r = eval { $o->get_ips( sort_by => $ipsort ) };
    $r = [] if $@ || !ref $r;
    my @ips = @$r;

    # Mason filters the IP rows by the showvlan param (as the Interfaces view).
    my %showif;
    if ( $showvlan ne 'all' ) {
        my @allifs;
        eval { @allifs = $o->interfaces };
        for my $if (@allifs) {
            my @ifv;
            eval { @ifv = $if->vlans };
            for my $ifv (@ifv) {
                my $vid = eval { $ifv->vlan->vid };
                if ( defined $vid && "$vid" eq "$showvlan" ) {
                    $showif{ $if->id } = 1;
                    last;
                }
            }
        }
    }

    # The device's interfaces: the Interface select options (edit mode + add
    # form), sorted by label as in Mason.
    my @ints;
    eval { @ints = $o->interfaces };
    my @int_opts =
        map  { [ $_->id, ( eval { $_->get_label } || '#' . $_->id ) ] }
        grep { $_ }
        sort { ( eval { $a->get_label } // '' ) cmp ( eval { $b->get_label } // '' ) } @ints;

    # The RR the device name points to: it must never be deletable from here
    # (Mason: deleting it would break the device.name referential integrity).
    my $name_rr = eval { $o->name->id };

    # Service / contact list options for the inline "add service" form
    # (Mason's addservice.html popup, inline here). The contact list defaults
    # to the device's first contact's list, as in Mason.
    my ( @svc_opts, @cl_opts, $cl_def );
    eval {
        my @svcs = Service->retrieve_all;
        @svc_opts =
            map  { [ $_->id, ( $_->name // '' ) ] }
            grep { $_ }
            sort { ( $a->name // '' ) cmp ( $b->name // '' ) } @svcs;
        my @cls = ContactList->retrieve_all;
        @cl_opts =
            map  { [ $_->id, ( $_->name // '' ) ] }
            grep { $_ }
            sort { ( $a->name // '' ) cmp ( $b->name // '' ) } @cls;
        my @cts = $o->contacts;
        $cl_def = $cts[0] ? eval { $cts[0]->contactlist->id } : undef;
    };

    my @rows;
    for my $ip (@ips) {
        my $iface = eval { $ip->interface };
        my $iface_id = eval { $iface->id };
        next if $showvlan ne 'all' && !$showif{ $iface_id };

        my @dns;
        my @ar;
        eval { @ar = $ip->a_records };
        for my $a (@ar) {
            my $rr  = eval { $a->rr };
            next unless $rr;
            my $lbl = eval { $rr->get_label };
            $lbl //= eval { $rr->name };
            push @dns, {
                id        => $rr->id,
                label     => $lbl // '',
                href      => Netdot::Mojo::Registry::set_uri( '/management/rr/' . $rr->id ),
                deletable => ( defined $name_rr && $rr->id != $name_rr ) ? 1 : 0,
            } if length( $lbl // '' );
        }

        my @svc;
        my @sv;
        eval { @sv = $ip->services };
        for my $s (@sv) {
            my $sn = eval { $s->service->name };
            push @svc, {
                id   => $s->id,
                name => $sn // '',
                href => Netdot::Mojo::Registry::set_uri( '/management/ipservice/' . $s->id ),
            } if length( $sn // '' );
        }

        my $parent = eval { $ip->parent };
        push @rows, {
            id        => $ip->id,
            address   => [ ( eval { $ip->address } // '' ),
                            Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $ip->id ) ],
            subnet    => $parent
                        ? [ ( eval { $parent->cidr } // eval { $parent->address } // '' ),
                             Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $parent->id ) ]
                        : [ '', '' ],
            iface     => $iface
                        ? [ ( eval { $iface->name } // '' ),
                             Netdot::Mojo::Registry::set_uri( '/management/interface/' . $iface->id ) ]
                        : [ '', '' ],
            dns       => \@dns,
            monitored => ( eval { $ip->monitored } ) ? 1 : 0,
            services  => \@svc,
            iface_id  => $iface_id,
        };
    }

    return {
        view         => 'IP',
        rows         => \@rows,
        sort_base    => Netdot::Mojo::Registry::set_uri( "/management/device/$id?view=IP" ),
        sort_param   => 'ipsort',
        sort         => $ipsort,
        empty_msg    => 'This device has no IP addresses.',
        editips      => $editips,
        add_ip       => $add_ip,
        can_edit     => $can_edit,
        showvlan     => $showvlan,
        int_opts     => \@int_opts,
        svc_opts     => \@svc_opts,
        cl_opts      => \@cl_opts,
        cl_def       => $cl_def,
    };
}

sub _bgp_view {
    my ( $o, $c, $id ) = @_;
    my %ok       = map { $_ => 1 } qw(ip id state);
    my $peersort = $c->param('peersort') || 'ip';
    $peersort    = 'ip' unless $ok{$peersort};
    my $can_edit   = $c->perm( 'edit', $o );
    my $editbgp    = $c->param('editbgp')   ? 1 : 0;
    my $editdevbgp = $c->param('editdevbgp') ? 1 : 0;
    my $addpeer    = $c->param('addpeer')   ? 1 : 0;

    my $localas = eval { $o->bgplocalas };
    my $bgpid   = eval { $o->bgpid };
    my $whois   = eval { Netdot->config->get( 'BGP_AS_WHOIS_URL' ) };

    # Mason: show the iBGP and eBGP sections; "all" only when both are empty
    # (happens when the device's local AS is not set).
    my $ipeers = eval { $o->get_bgp_peers( type => 'internal', sort => $peersort ) };
    $ipeers = [] if $@ || !ref $ipeers;
    my $epeers = eval { $o->get_bgp_peers( type => 'external', sort => $peersort ) };
    $epeers = [] if $@ || !ref $epeers;
    my $allpeers;
    if ( !@$ipeers && !@$epeers ) {
        $allpeers = eval { $o->get_bgp_peers( type => 'all', sort => $peersort ) };
        $allpeers = [] if $@ || !ref $allpeers;
    }

    # Contact lists + entities for the per-peer selects (edit/add modes).
    my ( @cl_opts, @ent_opts );
    eval {
        my @cls = ContactList->retrieve_all;
        @cl_opts =
            map  { [ $_->id, ( $_->name // '' ) ] }
            grep { $_ }
            sort { ( $a->name // '' ) cmp ( $b->name // '' ) } @cls;
        my @ents = Entity->retrieve_all;
        @ent_opts =
            map  { [ $_->id, ( $_->name // '' ) ] }
            grep { $_ }
            sort { ( $a->name // '' ) cmp ( $b->name // '' ) } @ents;
    };

    # Remote IP: link each peer address to its /32 ipblock when that address is a
    # Netdot block (Ipblock->search(address=>..)); memoised per address.
    my %ip_cache;
    my $ip_link = sub {
        my ($addr) = @_;
        return [ ( $addr // '' ), '' ] unless defined $addr && length $addr;
        return $ip_cache{$addr} if exists $ip_cache{$addr};
        my $ipb = eval { Ipblock->search( address => $addr )->first };
        $ip_cache{$addr} = $ipb
            ? [ $addr, Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $ipb->id ) ]
            : [ $addr, '' ];
        return $ip_cache{$addr};
    };

    # One row hash per peer (Mason columns). AS Number links to the configured
    # whois URL; eBGP skips the private ASN range 64512-65535 (Mason).
    my $peer_row = sub {
        my ($p, $ext) = @_;
        my $ent    = eval { $p->entity };
        my $asn    = eval { $ent->asnumber };
        my $ahref  = '';
        if ( $whois && defined $asn
             && !( $ext && $asn >= 64512 && $asn <= 65535 ) ) {
            $ahref = $whois;
            $ahref =~ s{<ASNUMBER>}{$asn}g;
        }
        my $cl   = eval { $p->contactlist };
        return {
            id        => $p->id,
            addr      => $ip_link->( eval { $p->bgppeeraddr } ),
            pid       => ( eval { $p->bgppeerid } // '' ),
            entity    => $ent
                        ? [ ( eval { $ent->name } // '' ),
                             Netdot::Mojo::Registry::set_uri( '/management/entity/' . $ent->id ) ]
                        : [ '', '' ],
            asname    => ( eval { $ent->asname } // '' ),
            asn       => [ ( defined $asn ? $asn : '' ), $ahref ],
            state     => ( eval { $p->state } // '' ),
            monitored => ( eval { $p->monitored } ) ? 1 : 0,
            contactlist => $cl
                        ? [ $cl->id, ( eval { $cl->name } // '' ),
                             Netdot::Mojo::Registry::set_uri( '/management/contactlist/' . $cl->id ) ]
                        : [ undef, '', '' ],
        };
    };

    my @rows;    # section markers + peer row hashes
    if ( @$epeers ) {
        push @rows, { section => 'External (eBGP)' };
        push @rows, map { $peer_row->( $_, 1 ) } @$epeers;
        push @rows, { section => '' };    # Mason's spacer row
    }
    if ( @$ipeers ) {
        push @rows, { section => 'Internal (iBGP)' };
        push @rows, map { $peer_row->( $_, 0 ) } @$ipeers;
    }
    if ( !@rows && defined $allpeers ) {
        push @rows, map { $peer_row->( $_, 1 ) } @$allpeers;
    }

    return {
        view        => 'BGP',
        rows        => \@rows,
        can_edit    => $can_edit,
        editbgp     => $editbgp,
        editdevbgp  => $editdevbgp,
        addpeer     => $addpeer,
        bgpid       => ( defined $bgpid ? $bgpid : '' ),
        localas     => $localas
                    ? { id     => $localas->id,
                        number => ( eval { $localas->number } // '' ),
                        href   => ( Netdot::Mojo::Registry::link_for( $localas ) )[1] // '' }
                    : undef,
        peer_type   => ( @$ipeers || @$epeers ) ? '' : 'all',
        sort_base   => Netdot::Mojo::Registry::set_uri( "/management/device/$id?view=BGP" ),
        sort_param  => 'peersort',
        sort        => $peersort,
        cl_opts     => \@cl_opts,
        ent_opts    => \@ent_opts,
        empty_msg   => 'This device has no BGP peers.',
    };
}

sub _hosted_view {
    my ( $o, $c, $id ) = @_;
    my @hd = ();
    eval { @hd = $o->hosted_devices };
    my @rows;
    for my $h (@hd) {
        my $hname = _lk( eval { $h->name } );
        push @rows, [
            [ [ $hname->[0], Netdot::Mojo::Registry::set_uri( "/management/device/" . $h->id ) ] ],
            [ [ ( eval { $h->http_addr } // '' ), 'http://' . ( eval { $h->http_addr } // '' ) ] ],
            [ [ ( eval { $h->https_addr } // '' ), 'https://' . ( eval { $h->https_addr } // '' ) ] ],
        ];
    }
    return {
        view      => 'Hosted',
        cols      => [ [ 'Name', undef ], [ 'HTTP', undef ], [ 'HTTPS', undef ] ],
        rows      => \@rows,
        empty_msg => 'No hosted devices.',
    };
}

sub _circuits_view {
    my ( $o, $c, $id ) = @_;
    my @c = ();
    eval { @c = $o->get_circuits };
    my @rows;
    for my $ci (@c) {
        push @rows, [
            [ [ ( eval { $ci->cid } // '' ), '' ] ],
            [ [ ( eval { $ci->type } // '' ), '' ] ],
            [ [ ( eval { $ci->vendor } // '' ), '' ] ],
            [ [ ( eval { $ci->status } // '' ), '' ] ],
            [ [ ( eval { $ci->speed } // '' ), '' ] ],
        ];
    }
    return {
        view      => 'Circuits',
        cols      => [
            [ 'Circuit ID', undef ], [ 'Type', undef ], [ 'Provider', undef ],
            [ 'Status', undef ], [ 'Speed', undef ],
        ],
        rows      => \@rows,
        empty_msg => 'No circuits.',
    };
}

sub _stp_view {
    my ( $o, $c, $id ) = @_;
    my @info;
    push @info, [ 'STP Enabled', ( eval { $o->stp_enabled } ) ? 'yes' : 'no', '' ];
    push @info, [ 'STP Type',    _fmt( eval { $o->stp_type } ), '' ];

    my @stp = ();
    eval { @stp = $o->stp_instances };
    my @rows;
    for my $s (@stp) {
        push @rows, [
            [ [ ( eval { $s->number } // '' ), '' ] ],
            [ [ ( eval { $s->root_bridge } // '' ), '' ] ],
            [ [ ( eval { $s->root_port } // '' ), '' ] ],
            [ [ ( eval { $s->bridge_priority } // '' ), '' ] ],
        ];
    }
    return {
        view      => 'STP',
        info      => \@info,
        cols      => [
            [ 'Number', undef ], [ 'Root Bridge', undef ],
            [ 'Root Port', undef ], [ 'Bridge Priority', undef ],
        ],
        rows      => \@rows,
        empty_msg => 'No STP instances.',
    };
}

sub _modules_view {
    my ( $o, $c, $id ) = @_;
    my @m = ();
    eval { @m = $o->modules };
    my @rows;
    for my $mod (@m) {
        push @rows, [
            [ [ ( eval { $mod->number } // '' ), '' ] ],
            [ [ ( eval { $mod->name } // '' ), '' ] ],
            [ [ ( eval { $mod->description } // '' ), '' ] ],
        ];
    }
    return {
        view      => 'Modules',
        cols      => [ [ 'Number', undef ], [ 'Name', undef ], [ 'Description', undef ] ],
        rows      => \@rows,
        empty_msg => 'No modules.',
    };
}

# ---------------------------------------------------------------------------
# ARP / FWT views (port of the legacy device.html sections): the device's
# ARP caches / forwarding tables (ArpCache / FWTable objects, tstamp DESC),
# each row linked to the object's detail page.
# ---------------------------------------------------------------------------
sub _cache_view {
    my ( $o, $c, $view, $objs ) = @_;
    my ( $type, $empty ) =
        $view eq 'ARP' ? ( 'arpcache', 'No ARP caches.' )
                      : ( 'fwtable',  'No forwarding tables.' );
    my @rows;
    for my $a (@$objs) {
        my $aid = eval { $a->id };
        my $dev = eval { $a->device };
        my $did = eval { $dev->id };
        push @rows, [
            [ [ _fmt( eval { $a->tstamp } ),
                $aid ? $c->set_uri( '/management/' . $type . '/' . $aid ) : '' ] ],
            [ [ ( eval { $dev->short_name } || '' ),
                $did ? $c->set_uri( '/management/device/' . $did ) : '' ] ],
        ];
    }
    return {
        view      => $view,
        cols      => [ [ 'Tstamp', undef ], [ 'Device', undef ] ],
        rows      => \@rows,
        empty_msg => $empty,
    };
}

# ---------------------------------------------------------------------------
# Topology view (port of the legacy device.html "Topology" section +
# Netdot::UI::build_device_topology_graph[_html]): the Layer-2 topology as a
# GraphViz "dot" graph — nodes = devices (click -> device page, keeping the
# Topology parameters), edges = L2 links (click -> interface pages, colored
# per VLAN, dashed when STP-blocking). The PNG is generated on the fly and
# embedded as a data: URI (Mason wrote htdocs/img/graphs/); the GraphViz
# image map (as_cmapx) makes the nodes/edges clickable.
# ---------------------------------------------------------------------------
sub _topology_view {
    my ( $o, $c, $id ) = @_;

    # The graph render (dot) can take minutes on a deep/large topology; the
    # server's default 30 s per-connection inactivity timeout would truncate
    # such a slow, large response (first 128 KiB of socket buffer only).
    $c->inactivity_timeout(900);

    # Form parameters (Mason's change_topo_view_form, same names).
    my $p_int = sub {
        my $v = $c->param( shift );
        return ( defined $v && $v =~ /^\d+$/ ) ? $v + 0 : 0;
    };
    my $depth_up   = $p_int->('topodepth_up')   || 1;
    my $depth_down = $p_int->('topodepth_down') || 1;
    my $show_vlans = $c->param('topovlans') ? 1 : 0;
    my $show_names = $c->param('toponames') ? 1 : 0;
    my $minlen     = $p_int->('topominlen')     || 1;
    my $svid       = $p_int->('specific_vlan');
    my $root_name  = $c->param('toporoot');
    unless ( defined $root_name && length $root_name ) {
        $root_name = Netdot::Model->config->get('NMS_DEVICE') // '';
    }
    $root_name =~ s/^\s+|\s+$//g;

    # The "Show this Vlan only?" select: this device's VLANs. (Mason filled
    # it from the Interfaces view render, which left it empty on a direct
    # ?view=Topology request.)
    my ( %vseen, @vlan_opts );
    eval {
        for my $i ( @{ $o->interfaces } ) {
            for my $iv ( @{ $i->vlans } ) {
                my $vid = eval { $iv->vlan->vid };
                next unless defined $vid && $vid != 0;
                next if $vseen{ $vid }++;
                push @vlan_opts, $vid;
            }
        }
    };
    @vlan_opts = sort { $a <=> $b } @vlan_opts;

    my $d = {
        view            => 'Topology',
        topo_depth_up   => $depth_up,
        topo_depth_down => $depth_down,
        topo_vlans      => $show_vlans,
        topo_names      => $show_names,
        topo_minlen     => $minlen,
        topo_root       => $root_name,
        topo_svid       => $svid,
        topo_vlan_opts  => \@vlan_opts,
        topo_error      => '',
        topo_img        => '',
        topo_map        => '',
        topo_legend     => [],
    };

    # Root device: by name (Mason), or the device itself when left empty
    # (Mason's default NMS_DEVICE is unset in this deployment, where
    # Device->search(name=>undef) would have picked the first device).
    my $root = $o;
    if ( length $root_name ) {
        $root = eval { Device->search( name => $root_name )->first };
        $d->{topo_error} = "Cannot find root device: $root_name"
            unless $root && !$@;
    }
    return $d if $d->{topo_error};

    my ( $g, $bytes, $vlans ) =
        _topology_graph(
            id            => $id,
            root          => $root->id,
            depth_up      => $depth_up,
            depth_down    => $depth_down,
            show_vlans    => $show_vlans,
            show_names    => $show_names,
            minlen        => $minlen,
            specific_vlan => $svid,
        );
    if ( !$g ) {
        $d->{topo_error} = $bytes;
        return $d;
    }
    $d->{topo_img}    = 'data:image/png;base64,' . b64_encode( $bytes );
    $d->{topo_map}    = $g->as_cmapx;
    $d->{topo_legend} = [
        map {
            [ $_, $vlans->{$_}{color},
              Netdot::Mojo::Registry::set_uri( '/management/vlan/' . $vlans->{$_}{vlan} ) ]
        } sort keys %$vlans
    ] if $show_vlans;
    return $d;
}

# Graph builder: port of Netdot::UI::build_device_topology_graph.
# Returns ( $g, $png_bytes, \%vlans ) or ( undef, $error_message ).
sub _topology_graph {
    my (%a) = @_;
    my ( $id, $root, $depth_up, $depth_down, $show_vlans, $show_names,
         $minlen, $specific_vlan ) =
        @a{ qw(id root depth_up depth_down show_vlans show_names
               minlen specific_vlan) };

    # Guard against malicious input (same as Mason).
    $depth_up   = ( int( $depth_up   || 0 ) > 0 ) ? int $depth_up   : 0;
    $depth_down = ( int( $depth_down || 0 ) > 0 ) ? int $depth_down : 0;
    $show_vlans = ( $show_vlans == 1 ) ? 1 : 0;
    $show_names = ( $show_names == 1 ) ? 1 : 0;
    $minlen     ||= 1;
    $root      ||= $id;
    if ( !defined $specific_vlan || $specific_vlan == 0 || $show_vlans == 0 ) {
        $specific_vlan = undef;
    }
    if ( defined $specific_vlan && $specific_vlan != 0 ) {
        $show_vlans = 1;
    }

    my $g = GraphViz->new(
        layout    => 'dot',
        truecolor => 1,
        bgcolor   => '#ffffff00',
        ranksep   => 2.0,
        node      => { shape => 'record', fillcolor => '#ffffff88',
                       style => 'filled',  fontsize => 10,    height => .25 },
        edge      => { dir => 'none', labelfontsize => 8, minlen => $minlen },
        rankdir   => 1,    # as in Mason (no 'direction' arg passed)
    );

    # Neighbouring-interface map + shortest paths to the root (model
    # methods; the latter is a Dijkstra and decides the up/down direction
    # of each edge).
    my $igraph = Device->get_device_i_graph();
    my $spp    = Device->shortest_path_parents( $root );

    # Bulk-load everything the traversal needs (one query per table) so the
    # DFS never hits the DB per edge — on a large network that N+1 pattern
    # (per-edge interface retrieve + per-VLAN interfacevlan search) is what
    # made the legacy inline render take minutes.
    my $B = _topo_bulk_data( $igraph );

    # The start device's label (RR name); it is not in the bulk data when the
    # device has no L2 link at all -> one fallback lookup.
    my $start_label = $B->{devlabel}{ $id }
        // eval { Device->retrieve( $id )->short_name };
    _topo_add_node( $g, $id, $start_label, $show_names, $show_vlans,
                    { color => 'red' } );

    my $vlans = {};
    my $seen  = { NODE => {}, EDGE => {} };
    $seen->{NODE}{ $id } = 1;

    # Mason: when one of the two depths is 0 it used the (unpassed, i.e. 0)
    # unified $depth for both -> no traversal (single-node graph). Kept as-is.
    my ( $hopup, $hopdown ) =
        ( $depth_up && $depth_down ) ? ( $depth_up, $depth_down ) : ( 0, 0 );
    _topo_dfs( $g, $igraph, $spp, $root, $id,
               $hopup, $hopdown, 'undef', $seen, $vlans,
               $show_vlans, $show_names, $specific_vlan, $B );

    # PNG: GraphViz needs a file name, so render into a temp file, read the
    # bytes back (served as a data: URI — no file left on disk).
    my ( $fh, $name ) = tempfile( SUFFIX => '.png', UNLINK => 1 );
    my ( $bytes, $ok );
    $ok = eval {
        $g->as_png( $name );
        open my $rfh, '<', $name or die $!;
        local $/;
        $bytes = <$rfh>;
        close $rfh;
        1;
    };
    close $fh;
    return ( undef, "Could not render the topology graph: $@" )
        unless $ok && defined $bytes && length $bytes;
    return ( $g, $bytes, $vlans );
}

# Bulk pre-fetch for the traversal: interface (number/name/device),
# interface VLANs (vid/name/stp_state) and device labels (RR name) — one
# query per table (the interfacevlan/vlan pair in a single join). Only the
# interfaces and devices present in the L2 graph are indexed. Returns:
#   ifaces   : iface id  => { number, name, device }
#   ifvlans  : iface id  => { vid => { vlan, name, stp } }
#   devlabel : device id => RR name (undef when the device has no RR — the
#              legacy short_name() dies there; we degrade to '#<id>' instead)
sub _topo_bulk_data {
    my ($igraph) = @_;

    my ( %iids, %devids );
    for my $did ( keys %$igraph ) {
        $devids{ $did } = 1;
        for my $iid ( keys %{ $igraph->{ $did } } ) {
            $iids{ $iid } = 1;
            $iids{ $igraph->{ $did }{ $iid } } = 1;
        }
    }

    my $dbh = Device->db_Main;
    my ( %ifaces, %ifvlans, %devlabel );

    # Interface number/name/device, in chunks (placeholder-bound IN lists).
    {
        my @ids = sort { $a <=> $b } keys %iids;
        for ( my $i = 0; $i < @ids; $i += 1000 ) {
            my @chunk = @ids[ $i .. ( $i + 999 <= $#ids ? $i + 999 : $#ids ) ];
            my $sth = $dbh->prepare(
                "SELECT id, number, name, device FROM interface WHERE id IN ("
                . join( ',', ('?') x @chunk ) . ")" );
            $sth->execute(@chunk);
            while ( my ( $iid, $num, $nm, $dev ) = $sth->fetchrow_array ) {
                $ifaces{ $iid } = { number => $num, name => $nm,
                                    device => $dev };
            }
        }
    }

    # Interface VLANs: one join over the whole (small) interfacevlan table,
    # indexed only for the interfaces in the graph.
    {
        my $sth = $dbh->prepare(
            "SELECT iv.interface, v.vid, v.name, iv.stp_state, v.id
             FROM   interfacevlan iv JOIN vlan v ON iv.vlan = v.id" );
        $sth->execute;
        while ( my ( $iid, $vid, $vname, $stp, $vlan_id )
               = $sth->fetchrow_array )
        {
            next unless $iids{ $iid };
            $ifvlans{ $iid }{ $vid } = { vlan => $vlan_id, name => $vname,
                                         stp => $stp };
        }
    }

    # Device label = RR name (device.name is the FK into rr.id).
    {
        my @ids = sort { $a <=> $b } keys %devids;
        for ( my $i = 0; $i < @ids; $i += 1000 ) {
            my @chunk = @ids[ $i .. ( $i + 999 <= $#ids ? $i + 999 : $#ids ) ];
            my $sth = $dbh->prepare(
                "SELECT d.id, r.name
                 FROM   device d LEFT JOIN rr r ON d.name = r.id
                 WHERE  d.id IN (" . join( ',', ('?') x @chunk ) . ")" );
            $sth->execute(@chunk);
            while ( my ( $did, $rname ) = $sth->fetchrow_array ) {
                $devlabel{ $did } = $rname;
            }
        }
    }

    return { ifaces => \%ifaces, ifvlans => \%ifvlans, devlabel => \%devlabel };
}

# One node = one device (label = short name, click -> device page keeping
# the Topology parameters, the starting device in red).
sub _topo_add_node {
    my ( $g, $did, $label, $show_names, $show_vlans, $nodeoptions ) = @_;
    $nodeoptions ||= {};
    $g->add_node(
        $did,
        label => ( $label || '#' . $did ),
        shape => 'record',
        URL   => Netdot::Mojo::Registry::set_uri(
            '/management/device/' . $did
            . '?view=Topology&toponames=' . $show_names
            . '&topovlans=' . $show_vlans ),
        %$nodeoptions,
    );
}

# Deterministic color per VLAN (port of Mason's _vlancolor): the low-order
# bits at the top, so numerically adjacent vids contrast, vid=1 is black.
sub _vlancolor {
    my ($vid) = @_;
    my @b = reverse( split( '', sprintf( '%012b', 4097 - $vid ) ) );
    return sprintf(
        '#%02X%02X%02X',
        oct("0b$b[0]$b[3]$b[6]$b[9]000"),
        oct("0b$b[1]$b[4]$b[7]$b[10]000"),
        oct("0b$b[2]$b[5]$b[8]$b[11]000"));
}

# Depth-first traversal (port of Mason's _dfs): one edge per L2 link,
# colored per VLAN (dashed when STP-blocking), directed toward the root
# when the neighbour is closer to it (shortest_path_parents).
# Runs entirely on the bulk data ($B) — no DB access per edge.
sub _topo_dfs {
    my ( $g, $igraph, $spp, $root, $device_id, $hopup, $hopdown, $prev_dir,
         $seen, $vlans, $show_vlans, $show_names, $specific_vlan, $B ) = @_;
    return if ( $hopup == 0 && $prev_dir eq 'up' );
    return if ( $hopdown == 0 && $prev_dir eq 'down' );
    return unless ( $hopup || $hopdown );

    my $adj = $igraph->{ $device_id };
    return unless $adj && %$adj;

    my ( $if, $ifv, $dl ) = ( $B->{ifaces}, $B->{ifvlans}, $B->{devlabel} );

    my $dir;
    for my $iid ( sort { $a <=> $b } keys %$adj ) {
        my $niid = $adj->{$iid};
        my $mi   = $if->{ $iid };
        my $ni   = $if->{ $niid };
        next unless $mi && $ni;

        my $name          =
            ( $show_names ? $mi->{name} : $mi->{number} ) || $mi->{number};
        my $neighbor_name =
            ( $show_names ? $ni->{name} : $ni->{number} ) || $ni->{number};

        my $nd = $ni->{device};
        next unless defined $nd;
        my ( $from, $to, $head, $tail, $constraint ) = ( 'from', 'to', 'head', 'tail', 1 );

        if ( exists( $spp->{ $device_id }{ $nd } ) ) {
            # Neighbour is closer to root
            $dir = 'up';
            ( $from, $to, $head, $tail ) = ( 'to', 'from', 'tail', 'head' );
        }
        elsif ( exists( $spp->{ $nd }{ $device_id } ) ) {
            # The opposite
            $dir = 'down';
        }
        else {
            $dir        = 'level';
            $constraint = 0;
        }
        my $add_node = 0;

        # If we haven't seen this edge before, add it to the graph
        next if exists $seen->{EDGE}{ $niid . ' ' . $iid };
        $seen->{EDGE}{ $niid . ' ' . $iid } = 1;
        $seen->{EDGE}{ $iid . ' ' . $niid } = 1;

        my $cont    = 0;
        my $myvlans = $ifv->{ $iid };
        my $nvlans  = $ifv->{ $niid };
        if ( $show_vlans && $myvlans && %$myvlans ) {
            for my $vid ( sort { $a <=> $b } keys %$myvlans ) {
                next if ( defined $specific_vlan && $specific_vlan != $vid );
                my $mv = $myvlans->{ $vid };
                my $nv = $nvlans ? $nvlans->{ $vid } : undef;
                # Legacy searched the neighbour's row for the SAME vlan
                # object; a hit therefore always carries the same vid, so
                # "does the neighbour carry this vid?" is the equivalent
                # membership test.
                next if ( defined $specific_vlan && $specific_vlan != 0
                           && !$nv );

                my $vname = $mv->{name} || $vid;
                if ( !exists $vlans->{ $vname } ) {
                    $vlans->{ $vname } =
                        { color => _vlancolor( $vid ),
                          vlan  => $mv->{vlan} };
                }
                my $color = $vlans->{ $vname }{color};

                my $style = 'solid';
                if ( ( $mv->{stp} // '' ) eq 'blocking'
                     || ( $nv && ( $nv->{stp} // '' ) eq 'blocking' ) )
                {
                    $style = 'dashed';
                }

                $g->add_edge(
                    $from          => $device_id,
                    $to            => $nd,
                    constraint     => $constraint,
                    "${tail}URL"   =>
                        Netdot::Mojo::Registry::set_uri(
                            '/management/interface/' . $iid ),
                    "${tail}label" =>
                        ( defined $specific_vlan && $specific_vlan != 0 )
                        ? $name : $vname,
                    "${head}URL"   =>
                        Netdot::Mojo::Registry::set_uri(
                            '/management/interface/' . $niid ),
                    "${head}label" => $neighbor_name,
                    color         => $color,
                    style         => $style,
                );
                $add_node = 1;
                $cont     = 1;
            }
        }
        else {
            if ( !defined $specific_vlan || $specific_vlan == 0 ) {
                $g->add_edge(
                    $from          => $device_id,
                    $to            => $nd,
                    constraint     => $constraint,
                    "${tail}URL"   =>
                        Netdot::Mojo::Registry::set_uri(
                            '/management/interface/' . $iid ),
                    "${tail}label" => $name,
                    "${head}URL"   =>
                        Netdot::Mojo::Registry::set_uri(
                            '/management/interface/' . $niid ),
                    "${head}label" => $neighbor_name,
                    color         => 'black',
                );
                $add_node = 1;
                $cont     = 1;
            }
        }

        # Also make sure we haven't seen this node before
        if ( $add_node == 1 && !exists $seen->{NODE}{ $nd } ) {
            _topo_add_node( $g, $nd, $dl->{ $nd }, $show_names, $show_vlans );
            $seen->{NODE}{ $nd } = 1;
        }

        # If we're at our root, we're done...
        if ( $root == $nd ) {
            $cont = 0;
        }

        # If we haven't recursed across this edge before, then do so now.
        if ( $cont == 1 ) {
            if ( $dir eq 'up' ) {
                _topo_dfs( $g, $igraph, $spp, $root, $nd,
                           $hopup - 1, $hopdown, $dir, $seen, $vlans,
                           $show_vlans, $show_names, $specific_vlan, $B );
            }
            elsif ( $dir eq 'down' ) {
                _topo_dfs( $g, $igraph, $spp, $root, $nd,
                           $hopup, $hopdown - 1, $dir, $seen, $vlans,
                           $show_vlans, $show_names, $specific_vlan, $B );
            }
            else {
                _topo_dfs( $g, $igraph, $spp, $root, $nd,
                           $hopup - 1, $hopdown - 1, $dir, $seen, $vlans,
                           $show_vlans, $show_names, $specific_vlan, $B );
            }
        }
    }
}

sub _audit_view {
    my ( $o, $c, $id ) = @_;
    my @a = ();
    eval { @a = $o->get_audit_records };
    my @rows;
    for my $rec (@a) {
        push @rows, [
            [ [ _fmt( eval { $rec->tstamp } ), '' ] ],
            [ [ ( eval { $rec->username } // '' ), '' ] ],
            [ [ ( eval { $rec->operation } // '' ), '' ] ],
            [ [ ( eval { $rec->label } // '' ), '' ] ],
        ];
    }
    return {
        view      => 'Audit',
        cols      => [ [ 'Date', undef ], [ 'User', undef ], [ 'Operation', undef ], [ 'Target', undef ] ],
        rows      => \@rows,
        empty_msg => 'No audit records.',
    };
}

# Rights view: who holds which access rights on this device (read-only port of
# the Mason list_rights.mhtml / device.html "Rights" view). AccessRight->search
# (object_class=>'Device', object_id) yields the AccessRight rows; each expands
# to UserRight (person) / GroupRight (contactlist) via user_rights/group_rights.
# Rows are grouped by subject name; rights joined as display names.
sub _rights_view {
    my ( $o, $c, $id ) = @_;
    # Mason: the section is visible to access_section('device.html:edit_rights');
    # only Admin may grant/revoke (the legacy add form required Admin too).
    my $can_rights = $c->perm( 'access_section', 'device.html:edit_rights' );
    return {
        view => 'Rights', can_rights => 0, rights => [],
        empty_msg => 'No access rights for this device.',
    } unless $can_rights;
    my $can_rights_edit = ( $c->user_type eq 'Admin' );

    my %anames = ( view => 'View', edit => 'Edit', delete => 'Delete',
                   choose_ip => 'Choose IP', none => 'None' );
    my @arights;
    eval { @arights = AccessRight->search( object_class => 'Device', object_id => $id ) };
    @arights = () if $@;
    my @rows;
    for my $ar (@arights) {
        my $access = $ar->access;
        my @sub;
        my @ur = eval { $ar->user_rights  }; @ur = () if $@;
        my @gr = eval { $ar->group_rights }; @gr = () if $@;
        for my $r (@ur) {
            my $s = eval { $r->person };
            push @sub, { type => 'user',  subj => $s, right_id => $r->id, right_table => 'userright' } if $s;
        }
        for my $r (@gr) {
            my $s = eval { $r->contactlist };
            push @sub, { type => 'group', subj => $s, right_id => $r->id, right_table => 'groupright' } if $s;
        }
        for my $e (@sub) {
            my $label = eval { $e->{subj}->get_label } // '';
            my $table = $e->{type} eq 'user' ? 'person' : 'contactlist';
            my $href  = Netdot::Mojo::Registry::set_uri( "/management/$table" ) . '/' . $e->{subj}->id;
            push @rows, {
                type         => $e->{type},
                name         => $label,
                subject_html => '<a href="' . $href . '">' . _esc( $label ) . '</a>',
                access       => $access,
                access_name  => $anames{ $access } // $access,
                del_subject  => $e->{type} . ':' . $e->{subj}->id,
                right_id     => $e->{right_id},
                right_table  => $e->{right_table},
            };
        }
    }
    @rows = sort {
        $a->{type} cmp $b->{type}
            || $a->{name} cmp $b->{name}
            || $a->{access} cmp $b->{access}
    } @rows;

    # Subjects for the "Add rights" form (loaded only when the user may write).
    my ( @right_users, @right_groups );
    if ( $can_rights_edit ) {
        eval {
            my @ps = Person->retrieve_all;
            @right_users =
                map  { [ $_->id, ( eval { $_->get_label } // '' ) ] }
                grep { $_ }
                sort { ( eval { $a->get_label } // '' ) cmp ( eval { $b->get_label } // '' ) } @ps;
            my @cls = ContactList->retrieve_all;
            @right_groups =
                map  { [ $_->id, ( $_->name // '' ) ] }
                grep { $_ }
                sort { ( $a->name // '' ) cmp ( $b->name // '' ) } @cls;
        };
    }

    return {
        view            => 'Rights',
        can_rights      => 1,
        can_rights_edit => $can_rights_edit ? 1 : 0,
        rights          => \@rows,
        right_users     => \@right_users,
        right_groups    => \@right_groups,
        empty_msg       => 'No access rights for this device.',
    };
}

# HTML-escape for user-visible labels (names come from the DB).
sub _esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
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