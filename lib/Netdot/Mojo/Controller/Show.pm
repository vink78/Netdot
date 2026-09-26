package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::UI;
use Netdot::Mojo::Registry;
use NetAddr::IP;

# Read-only detail page for one object: every non-empty, non-sensitive attribute.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    # ipblock: hierarchical detail with a view-format flag (list | block | tree).
    if ( $type eq 'ipblock' ) {
        my $o = eval { $class->retrieve( $id ) };
        return $c->reply->not_found unless $o;

        my $cfg    = Netdot->config;
        my $status = eval { $o->status->name } // '';
        my $prefix = $o->prefix;
        my $v4     = ( $o->version == 4 );

        # View modes available for this block (rules from ip.html):
        #   list always; block and tree for v4 when prefix >= MAX.
        my $max = $status eq 'Subnet' ? $cfg->get('SUBNET_BLOCK_VIEW_MAX_PREFIX')
                 : ( $status eq 'Container' ? $cfg->get('CONTAINER_BLOCK_VIEW_MAX_PREFIX') : undef );
        my @modes = ( 'list' );
        if ( $v4 && $max && $prefix >= $max ) {
            push @modes, 'block';
            push @modes, 'tree';
        }

        # Effective view: requested (sanitized), defaulting to the config value,
        # forced to an available mode (so v6 / too-large blocks fall back to list).
        my $vfmt = $c->param('view_format');
        $vfmt = $cfg->get('DEFAULT_IPBLOCK_VIEW') || 'block' unless $vfmt;
        $vfmt = 'list' unless $vfmt =~ /^(list|block|tree)$/;
        $vfmt = 'list' unless grep { $_ eq $vfmt } @modes;

        # Objects to display, depending on the effective view.
        my ( @blocks, $viewtype, $tree_html, $grid, $container_grid );
        if ( $vfmt eq 'list' ) {
            if ( $status eq 'Subnet' ) {
                @blocks   = $o->get_addresses_by('Address');   # individual addresses
                $viewtype = @blocks ? 'address' : 'block';
            } else {
                @blocks   = _ipblock_children( $o );            # contained IP blocks
                $viewtype = @blocks && eval { $blocks[0]->is_address } ? 'address' : 'block';
            }
        } elsif ( $vfmt eq 'tree' ) {
            $viewtype  = 'block';
            my $ref    = eval { $o->get_descendants( no_addresses => 1 ) };
            my $ui     = eval { Netdot::UI->new() };
            $tree_html = ( $ui && $ref ) ? eval { $ui->build_ip_tree_graph_html( id => $o->id, list => $ref ) } : undef;
        } else {  # block view
            $viewtype = 'block';
            if ( $status eq 'Subnet' ) {
                $grid = _build_subnet_grid( $o );               # the address grid
            } else {
                # Container: the proportional usage visualization (port of container.mhtml).
                $container_grid = _build_container_grid_html(
                    $o,
                    rowsize => $c->param('rowsize'),
                    divide  => $c->param('dividefreespace'),
                );
            }
        }

        my @ancs   = $o->get_ancestors;
        my @crumbs = ( { label => 'Roots', id => 0 } );
        push @crumbs, map { { label => $_->get_label, id => $_->id } } ( reverse @ancs );
        my $devs   = $viewtype eq 'address' ? ( eval { Device->get_ips_from_all() } || {} ) : undef;

        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => "Ipblock " . $o->get_label,
            viewtype   => $viewtype,
            viewformat => $vfmt,
            modes      => \@modes,
            tree_html  => $tree_html,
            grid       => $grid,
            container_grid => $container_grid,
            blocks     => \@blocks,
            current    => $o,
            breadcrumb => \@crumbs,
            devs       => $devs,
        );
        return;
    }

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;

    my @attrs;
    for my $col ( $class->columns ) {
        next if $col eq 'id';
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        next if $@;
        next unless defined $v;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        next if !defined $text || $text eq '';
        push @attrs, [ $col, $text, $href ];
    }

    $c->render(
        template => 'management/detail',
        layout   => 'default',
        title    => ucfirst($type) . " #$id",
        type     => $type,
        id       => $id,
        attrs    => \@attrs,
    );
}

# Direct children of an ipblock. ->children returns a Class::DBI::Iterator, so it
# must be iterated (a plain list assignment via eval() degrades to the iterator).
sub _ipblock_children {
    my ($o) = @_;
    my @kids;
    my $it = eval { $o->children };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $k = $it->next ) {
            push @kids, $k;
        }
    }
    return @kids;
}

