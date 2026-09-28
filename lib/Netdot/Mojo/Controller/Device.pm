package Netdot::Mojo::Controller::Device;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;
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

    my $view = $c->param('view') || 'Basics';
    my %views = map { $_ => 1 } qw(Basics Interfaces);
    $view = 'Basics' unless $views{$view};

    my ($name, $fqdn) = ('', '');
    my $rr = eval { $o->name };
    if ($rr) {
        $name = eval { $rr->name } // '';
        my $zone = eval { $rr->zone->name } // '';
        $fqdn   = ( $name && $zone ) ? "$name.$zone" : $name;
    }
    $fqdn = "Device #$id" unless length $fqdn;

    my %stash = (
        id    => $id,
        view  => $view,
        fqdn  => $fqdn,
        title => "Device $fqdn",
    );

    if ($view eq 'Basics') {
        $stash{sections} = _basics($o);
    } else {
        my $d = _interfaces($o, $c, $id);
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
    for ( my $i = 0; $i < @$list; $i += $n ) {
        my $end = $i + $n - 1;
        $end = $#$list if $end > $#$list;
        push @rows, [ @$list[ $i .. $end ] ];
    }
    return \@rows;
}

# Friendly label for a column (from the meta tag).
sub _tag {
    my ($col) = @_;
    my $tag = eval { Device->meta_data->get_column($col)->tag };
    return ( defined $tag && length $tag ) ? $tag : $col;
}

# [ tag, text, href ] for a device column. Sensitive columns are masked.
sub _kv {
    my ( $o, $col ) = @_;
    if ( Netdot::Mojo::Registry::is_sensitive($col) ) {
        return [ _tag($col), '\x{2022}\x{2022}\x{2022}\x{2022}\x{2022}', undef ];
    }
    my $v = eval { $o->$col };
    $v    = undef if $@;
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
    $text = '' unless defined $text;
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
        my $ihref = "/management/interface/$i";

        my @vp;
        if ( exists $ifvlans{$i} ) {
            for my $vid ( sort { $a <=> $b } keys %{ $ifvlans{$i} } ) {
                push @vp, Netdot::Mojo::Registry::link_for( $ifvlans{$i}{$vid} );
            }
        }

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
                        if ( $ip->{rrid} ) { $t = $ip->{fqdn};  $h = "/management/rr/$ip->{rrid}"; }
                        else               { $t = $ip->{address}; $h = "/management/ipblock/$ip_id"; }
                        next if $seen{$t}++;
                        push @conn, [ $t, $h ];
                    }
                } else {
                    push @conn, [ $e->{mac}, "/management/physaddr/$mac_id" ];
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
            vlans  => \@vp,
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
        sort_base => "/management/device/$id?view=Interfaces",
    };
}

1;
