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

1;