# Block view for a Container: a proportional usage visualization (port of
# container.mhtml). Rendered as a CSS grid: one row = a /rowsize (config
# DEFAULT_IPBLOCK_ROWSIZE), divided into $COLS base columns; each contained block /
# free partition spans 2^(base_prefix-prefix) columns, so a /23 is exactly 2x a /24.
# A leading column holds the row's starting address. CIDR blocks are aligned to their
# prefix, so no cell crosses a row boundary at a mid-cell offset. Returns HTML.
sub _build_container_grid_html {
    my ( $o, %opt ) = @_;
    my $rowsize = $opt{rowsize} || ( Netdot->config->get('DEFAULT_IPBLOCK_ROWSIZE') || 22 );
    my $divide  = $opt{divide}  || 'max';
    $rowsize    = int( $rowsize );
    my $v4      = ( $o->version == 4 );
    my $bits    = $v4 ? 32 : 128;
    $rowsize    = 32  if ( $v4 && $rowsize > 32 );
    $rowsize    = 128 if ( ! $v4 && $rowsize > 128 );
    my $COLS        = 16;                  # base columns per row
    my $base_prefix = $rowsize + 4;        # one row = a /rowsize, split into 16=2^4 columns
    my $base_size   = 2 ** ( $bits - $base_prefix );   # addresses per base column

    # Contained blocks (sorted) and free space (sorted), merged by address.
    my @ch;
    my $it = eval { $o->children };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $k = $it->next ) { push @ch, $k; }
    }
    @ch = sort { $a->address_numeric <=> $b->address_numeric } @ch;
    my @fs = $o->free_space( $divide );
    @fs   = sort { $a->numeric <=> $b->numeric } @fs;

    my @cells;
    while ( @ch || @fs ) {
        if ( ! @ch || ( @fs && $fs[0]->numeric < $ch[0]->address_numeric ) ) {
            my $f = shift @fs;
            push @cells, {
                width => 2 ** ( $base_prefix - $f->masklen ), class => 'ipaddr_available',
                title => "$f", link => '',
            };
        } elsif ( ! @fs || $fs[0]->numeric > $ch[0]->address_numeric ) {
            my $c     = shift @ch;
            my $st    = $c->status->name;
            my $title = $c->cidr;
            $title   .= ' (' . $c->description . ')' if $c->description;
            push @cells, {
                width => 2 ** ( $base_prefix - $c->prefix ), class => 'ipaddr_' . lc($st),
                title => $title, link => '/management/ipblock/' . $c->id,
            };
        } else {
            last;   # inconsistent state; stop rather than loop forever
        }
    }

    # Row headers: the starting address of each /rowsize row.
    my $total_units = 2 ** ( $base_prefix - $o->prefix );
    my $num_rows    = int( $total_units / $COLS );
    my $start_num   = $o->address_numeric;
    my $base_url    = '/management/ipblock/' . $o->id . '?view_format=block';

    my $html = '<table style="width:100%"><tr>';
    $html .= '<td style="text-align:right;vertical-align:middle">Zoom: Set one row equal to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=\'+this.value">';
    for my $i ( $o->prefix .. ( $v4 ? 32 : 128 ) ) {
        $html .= '<option value="' . $i . '"' . ( $rowsize == $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td><td style="text-align:right;vertical-align:middle">Partition: Set max free space size to '
           . '<select class="small" onchange="window.location=\'' . $base_url
           . '&rowsize=' . $rowsize . '&dividefreespace=\'+this.value">';
    $html .= '<option value="max"' . ( $divide eq 'max' ? ' selected' : '' ) . '>unlimited</option>';
    for my $i ( $o->prefix .. ( $v4 ? 32 : 128 ) ) {
        $html .= '<option value="' . $i . '"' . ( $divide eq $i ? ' selected' : '' ) . '>/'. $i . '</option>';
    }
    $html .= '</select></td></tr></table>';

    $html .= '<div class="ipcontainergrid" style="display:grid;grid-template-columns:110px repeat('
           . $COLS . ',1fr);grid-auto-rows:15px;gap:1px;width:100%">';
    for my $r ( 0 .. $num_rows - 1 ) {
        my $n    = $start_num + $r * $COLS * $base_size;
        my $addr = eval { NetAddr::IP->new( $n )->addr } // '';
        $html   .= '<div class="ipcontainergrid-rowheader" style="grid-column:1 / 2;grid-row:' . ( $r + 1 )
                 . ' / span 1">' . $addr . '</div>';
    }
    my $g = 0;
    for my $cell (@cells) {
        my $W         = $cell->{width};
        my $start_row = int( $g / $COLS );
        my $start_col = $g % $COLS;
        my ( $spanC, $spanR ) = $W <= $COLS ? ( $W, 1 ) : ( $COLS, int( $W / $COLS ) );
        $html .= '<div class="' . $cell->{class} . '" title="' . $cell->{title}
               . '" style="grid-column:' . ( $start_col + 2 ) . ' / span ' . $spanC
               . ';grid-row:' . ( $start_row + 1 ) . ' / span ' . $spanR . '">'
               . '<a href="' . ( $cell->{link} || '#' ) . '" style="display:block;height:100%"></a></div>';
        $g += $W;
    }
    $html .= '</div>';
    return $html;
}

# Block view for a Subnet: a grid of every individual address (port of subnet.mhtml).
# Returns an arrayref of rows, each row an arrayref of ready-to-print HTML cell strings.
sub _build_subnet_grid {
    my ($o) = @_;

    my %classes = (
        Static => 'ipaddr_static', Dynamic => 'ipaddr_dynamic', Reserved => 'ipaddr_reserved',
        Container => 'ipaddr_container', Discovered => 'ipaddr_discovered', Available => 'ipaddr_available',
    );

    # Used addresses in this subnet (id, numeric address, description, status, dns, device).
    my $id  = $o->id;
    my $dbh = Netdot::Model->db_Main();
    my $q   = "SELECT ipblock.id, ipblock.address, ipblock.description, ipblockstatus.name, rr.name, device.id
               FROM ipblockstatus, ipblock
               LEFT JOIN (rr CROSS JOIN rraddr) ON (ipblock.id = rraddr.ipblock AND rraddr.rr = rr.id)
               LEFT JOIN (device CROSS JOIN interface) ON (ipblock.interface = interface.id AND interface.device = device.id)
               WHERE ipblock.parent = $id AND ipblock.status = ipblockstatus.id
               ORDER BY ipblock.address";
    my $results = $dbh->selectall_arrayref($q);
    my ( %used, %names, %status, %ids );
    for my $r ( @$results ) {
        my ( $ipid, $address, $description, $st, $dnsname, $device ) = @$r;
        $used{ $address }   = 1;
        $names{ $address }  = $st;
        if ( $st eq 'Static' ) {
            $names{ $address } = $dnsname if $dnsname;
        } elsif ( $device ) {
            my $lbl = eval { Device->retrieve($device)->get_label };
            $names{ $address } = $lbl if $lbl;
        }
        $names{ $address } = $description if ( $st ne 'Static' && $description );
        $status{ $address } = $st;
        $ids{ $address }    = $ipid;
    }

    my $net   = $o->netaddr->network;
    my $mask  = $net->masklen;
    my $bits  = ( $o->version == 4 ) ? 32 : 128;
    my $total = 2 ** ( $bits - $mask );
    my $cols  = ( $total < 16 ) ? $total : 16;
    my $rows  = int( $total / $cols );

    my @out;
    for ( my $i = 0; $i < $rows; $i++ ) {
        my @row;
        for ( my $j = 0; $j < $cols; $j++ ) {
            my $disp     = $net->addr;
            my $stn      = $status{ $net->numeric } // '';
            my $divclass = $classes{ $stn } || 'ipaddr_available';
            my $divtitle = $names{ $net->numeric } || $net->addr;
            # Hide the insignificant (network) octets for v4.
            if ( $o->version == 4 ) {
                $disp =~ s/^\d+\.\d+\.\d+\.(\d+)$/$1/o if $mask >= 24;
                $disp =~ s/^\d+\.\d+\.(\d+\.\d+)$/$1/o    if $mask >= 16 && $mask < 24;
                $disp =~ s/^\d+\.(\d+\.\d+\.\d+)$/$1/o    if $mask >= 8  && $mask < 16;
            }
            my $cell;
            if ( $mask != 31 && $net->numeric == $net->network->numeric && !$o->use_network_broadcast ) {
                $cell = qq{<div class="ipaddr_disabled" title="Network">$disp</div>};
            } elsif ( $mask != 31 && $net->numeric == $net->broadcast->numeric && !$o->use_network_broadcast ) {
                $cell = qq{<div class="ipaddr_disabled" title="Broadcast">$disp</div>};
            } else {
                my $inner = qq{<div class="$divclass" title="$divtitle" width="100%">$disp</div>};
                my $aid   = $ids{ $net->numeric };
                $cell = ( exists $used{ $net->numeric } && $aid )
                    ? qq{<a href="/management/ipblock/$aid" class="ipaddr">$inner</a>}
                    : $inner;
            }
            push @row, $cell;
            $net++;
        }
        push @out, \@row;
    }
    return \@out;
}

1;
