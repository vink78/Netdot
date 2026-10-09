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
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    # Main attributes (all view) — same logic as the generic detail.
    my @attrs;
    for my $cd ( @{ Netdot::Mojo::Registry::display_columns('Interface') } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive( $col );
        my $v = eval { $o->$col };
        $v = undef if $@;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::attr_display( 'Interface', $col, $v ) };
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

    # Forwarding-table (FDB) timestamps — last SHOW_LAST_N_FTE (model method).
    my @fwt;    eval { @fwt = $o->fdb_tstamps() };
    my @fwt_links =
        map { my $t = $_; [ $t, Netdot::Mojo::Registry::set_uri( "/management/interface/$id/fdb?tstamp=" . url_escape($t) ) ] } @fwt;

    # ARP timestamps — last SHOW_LAST_N_ARP (model method).
    my @arp;    eval { @arp = $o->arp_tstamps() };
    my @arp_links =
        map { my $t = $_; [ $t, Netdot::Mojo::Registry::set_uri( "/management/interface/$id/arp?tstamp=" . url_escape($t) ) ] } @arp;

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
    return if $c->deny_unless( 'view', $o );

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
    return if $c->deny_unless( 'view', $o );

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