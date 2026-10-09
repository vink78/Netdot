package Netdot::Mojo::Controller::Search;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;

# Global search: detect IP / MAC / text and route accordingly.
sub index {
    my $c    = shift;
    my $q    = $c->param('q') // '';
    $q =~ s/^\s+|\s+$//g;
    return $c->redirect_to('/') unless $q;

    # MAC address (with or without delimiters) — checked BEFORE IPv6 because
    # a colon-delimited MAC (00:50:56:b0:d5:91) also matches the IPv6 pattern.
    if ( $q =~ /^[0-9A-Fa-f]{2}([:.-][0-9A-Fa-f]{2}){5}$/
       || $q =~ /^[0-9A-Fa-f]{12}$/ ) {
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/physaddr/search?search=' . $q ) );
    }

    # IPv4 (with optional /prefix)
    if ( $q =~ /^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/ ) {
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/ipblock/search?search_address=' . $q ) );
    }

    # IPv6 (contains colons, hex chars — but NOT a MAC: already excluded above)
    if ( $q =~ /^[0-9a-fA-F:]+$/ && $q =~ /:/ ) {
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/ipblock/search?search_address=' . $q ) );
    }

    # Text: search RR (hostname)
    my @results;
    eval {
        my $it = RR->search_like( name => $q );
        while ( my $o = $it->next ) { push @results, $o; }
    };

    # Single match -> redirect to detail
    if ( @results == 1 ) {
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/rr/' . $results[0]->id ) );
    }

    # Multiple or zero -> results page
    my $limit = 200;
    my @rows;
    my $max   = @results > $limit ? $limit : scalar @results;
    for my $i ( 0 .. $max - 1 ) {
        my $o = $results[$i];
        my $zone = eval { $o->zone->name } // '';
        push @rows, {
            label => $o->name // '',
            href  => Netdot::Mojo::Registry::set_uri( '/management/rr/' . $o->id ),
            cells => [ $zone ],
        };
    }

    $c->render(
        template   => 'search/results',
        layout     => 'default',
        title      => 'Search',
        search     => $q,
        # The template renders a leading "Name" header for the label column, so
        # $headers holds only the ADDITIONAL (non-label) columns.
        headers    => [ 'Zone' ],
        rows       => \@rows,
        search_url => Netdot::Mojo::Registry::set_uri( '/search' ),
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