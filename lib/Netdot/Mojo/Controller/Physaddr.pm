package Netdot::Mojo::Controller::Physaddr;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;

# Detail page for a MAC / PhysAddr — read-only port of mac.html: the MAC
# attributes (address, vendor/OUI, static, first/last seen), the devices and
# interfaces using the address, the edge port, the last N forwarding-table and
# ARP entries, and the DHCP scopes.

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Physaddr - MAC / PhysAddr detail page (port of mac.html) + search

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/management/physaddr/:id')->to('physaddr#show', type => 'physaddr')
    #   ->get('/management/physaddr/search')->to('physaddr#search', type => 'physaddr')

=head1 INSTANCE METHODS

=cut

=head2 show - MAC / PhysAddr detail page

Arguments:  Controller (param: id)
Returns:    Renders the management/mac template
Description: Read-only port of mac.html: the MAC attributes (address,
            vendor/OUI, static, first/last seen), the devices and interfaces
            using the address, the edge port, the last N forwarding-table
            and ARP entries (grouped by timestamp) and the DHCP scopes.

=cut

sub show {
    my $c  = shift;
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    my $o = eval { PhysAddr->retrieve($id) };
    return $c->reply->not_found unless $o && !$@;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $app   = $c->app;
    my $esc   = sub { my ($s) = @_; $s = '' unless defined $s; $s =~ s/([&<>"])/\u$1/ge; $s };
    my $limit = 10;    # SHOW_LAST_N_* default

    # MAC attributes: address, vendor (with OUI link), static, first/last seen.
    my $vendor = $o->vendor;
    my $oui    = $o->oui;
    my @addr_rows = (
        ['Address',    $esc->( $o->format_address // $o->address )],
        ['Vendor',     ( defined $oui && length $oui
                          ? '<a href="' . Netdot::Mojo::Registry::set_uri( "/management/physaddr/search?search=" . $esc->($oui) )
                            . '">' . $esc->($vendor // '-') . ' (' . $esc->($oui) . ')</a>'
                          : $esc->($vendor // '-') )],
        ['Static',     $o->static ? 'Yes' : 'No'],
        ['First Seen', $esc->( $o->first_seen // '' )],
        ['Last Seen',  $esc->( $o->last_seen  // '' )],
    );

    # List-context calls: NEVER wrap in eval{ } // () (it degrades wantarray and
    # yields a single iterator/count instead of the object list). Assign into an
    # array inside the eval so list context is preserved and errors are swallowed.
    my @devices;    eval { @devices = $o->devices };
    my @interfaces; eval { @interfaces = $o->interfaces };
    my @scopes;     eval { @scopes = $o->dhcp_hosts };

    # Edge port (find_edge_port may die when there is none; guard it).
    my $edge_html;
    my $ep = eval { $o->find_edge_port };
    $ep = undef if $@;
    if ( $ep ) {
        my $iface = eval { Interface->retrieve($ep) };
        if ( $iface ) {
            my ( $jack, $room );
            my $j = eval { $iface->jack };
            if ( $j ) {
                $jack = $j->jackid;
                $room = eval { $j->room->name };
            }
            else { $jack = $iface->jack_char; $room = $iface->room_char; }
            $jack ||= 'n/a';
            $room ||= 'n/a';
            my $lbl = $esc->( $iface->get_label // "interface #$ep" );
            $edge_html = '<tr><td><a href="' . Netdot::Mojo::Registry::set_uri( "/management/interface/" . $ep ) . '">' . $lbl . '</a></td>'
                        . '<td>' . $esc->($room) . '</td><td>' . $esc->($jack) . '</td>'
                        . '<td>' . $esc->( $iface->description // '' ) . '</td></tr>';
        }
    }

    # Last N forwarding-table entries (rows: [tstamp, interface_id]).
    my $fwt_html;
    my $fwt = eval { $o->get_last_n_fte($limit) };
    $fwt = [] unless ref $fwt eq 'ARRAY';
    if ( @$fwt ) {
        my %tstamps;
        for my $row ( @$fwt ) {
            my ( $tstamp, $iid ) = @$row;
            my $iface = eval { Interface->retrieve($iid) };
            my $lbl   = $iface ? $iface->get_label : "interface #$iid";
            push @{ $tstamps{$tstamp} }, '<a href="' . Netdot::Mojo::Registry::set_uri( "/management/interface/" . $iid ) . '">' . $esc->($lbl) . '</a>';
        }
        my $rows = join '', map {
            my $t     = $_;
            my $links = join ', ', sort @{ $tstamps{$t} };
            '<tr><td>' . $esc->($t) . '</td><td>' . $links . '</td></tr>';
        } reverse sort keys %tstamps;
        $fwt_html = '<thead><tr><th>Time Seen</th><th>Interfaces</th></tr></thead><tbody>' . $rows . '</tbody>';
    }

    # Last N ARP entries (rows: [interface_id, ipblock_id, tstamp]).
    my $arp_html;
    my $arp = eval { $o->get_last_n_arp($limit) };
    $arp = [] unless ref $arp eq 'ARRAY';
    if ( @$arp ) {
        my %tstamps;
        for my $row ( @$arp ) {
            my ( $iid, $ipid, $tstamp ) = @$row;
            my $iface = eval { Interface->retrieve($iid) };
            my $lbl   = $iface ? $iface->get_label : "interface #$iid";
            push @{ $tstamps{$tstamp}{$ipid} },
                 '<a href="' . Netdot::Mojo::Registry::set_uri( "/management/interface/" . $iid ) . '">' . $esc->($lbl) . '</a>';
        }
        my @rows;
        for my $tstamp ( reverse sort keys %tstamps ) {
            for my $ipid ( sort keys %{ $tstamps{$tstamp} } ) {
                my $ip     = eval { Ipblock->retrieve($ipid) };
                my $iplbl  = $ip ? $ip->get_label : "ip #$ipid";
                my $iplink = '<a href="' . Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $ipid ) . '">' . $esc->($iplbl) . '</a>';
                my $links  = join ', ', sort @{ $tstamps{$tstamp}{$ipid} };
                push @rows, '<tr><td>' . $esc->($tstamp) . '</td><td>' . $iplink . '</td><td>' . $links . '</td></tr>';
            }
        }
        $arp_html = '<thead><tr><th>Time Seen</th><th>IP</th><th>Interfaces</th></tr></thead><tbody>' . join('', @rows) . '</tbody>';
    }

    $c->render( template => 'management/mac', status => 200,
        layout     => 'default',
        title      => $o->format_address // "PhysAddr #$id",
        o          => $o,
        limit      => $limit,
        addr_rows  => \@addr_rows,
        devices    => \@devices,
        interfaces => \@interfaces,
        scopes     => \@scopes,
        edge_html  => $edge_html,
        fwt_html   => $fwt_html,
        arp_html   => $arp_html,
    );
}

# MAC search (port of mac.html "search"): a LIKE on the address (full MAC or
# OUI prefix). One match -> straight to the detail page; several -> a results
# table; none -> not found.
=head2 search - MAC address search

Arguments:  Controller (param: search = full MAC or OUI prefix)
Returns:    A single match redirects to the detail page; several matches
            render the management/search_results template (max 200 rows,
            with a batch-delete option when the user may delete PhysAddr);
            no match -> not found
Description: Port of mac.html "search": a LIKE on the address
            (PhysAddr->search_like).

=cut

sub search {
    my $c    = shift;
    my $term = $c->param('search');
    $term =~ s/^\s+|\s+$//g if defined $term;
    my $search_url = $c->url_for('physaddr_search');
    unless ( $term ) { $c->redirect_to( $search_url ); return; }

    # search_like returns a CDBI iterator; iterate it explicitly (never wrap the
    # call in eval{} // (), that degrades wantarray -> a single iterator object).
    my @results;
    eval {
        my $it = PhysAddr->search_like( address => $term );
        while ( my $o = $it->next ) { push @results, $o; }
    };

    if ( @results == 1 ) {
        $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/physaddr/' . $results[0]->id ) );
        return;
    }

    my $limit = 200;
    my @rows;
    for my $o ( @results[ 0 .. ( @results > $limit ? $limit - 1 : $#results ) ] ) {
        push @rows, { id    => $o->id,
                      label => $o->format_address // $o->address,
                      href  => Netdot::Mojo::Registry::set_uri( '/management/physaddr/' . $o->id ),
                      cells => [ $o->first_seen // '', $o->last_seen // '' ] };
    }
    # Batch delete on the results (PhysAddr type) when the user may delete.
    my $del;
    if ( @rows && Netdot::Mojo::Permissions->has_action( 'PhysAddr', $c->current_person, 'delete' ) ) {
        $del = { type => 'physaddr', api => $c->web_prefix . '/api/physaddr' };
    }
    $c->render(
        template   => 'management/search_results',
        layout     => 'default',
        title      => 'MAC Address Search',
        search     => $term,
        headers    => [ 'MAC Address', 'First Seen', 'Last Seen' ],
        rows       => \@rows,
        search_url => $search_url,
        del        => $del,
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