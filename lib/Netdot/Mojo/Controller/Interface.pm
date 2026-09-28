package Netdot::Mojo::Controller::Interface;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util  qw(url_escape);
use Netdot::Model;
use Netdot::Mojo::Registry;

# Detail page for a single interface — read-only port of interface.html: the
# interface attributes (netdot.meta "all" view), the VLANs, the forwarding-table
# and ARP entry timestamps (each linking to the FDB/ARP sub-view), the IP
# addresses, the neighbors, and the audit records.
sub show {
    my $c  = shift;
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Interface->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;

    my $dbh = Netdot::Model->db_Main;

    # Main attributes (all view) — same logic as the generic detail.
    my @attrs;
    for my $cd ( @{ Netdot::Mojo::Registry::display_columns('Interface') } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive( $col );
        my $v = eval { $o->$col };
        $v = undef if $@;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        $text = '' unless defined $text;
        push @attrs, [ $tag, $text, $href ];
    }

    # VLANs (InterfaceVlan -> Vlan).
    my @ivlans;
    eval { @ivlans = $o->vlans };
    my @vlans;
    for my $iv (@ivlans) { my $v = eval { $iv->vlan }; push @vlans, $v if $v; }

    # IP addresses assigned to the interface (Ipblock objects).
    my @ips;    eval { @ips = $o->ips };

    # Neighboring interfaces.
    my @neighbors;    eval { @neighbors = $o->neighbors };

    # Forwarding-table timestamps (GROUP BY tstamp, newest first; limited to
    # SHOW_LAST_N_FTE). Each links to the FDB sub-view with the tstamp encoded.
    my $fwt_limit = Netdot->config->get('SHOW_LAST_N_FTE') || 10;
    my @fwt;
    my $sth1 = $dbh->prepare(
        'SELECT ft.tstamp FROM interface i, fwtable ft, fwtableentry fte
          WHERE fte.interface=i.id AND fte.fwtable=ft.id AND i.id=?
          GROUP BY ft.tstamp ORDER BY ft.tstamp DESC LIMIT ?' );
    $sth1->execute($id, $fwt_limit);
    @fwt = map { $_->[0] } @{ $sth1->fetchall_arrayref // [] };
    my @fwt_links =
        map { my $t = $_; [ $t, "/management/interface/$id/fdb?tstamp=" . url_escape($t) ] } @fwt;

    # ARP timestamps (GROUP BY tstamp, newest first; limited to SHOW_LAST_N_ARP).
    my $arp_limit = Netdot->config->get('SHOW_LAST_N_ARP') || 10;
    my @arp;
    my $sth2 = $dbh->prepare(
        'SELECT arp.tstamp FROM interface i, arpcache arp, arpcacheentry arpe
          WHERE arpe.interface=i.id AND arpe.arpcache=arp.id AND i.id=?
          GROUP BY arp.tstamp ORDER BY arp.tstamp DESC LIMIT ?' );
    $sth2->execute($id, $arp_limit);
    @arp = map { $_->[0] } @{ $sth2->fetchall_arrayref // [] };
    my @arp_links =
        map { my $t = $_; [ $t, "/management/interface/$id/arp?tstamp=" . url_escape($t) ] } @arp;

    # Audit records.
    my @audit;    eval { @audit = $o->get_audit_records( table => 'Interface', id => $id ) };

    my $label = eval { $o->get_label } // '';
    $label = "Interface #$id" unless defined $label && length $label;

    $c->render(
        template    => 'management/interface',
        layout      => 'default',
        title       => $label,
        id          => $id,
        attrs       => \@attrs,
        vlans       => \@vlans,
        ips         => \@ips,
        neighbors   => \@neighbors,
        fwt_links   => \@fwt_links,
        arp_links   => \@arp_links,
        audit       => \@audit,
    );
}

# FDB (forwarding table) entries seen on this interface at a given timestamp —
# port of i_fdb.html.
sub fdb {
    my $c      = shift;
    my $id     = $c->param('id');
    my $tstamp = $c->param('tstamp');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Interface->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;

    my @macs;    eval { @macs = PhysAddr->search_interface_macs( $id, $tstamp ) };

    my $label = eval { $o->get_label } // "";
    $label = "Interface #$id" unless defined $label && length $label;

    $c->render(
        template => 'management/i_fdb',
        layout   => 'default',
        title    => "FDB - $label",
        id       => $id,
        tstamp   => $tstamp // '',
        label    => $label,
        macs     => \@macs,
    );
}

# ARP entries on this interface at a given timestamp — port of i_arp.html.
sub arp {
    my $c      = shift;
    my $id     = $c->param('id');
    my $tstamp = $c->param('tstamp');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Interface->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;

    my @entries;    eval { @entries = ArpCacheEntry->search_interface( $id, $tstamp ) };

    # Each entry: IP + MAC (both linkable).
    my $esc = sub { my ($s) = @_; $s = '' unless defined $s; $s =~ s/([&<>"])/\u$1/ge; $s };
    my @rows;
    for my $e (@entries) {
        my ( $ip, $iphref )    = @{ Netdot::Mojo::Registry::link_for( eval { $e->ipaddr } ) };
        my ( $mac, $machref )  = @{ Netdot::Mojo::Registry::link_for( eval { $e->physaddr } ) };
        $ip  = '' unless defined $ip;
        $mac = '' unless defined $mac;
        push @rows, {
            ip   => $ip,      iphref  => $iphref,
            mac  => $mac,     machref => $machref,
        };
    }

    my $label = eval { $o->get_label } // "";
    $label = "Interface #$id" unless defined $label && length $label;

    $c->render(
        template => 'management/i_arp',
        layout   => 'default',
        title    => "ARP - $label",
        id       => $id,
        tstamp   => $tstamp // '',
        label    => $label,
        rows     => \@rows,
    );
}

1;
