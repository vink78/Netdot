package Netdot::Mojo::Controller::Device;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;
use Netdot::Mojo::Permissions;
use Netdot::Model::Device;
use Netdot::Util::Log;
use Log::Log4perl;

# Read-only Device detail page. Two views for now:
#   Basics     - device attributes (netdot.meta "all" view) + custom attributes
#   Interfaces - the interfaces table (read-only port of interfaces.mhtml)
# All edit/write functionality and the Topology/STP/Rights views are deferred.

sub show {
    my $c  = shift;
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Device->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $view = $c->param('view') || 'Basics';
    my %views = map { $_ => 1 }
        qw(Basics Interfaces IP BGP Hosted Circuits STP Modules Audit Rights);
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
    my %stash = (
        id       => $id,
        view     => $view,
        fqdn     => $fqdn,
        title    => "Device $fqdn",
        can_edit => $can_edit,
        fields   => [],
        api_path => '',
        can_delete => $can_delete,
        del_path   => $can_delete ? $c->web_prefix . '/api/device/' . $id : '',
        del_goto   => $can_delete ? Netdot::Mojo::Registry::set_uri( '/management/device' ) : '',
        can_discover => $can_discover,
    );

    if ($view eq 'Basics') {
        $stash{sections} = _basics($o);
        if ($can_edit) {
            $stash{fields}   = Netdot::Mojo::Detail::build_edit_fields( $o, 'Device' );
            $stash{api_path} = $c->web_prefix . '/api/device/' . $id;
        }
    } elsif ($view eq 'Interfaces') {
        my $d = _interfaces($o, $c, $id);
        @stash{ keys %$d } = values %$d;
    } else {
        my $d = _table_view($view, $o, $c, $id);
        @stash{ keys %$d } = values %$d;
    }

    $c->render( template => 'management/device', layout => 'default', %stash );
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

    my $localas = eval { $o->bgplocalas };
    my $bgpid   = eval { $o->bgpid };
    my @info;
    push @info, [ 'BGP ID', _fmt($bgpid), '' ] if defined $bgpid && length $bgpid;
    if ( $localas && ( eval { $localas->number } ) ) {
        my ( $at, $ah ) = @{ Netdot::Mojo::Registry::link_for( $localas ) };
        push @info, [ 'Local AS', $localas->number, $ah ];
    }

    my ( $peers, $ptype );
    for my $t ( qw(internal external all) ) {
        my $r = eval { $o->get_bgp_peers( type => $t, sort => $peersort ) };
        $r = [] if $@ || !ref $r;
        if ( @$r ) { $peers = $r; $ptype = $t; last; }
    }
    $peers = [] unless $peers;

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

    my @rows;
    for my $p (@$peers) {
        my $ent  = eval { $p->entity };
        my @cl;
        eval { @cl = $p->contactlist };
        my @clinks;
        for my $cl (@cl) {
            my $cn = eval { $cl->name };
            push @clinks, [ ( $cn || '#' . $cl->id ), Netdot::Mojo::Registry::set_uri( "/management/contactlist/" . $cl->id ) ];
        }
        push @rows, [
            [ $ip_link->( eval { $p->bgppeeraddr } ) ],
            [ [ ( eval { $p->bgppeerid } // '' ),   '' ] ],
            [ [ ( eval { $ent->name } // '' ),       '' ] ],
            [ [ ( eval { $ent->asname } // '' ),     '' ] ],
            [ [ ( eval { $ent->asnumber } // '' ), 'http://www.iana.org/assignments/autonomous-systems/autonomous-system-numbers' ] ],
            [ [ ( eval { $p->state } // '' ), '' ] ],
            _ml(@clinks),
        ];
    }

    return {
        view        => 'BGP',
        cols        => [
            [ 'Remote IP',   'ip' ],
            [ 'ID',          'id' ],
            [ 'Entity',      undef ],
            [ 'AS Name',     undef ],
            [ 'AS Number',   undef ],
            [ 'State',       'state' ],
            [ 'Contact List',undef ],
        ],
        rows        => \@rows,
        info        => \@info,
        peer_type   => $ptype // '',
        sort_base   => Netdot::Mojo::Registry::set_uri( "/management/device/$id?view=BGP" ),
        sort_param  => 'peersort',
        sort        => $peersort,
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
    my %anames = ( view => 'View', edit => 'Edit', delete => 'Delete',
                   choose_ip => 'Choose IP', none => 'None' );
    my @arights;
    @arights = eval { AccessRight->search( object_class => 'Device', object_id => $id ) };
    my %r;
    for my $ar (@arights) {
        my @ur  = eval { $ar->user_rights };
        my @gr  = eval { $ar->group_rights };
        my @sub = ( @ur, @gr );
        for my $right (@sub) {
            my $type = ( ref($right) =~ /User/ ) ? 'User' : 'Group';
            my $subj = ( $type eq 'User' ) ? eval { $right->person }
                                           : eval { $right->contactlist };
            next unless $subj;
            my $name = eval { $subj->get_label } // '';
            next unless length $name;
            $r{$name}{type}    = $type;
            $r{$name}{subject} = $subj;
            $r{$name}{rights}{ $ar->access } = 1;
        }
    }
    my @rows;
    for my $name ( sort keys %r ) {
        my $e     = $r{$name};
        my $table = $e->{type} eq 'User' ? 'person' : 'contactlist';
        my $href  =
            Netdot::Mojo::Registry::set_uri( "/management/$table" ) . '/' . $e->{subject}->id;
        my $rights = join( ', ', map { $anames{$_} // $_ } sort keys %{ $e->{rights} } );
        push @rows, [
            [ [ $e->{type}, '' ] ],
            [ [ $name, $href ] ],
            [ [ $rights, '' ] ],
        ];
    }
    return {
        view      => 'Rights',
        cols      => [ [ 'Type', undef ], [ 'Name', undef ], [ 'Rights', undef ] ],
        rows      => \@rows,
        empty_msg => 'No access rights for this device.',
    };
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