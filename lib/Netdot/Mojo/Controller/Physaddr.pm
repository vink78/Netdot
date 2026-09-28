package Netdot::Mojo::Controller::Physaddr;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Registry;

# Detail page for a MAC / PhysAddr — read-only port of mac.html: the MAC
# attributes (address, vendor/OUI, static, first/last seen), the devices and
# interfaces using the address, the edge port, the last N forwarding-table and
# ARP entries, and the DHCP scopes.
sub show {
    my $c  = shift;
    my $id = $c->param('id');

    my $o = eval { PhysAddr->retrieve($id) };
    unless ( $o && !$@ ) {
        $c->render(template => 'error', status => 404,
                   title => 'MAC', message => "PhysAddr #${id} not found.");
        return;
    }

    my $app   = $c->app;
    my $esc   = sub { my ($s) = @_; $s = '' unless defined $s; $s =~ s/([&<>"])/\u$1/ge; $s };
    my $limit = 10;    # SHOW_LAST_N_* default

    # MAC attributes: address, vendor (with OUI link), static, first/last seen.
    my $vendor = $o->vendor;
    my $oui    = $o->oui;
    my @addr_rows = (
        ['Address',    $esc->( $o->format_address // $o->address )],
        ['Vendor',     ( defined $oui && length $oui
                          ? '<a href="/management/physaddr/search?search=' . $esc->($oui)
                            . '">' . $esc->($vendor // '-') . ' (' . $esc->($oui) . ')</a>'
                          : $esc->($vendor // '-') )],
        ['Static',     $o->static ? 'Yes' : 'No'],
        ['First Seen', $esc->( $o->first_seen // '' )],
        ['Last Seen',  $esc->( $o->last_seen  // '' )],
    );

    my @devices    = eval { $o->devices }    // ();
    my @interfaces = eval { $o->interfaces } // ();
    my @scopes     = eval { $o->dhcp_hosts } // ();

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
            $edge_html = '<tr><td><a href="/management/interface/' . $ep . '">' . $lbl . '</a></td>'
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
            push @{ $tstamps{$tstamp} }, '<a href="/management/interface/' . $iid . '">' . $esc->($lbl) . '</a>';
        }
        my $rows = join '', map {
            my $t     = $_;
            my $links = join ', ', sort @{ $tstamps{$t} };
            '<tr><td>' . $esc->($t) . '</td><td>' . $links . '</td></tr>';
        } reverse sort keys %tstamps;
        $fwt_html = '<tr><th>Time Seen</th><th>Interfaces</th></tr>' . $rows;
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
                 '<a href="/management/interface/' . $iid . '">' . $esc->($lbl) . '</a>';
        }
        my @rows;
        for my $tstamp ( reverse sort keys %tstamps ) {
            for my $ipid ( sort keys %{ $tstamps{$tstamp} } ) {
                my $ip     = eval { Ipblock->retrieve($ipid) };
                my $iplbl  = $ip ? $ip->get_label : "ip #$ipid";
                my $iplink = '<a href="/management/ipblock/' . $ipid . '">' . $esc->($iplbl) . '</a>';
                my $links  = join ', ', sort @{ $tstamps{$tstamp}{$ipid} };
                push @rows, '<tr><td>' . $esc->($tstamp) . '</td><td>' . $iplink . '</td><td>' . $links . '</td></tr>';
            }
        }
        $arp_html = '<tr><th>Time Seen</th><th>IP</th><th>Interfaces</th></tr>' . join('', @rows);
    }

    $c->render( template => 'management/mac', status => 200,
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
sub search {
    my $c    = shift;
    my $term = $c->param('search');
    $term =~ s/^\s+|\s+$//g if defined $term;
    unless ( $term ) { $c->redirect_to('/management/physaddr_list'); return; }

    my @results = eval { PhysAddr->search_like(address => $term) } // ();

    if ( !@results ) {
        $c->render(template => 'management/search_results', status => 200,
                   title => 'MAC search', query => $term, type_label => 'MAC addresses', results => []);
        return;
    }
    if ( @results == 1 ) {
        $c->redirect_to('/management/physaddr/' . $results[0]->id);
        return;
    }
    my $shown  = scalar(@results) > 200 ? 200 : scalar(@results);
    my @items  = map {
        my $o = $_;
        { label => $o->format_address // $o->address,
          href  => '/management/physaddr/' . $o->id };
    } @results[ 0 .. $shown - 1 ];
    $c->render(template => 'management/search_results', status => 200,
               title => 'MAC search', query => $term,
               type_label => 'MAC addresses', results => \@items,
               total => scalar(@results), shown => $shown);
}

1;
