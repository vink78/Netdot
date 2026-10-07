package Netdot::Mojo::Controller::Device;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;
use Netdot::Model::Device;

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
    my %stash = (
        id       => $id,
        view     => $view,
        fqdn     => $fqdn,
        title    => "Device $fqdn",
        can_edit => $can_edit,
        fields   => [],
        api_path => '',
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

        push @rows, {
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
        show_jack => $present{jack} ? 1 : 0,
        show_desc => $present{desc} ? 1 : 0,
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
    my $r = eval { $o->get_ips( sort_by => $ipsort ) };
    $r = [] if $@ || !ref $r;
    my @ips = @$r;

    my @rows;
    for my $ip (@ips) {
        my @dns;
        my @ar;
        eval { @ar = $ip->a_records };
        for my $a (@ar) {
            my $rr  = eval { $a->rr };
            next unless $rr;
            my $lbl = eval { $rr->get_label };
            $lbl //= eval { $rr->name };
            push @dns, [ $lbl // '', Netdot::Mojo::Registry::set_uri( "/management/rr/" . $rr->id ) ] if length( $lbl // '' );
        }

        my @svc;
        my @sv;
        eval { @sv = $ip->services };
        for my $s (@sv) {
            my $sn = eval { $s->name };
            push @svc, [ $sn // '', '' ] if length( $sn // '' );
        }

        my $parent = eval { $ip->parent };
        my $iface  = eval { $ip->interface };

        push @rows, [
            [ [ ( eval { $ip->address } // '' ), Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $ip->id ) ] ],
            $parent
              ? [ [ ( eval { $parent->cidr } // eval { $parent->address } // '' ),
                    Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $parent->id ) ] ]
              : [ [ '', '' ] ],
            $iface ? [ [ ( eval { $iface->name } // '' ), Netdot::Mojo::Registry::set_uri( "/management/interface/" . $iface->id ) ] ] : [ [ '', '' ] ],
            _ml(@dns),
            [ [ ( eval { $ip->monitored } ) ? 'yes' : 'no', '' ] ],
            _ml(@svc),
        ];
    }

    return {
        view         => 'IP',
        cols         => [
            [ 'Address',      'address' ],
            [ 'Subnet',       undef ],
            [ 'Interface',    'interface' ],
            [ 'DNS Name(s)',  undef ],
            [ 'Monitored?',   undef ],
            [ 'Services',     undef ],
        ],
        rows         => \@rows,
        sort_base    => Netdot::Mojo::Registry::set_uri( "/management/device/$id?view=IP" ),
        sort_param   => 'ipsort',
        sort         => $ipsort,
        empty_msg    => 'This device has no IP addresses.',
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

1;
