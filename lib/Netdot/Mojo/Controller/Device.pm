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
        $stash{attrs}  = _device_attrs($o);
        $stash{custom} = _custom_attrs($o);
    } else {
        my $d = _interfaces($o, $c, $id);
        @stash{ keys %$d } = values %$d;
    }

    $c->render( template => 'management/device', layout => 'default', %stash );
}

# Main device attributes (all view) as [ tag, text, href ] rows — same logic as
# the generic detail page.
sub _device_attrs {
    my ($o) = @_;
    my @attrs;
    for my $cd ( @{ Netdot::Mojo::Registry::display_columns('Device') } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $o->$col };
        $v    = undef if $@;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        $text = '' unless defined $text;
        push @attrs, [ $tag, $text, $href ];
    }
    return \@attrs;
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
        push @out, [ $ntext, $val // '' ];
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
