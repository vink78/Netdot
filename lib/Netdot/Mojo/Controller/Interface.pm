package Netdot::Mojo::Controller::Interface;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util  qw(url_escape);
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Detail page for a single interface — port of interface.html: the interface
# attributes (netdot.meta "all" view, with the in-place edit form + page-level
# delete), the VLANs, the forwarding-table and ARP entry timestamps (each
# linking to the FDB/ARP sub-view), the IP addresses, the neighbors, and the
# audit records.

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Interface - Interface detail page (port of interface.html) + FDB / ARP sub-views

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/management/interface/:id')->to('interface#show', type => 'interface')
    #   ->get('/management/interface/:id/fdb')->to('interface#fdb')
    #   ->get('/management/interface/:id/arp')->to('interface#arp')

=head1 INSTANCE METHODS

=cut

=head2 show - Interface detail page

Arguments:  Controller (param: id)
Returns:    Renders the management/interface template
Description: Port of interface.html: the interface attributes
            (netdot.meta "all" view), the VLANs, the IP addresses, the
            neighbors, the FDB / ARP entry timestamps (each linking to the
            fdb/arp sub-view) and the audit records. The attributes are
            editable in place (Edit toggle -> the shared _edit_form partial,
            PATCH /api/interface/<id>) and the page offers a Delete button
            (DELETE /api/interface/<id>), both gated on the per-object right
            (same mechanism as the generic detail page).

=cut

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

    # In-place edit form + page-level delete (the same generic mechanism as
    # Show#show / detail.html.ep): editable fields via
    # Detail::build_edit_fields, written through PATCH /api/interface/<id>;
    # delete through DELETE /api/interface/<id>, back to the interface list.
    my $can_edit   = $c->perm( 'edit', $o );
    my $fields     = $can_edit ? Netdot::Mojo::Detail::build_edit_fields( $o, 'Interface' ) : [];
    my $api_path   = $can_edit ? $c->web_prefix . '/api/interface/' . $id : '';
    my $can_delete = $c->perm( 'delete', $o );
    my $del_path   = $can_delete ? $c->web_prefix . '/api/interface/' . $id : '';
    my $del_goto   = $can_delete ? Netdot::Mojo::Registry::set_uri( '/management/interface' ) : '';

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
        can_edit    => $can_edit,
        fields      => $fields,
        api_path    => $api_path,
        can_delete  => $can_delete,
        del_path    => $del_path,
        del_goto    => $del_goto,
    );
}

# FDB (forwarding table) entries seen on this interface at a given timestamp —
# port of i_fdb.html.
=head2 fdb - FDB (forwarding table) entries seen on an interface

Arguments:  Controller (params: id, tstamp)
Returns:    Renders the management/i_fdb template (MACs from
            PhysAddr->search_interface_macs at the given timestamp)
Description: Port of i_fdb.html.

=cut

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
=head2 arp - ARP entries on an interface at a timestamp

Arguments:  Controller (params: id, tstamp)
Returns:    Renders the management/i_arp template (rows of IP + MAC, both
            linkable, from ArpCacheEntry->search_interface)
Description: Port of i_arp.html.

=cut

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