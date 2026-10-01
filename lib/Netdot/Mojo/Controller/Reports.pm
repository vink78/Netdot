package Netdot::Mojo::Controller::Reports;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;
use NetAddr::IP;
use File::stat;
use Scalar::Util qw(blessed);
use Mojo::Util qw(url_escape);

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# HTML-escape text (cells are rendered raw, so names must be escaped here).
sub _esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Link to a detail page, or plain (escaped) text when there is no valid id.
sub _link {
    my ($type, $id, $text) = @_;
    $text = '' unless defined $text;
    return _esc($text) unless defined $id && $id ne '' && $id =~ /^\d+$/;
    return sprintf('<a href="/management/%s/%s">%s</a>', $type, $id, _esc($text));
}

# Generic: render ANY Netdot object as a detail link (type resolved via link_for),
# or its plain label when the type is not browsable / has no numeric id.
sub _obj_html {
    my ($obj) = @_;
    return '' unless $obj;
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for( $obj ) };
    return $href ? sprintf( '<a href="%s">%s</a>', $href, _esc( $text ) ) : _esc( $text );
}

# Walk rows: any blessed (Netdot) cell becomes link HTML; every other cell passes
# through untouched. Lets a report pass relationship objects directly as cells.
sub _normalize_rows {
    my ($rows) = @_;
    return [ map { [ map { blessed( $_ ) ? _obj_html( $_ ) : $_ } @$_ ] } @$rows ];
}

# Display string for a cell (object -> its label) used as a sort key.
sub _skey {
    my ($x) = @_;
    return '' unless defined $x;
    return blessed( $x ) ? ( eval { $x->get_label } // '' ) : $x;
}

# Link to the (filtered) Device list - equivalent of Mason's
# search_obj.html?table=Device&<col>=<value>&res=1. %f holds filters (site/id,
# product/id, os/string); values are URL-escaped so strings (os) are safe.
sub _devlink {
    my (%f) = @_;
    my @kv = grep { defined $f{$_} && length $f{$_} } sort keys %f;
    my $q  = join '&', map { "$_=" . url_escape( $f{$_} ) } @kv;
    return $q ? "/management/device?$q" : '/management/device';
}

# Byte count -> human readable (port of Netdot::UI->format_size).
sub _fmt_size {
    my ($bytes) = @_;
    $bytes = 0 unless defined $bytes;
    my @sizes = ('B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB');
    my $i = 0;
    while ( $bytes >= 1024 && $i < 2 ) { $bytes /= 1024; $i++; }
    return sprintf('%.0f', $bytes) . ' ' . $sizes[$i];
}

# <select> builder: _sel(name, selected, [v,l], ...).
sub _sel {
    my ($name, $selected, @opts) = @_;
    my $h = qq{<select name="$name">\n};
    for my $o (@opts) {
        my ( $v, $l ) = @$o;
        my $s = ( defined $v && $v ne '' && $v eq $selected ) ? ' selected' : '';
        $h .= qq{<option value="} . _esc($v // '') . qq{"$s>} . _esc($l) . "</option>\n";
    }
    return $h . "</select>";
}

# A NetAddr::IP (or address string) rendered as a short link, or &nbsp;.
sub _ip_cell {
    my ($address, $id) = @_;
    my $nip = eval { NetAddr::IP->new($address) };
    return '&nbsp;' unless defined $nip && defined $id && $id =~ /^\d+$/;
    return sprintf('<a href="/management/ipblock/%s">%s</a>', $id, _esc( $nip->short ));
}

# 403 unless the user may access the Reports section (Admin + Operator).
sub _guard {
    my ($c) = @_;
    my $ut = Netdot::Mojo::Permissions->user_type( $c->current_person );
    return 0 if $ut eq 'Admin' || $ut eq 'Operator';
    $c->render( template => 'forbidden', layout => 'default', title => 'Access denied', status => 403 );
    return 1;
}

# Strip HTML markup from a (raw) cell -> plain text for CSV export.
sub _strip_html {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/<[^>]*>//g;      # drop tags
    $s =~ s/&nbsp;/ /g;
    $s =~ s/&quot;/"/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

# Stream a report table as a CSV attachment (cells are the raw HTML cells -> stripped).
sub _csv {
    my ( $c, $headers, $rows, $name ) = @_;
    $rows = _normalize_rows( $rows );   # object cells -> link HTML (stripped to label below)
    my @hdr = map { Netdot::Mojo::Registry::csv_field( _strip_html($_) ) } @$headers;
    my $csv = join( ',', @hdr ) . "\n";
    for my $row ( @$rows ) {
        my @cells = map { Netdot::Mojo::Registry::csv_field( _strip_html($_) ) } @$row;
        $csv .= join( ',', @cells ) . "\n";
    }
    my $h = $c->res->headers;
    $h->content_type( 'text/csv' );
    $h->content_disposition( 'attachment; filename="' . $name . '"' );
    $c->render( data => $csv );
}

# Render a report: optional title/description + optional raw form + the data table.
# Also stashes a csv_url (current path + query, with format=csv) for the [csv] link.
sub _render {
    my ( $c, %a ) = @_;
    my $p = $c->req->params->clone;
    $p->param( format => 'csv' );
    $c->stash( csv_url => $c->req->url->path . '?' . $p->to_string );
    $c->render(
        template  => $a{template} // 'reports/report',
        layout    => 'default',
        title     => $a{title} // 'Reports',
        desc      => $a{desc},
        form_html => $a{form_html},
        headers   => $a{headers},
        rows      => _normalize_rows( $a{rows} // [] ),
        sortable  => $a{sortable},
    );
}

# ---------------------------------------------------------------------------
# Landing page
# ---------------------------------------------------------------------------
sub index ($c) {
    return if _guard($c);
    $c->render(
        template => 'reports/index',
        layout   => 'default',
        title    => 'Reports',
        reports  => [ Netdot::Mojo::Registry::reports_menu() ],
    );
}

# ---------------------------------------------------------------------------
# Device inventory (product / site / os / mismatches + sub-reports)
# ---------------------------------------------------------------------------
my @DEVICE_OPTS = (
    [ 'product',           'Type/Model' ],
    [ 'product_monitored', 'Type/Model (monitored)' ],
    [ 'site',              'Site/Type/Model' ],
    [ 'siteos',            'Site/Type/Model/OS' ],
    [ 'os',                'Model/OS' ],
    [ 'downtime',          'In Scheduled Downtime' ],
    [ 'snmp_down',         'SNMP Down' ],
    [ 'duplex',            'Duplex Mismatches' ],
    [ 'vlan_mismatches',   'VLAN Mismatches' ],
    [ 'os_mismatches',     'OS Mismatches' ],
);

sub device ($c) {
    return if _guard($c);
    my $rt = $c->param('report_type') // 'product';
    $rt = 'product' unless grep { $_->[0] eq $rt } @DEVICE_OPTS;

    my ( $headers, $rows, $desc ) = _device_report( $rt );

    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $headers, $rows, "device_inventory_$rt.csv" );
    }

    my $form = qq{<form method="get" action="/reports/device"> By }
             . _sel( 'report_type', $rt, @DEVICE_OPTS )
             . qq{ <input type="submit" class="btn" value="Go"></form>};

    _render( $c, title => 'Device Inventory', desc => $desc, form_html => $form,
             headers => $headers, rows => $rows );
}

sub _device_report {
    my ($rt) = @_;
    my ( @headers, @rows );

    if ( $rt eq 'product' || $rt eq 'product_monitored' ) {
        my %t;
        my $grandtotal = 0;
        for my $pt ( sort { $a->name cmp $b->name } ProductType->retrieve_all ) {
            my $name = $pt->name;
            $t{$name}{total} = 0;
            $t{$name}{id}    = $pt->id;
            my @prods = ( $rt eq 'product' )
                       ? Product->search_by_type( $pt->id )
                       : Product->search_monitored_by_type( $pt->id );
            for my $o (@prods) {
                my $oname = $o->name;
                $t{$name}{prod}{$oname}{id}  = $o->id;
                $t{$name}{prod}{$oname}{num} = $o->{numdevs};
                $t{$name}{total} += $o->{numdevs};
            }
            $grandtotal += $t{$name}{total};
        }
        # Products with no type.
        for my $o ( Device->search_no_type() ) {
            my $oname = $o->name;
            $t{'Unset'}{prod}{$oname}{id}  = $o->id;
            $t{'Unset'}{prod}{$oname}{num} = $o->{numdevs};
            $t{'Unset'}{total} += $o->{numdevs};
        }
        # Devices with no asset.
        my @noprod = Device->search( asset_id => undef );
        if ( my $num = scalar @noprod ) {
            $t{'Unset'}{prod}{'Unset'}{id}  = 0;
            $t{'Unset'}{prod}{'Unset'}{num} = $num;
            $t{'Unset'}{total} = $num;
        }
        $t{'Unset'}{total} = 0 unless exists $t{'Unset'};
        $grandtotal += $t{'Unset'}{total} if exists $t{'Unset'};

        @headers = ( 'Type', 'Model', 'Count' );
        push @rows, [ 'Total Devices in Inventory:', '&nbsp;', $grandtotal ];
        for my $pt ( sort keys %t ) {
            push @rows, [ _link('producttype', $t{$pt}{id}, $pt), '&nbsp;',
                          '<strong>' . $t{$pt}{total} . '</strong>' ];
            for my $product ( sort keys %{ $t{$pt}{prod} } ) {
                my $pid = $t{$pt}{prod}{$product}{id};
                my $ml  = $product eq 'Unset' ? 'Unset' : _link('product', $pid, $product);
                push @rows, [ '&nbsp;', $ml, $t{$pt}{prod}{$product}{num} ];
            }
        }
        return ( \@headers, \@rows, 'Devices grouped by product type and model' );
    }

    if ( $rt eq 'site' || $rt eq 'siteos' ) {
        my $sel_os = $rt eq 'siteos'
                  ? ", device.os AS os, concat(asset.product_id, ':', device.os) AS product_key\n"
                  : "";
        my $sql = "
            SELECT device.site, asset.product_id,
                   site.name AS site_name, product.name AS product_name,
                   producttype.name AS product_type, entity.name AS manufacturer,
                   entity.id AS manufacturer_id
                   $sel_os
            FROM   device
            LEFT JOIN  site ON site.id=device.site
            LEFT JOIN  (asset CROSS JOIN product CROSS JOIN entity)
                       ON (asset.id=device.asset_id
                        AND asset.product_id=product.id
                        AND entity.id=product.manufacturer)
            LEFT JOIN  producttype ON product.type = producttype.id
            ORDER BY   site_name, product_type, product_name";
        my %t;
        for my $r ( @{ Netdot::Model->raw_sql($sql)->{rows} } ) {
            my $site   = $r->[0] || '_unset';
            $t{$site}{name} = $r->[2] || 'Unset';
            my $type       = $r->[4] || 'Unset';
            $t{$site}{types}{$type}{count}++;
            if ( $rt eq 'site' ) {
                my $product = $r->[1] || '_unset';
                $t{$site}{types}{$type}{prods}{$product}{id}       = $r->[1] || '_unset';
                $t{$site}{types}{$type}{prods}{$product}{name}     = $r->[3] || 'Unset';
                $t{$site}{types}{$type}{prods}{$product}{manuf}    = $r->[5] || 'Unset';
                $t{$site}{types}{$type}{prods}{$product}{manuf_id} = $r->[6] || '_unset';
                $t{$site}{types}{$type}{prods}{$product}{count}++;
            }
            else {
                my $pkey = $r->[8] || 'Unset';
                $t{$site}{types}{$type}{prods}{$pkey}{id}       = $r->[1] || '_unset';
                $t{$site}{types}{$type}{prods}{$pkey}{name}     = $r->[3] || 'Unset';
                $t{$site}{types}{$type}{prods}{$pkey}{manuf}    = $r->[5] || 'Unset';
                $t{$site}{types}{$type}{prods}{$pkey}{manuf_id} = $r->[6] || '_unset';
                $t{$site}{types}{$type}{prods}{$pkey}{os}       = $r->[7] || 'Unset';
                $t{$site}{types}{$type}{prods}{$pkey}{count}++;
            }
            $t{$site}{total}++;
        }
        @headers = ( $rt eq 'site' ? ( 'Site', 'Type', 'Model', 'Vendor', 'Count' )
                                    : ( 'Site', 'Type', 'Model', 'Vendor', 'OS', 'Count' ) );
        for my $site ( sort { $t{$a}{name} cmp $t{$b}{name} } keys %t ) {
            my $sn  = $t{$site}{name};
            my $sln = ( $site ne '_unset' )
                    ? sprintf( '<a href="%s">%s</a>', _devlink( site => $site ), _esc( $sn ) )
                    : _esc( $sn );
            my @hdr = ( $sln );
            push @hdr, ('' ) x ( $rt eq 'site' ? 3 : 4 );
            push @hdr, $t{$site}{total};
            push @rows, \@hdr;
            for my $type ( keys %{ $t{$site}{types} } ) {
                my @row = ( '' );
                push @row, $type;
                push @row, ('' ) x ( $rt eq 'site' ? 2 : 3 );
                push @row, $t{$site}{types}{$type}{count};
                push @rows, \@row;
                for my $product ( keys %{ $t{$site}{types}{$type}{prods} } ) {
                    my $p   = $t{$site}{types}{$type}{prods}{$product};
                    my %mf  = ( product => $p->{id} );
                    $mf{site} = $site if $site ne '_unset';
                    my $mil = ( $p->{id} =~ /^\d+$/ )
                            ? sprintf( '<a href="%s">%s</a>', _devlink( %mf ), _esc( $p->{name} ) )
                            : _esc( $p->{name} );
                    my $vil = _link( 'entity',  $p->{manuf_id}, $p->{manuf} );
                    my @r2  = ( '', '', $mil, $vil );
                    if ( $rt eq 'siteos' ) {
                        my $osv = $p->{os} // '';
                        push @r2, ( $osv ne 'Unset' && $p->{id} =~ /^\d+$/ )
                            ? sprintf( '<a href="%s">%s</a>', _devlink( %mf, os => $osv ), _esc( $osv ) )
                            : _esc( $osv );
                    }
                    push @r2, '<strong>' . $p->{count} . '</strong>';
                    push @rows, \@r2;
                }
            }
        }
        return ( \@headers, \@rows, 'Devices grouped by site, type and model' );
    }

    if ( $rt eq 'os' ) {
        my %t;
        for my $dev ( Device->search_by_product_os() ) {
            my $manuf = $dev->{manuf} || 'Unset';
            $t{$manuf}{id} = $dev->{manuf_id} if $dev->{manuf};
            my $prod = $dev->{prod} || 'Unset';
            $t{$manuf}{product}{$prod}{id} = $dev->{prod_id} if $dev->{prod};
            my $os = $dev->os;
            $t{$manuf}{total}++;
            $t{$manuf}{product}{$prod}{latest_os} = $dev->{latest_os};
            $t{$manuf}{product}{$prod}{total}++;
            $t{$manuf}{product}{$prod}{os}{$os}{total}++ if defined $os;
        }
        @headers = ( 'Manufacturer', 'Model', 'OS', 'Count' );
        for my $manuf ( sort keys %t ) {
            push @rows, [ ( $manuf eq 'Unset' ? $manuf : _link('entity', $t{$manuf}{id}, $manuf) ),
                          ' ', ' ', '<b>' . $t{$manuf}{total} . '</b>' ];
            for my $prod ( sort keys %{ $t{$manuf}{product} } ) {
                my $latest;
                my $pcell = $prod eq 'Unset' ? $prod : _link('product', $t{$manuf}{product}{$prod}{id}, $prod);
                $latest = sprintf('(recommended: %s)', $t{$manuf}{product}{$prod}{latest_os})
                    if $t{$manuf}{product}{$prod}{latest_os};
                push @rows, [ ' ', $pcell, $latest // '', $t{$manuf}{product}{$prod}{total} ];
                for my $os ( sort keys %{ $t{$manuf}{product}{$prod}{os} } ) {
                    my $warn = ( $t{$manuf}{product}{$prod}{latest_os} && $os ne $t{$manuf}{product}{$prod}{latest_os} )
                              ? ' style="color:#c00"' : '';
                    my $pid    = $t{$manuf}{product}{$prod}{id};
                    my $oscell = ( defined $pid && $pid =~ /^\d+$/ && length $os )
                              ? sprintf( '<a href="%s"%s>%s</a>', _devlink( product => $pid, os => $os ), $warn, _esc( $os ) )
                              : _esc( $os ) . $warn;
                    push @rows, [ ' ', ' ', $oscell,
                                  $t{$manuf}{product}{$prod}{os}{$os}{total} ];
                }
            }
        }
        return ( \@headers, \@rows, 'Devices grouped by manufacturer, model and OS' );
    }

    if ( $rt eq 'os_mismatches' ) {
        my %t;
        for my $dev ( Device->search_for_os_mismatches() ) {
            my $prod     = $dev->product;
            my $prodid   = $prod ? $prod->id : 'Unset';
            my $prodname = $prod ? eval { $prod->name } // 'Unset' : 'Unset';
            my $manuf    = $prod ? $prod->manufacturer : undef;
            my $manufid   = $manuf ? $manuf->id : 'Unset';
            my $manufname = $manuf ? ( eval { $manuf->get_label } // $manuf->name ) : 'Unset';
            my $os    = $dev->os;
            $t{$manufid}{name}      = $manufname;
            $t{$manufid}{os}        = $prod ? $prod->latest_os : '';
            $t{$manufid}{total}++;
            $t{$manufid}{product}{$prodid}{name}   = $prodname;
            $t{$manufid}{product}{$prodid}{total}++;
            $t{$manufid}{product}{$prodid}{latest} = $prod ? $prod->latest_os : '';
            $t{$manufid}{product}{$prodid}{os}{$os}{dev}{ $dev->id }{total}++;
        }
        @headers = ( 'Manufacturer', 'Model', 'Device', 'OS' );
        for my $m ( keys %t ) {
            push @rows, [ ( $m ne 'Unset' ? _link( 'entity', $m, $t{$m}{name} ) : $m ),
                          ' ', ' ', $t{$m}{os} // '' ];
            for my $prod ( keys %{ $t{$m}{product} } ) {
                push @rows, [ ' ', ( $prod ne 'Unset' ? _link( 'product', $prod, $t{$m}{product}{$prod}{name} ) : $prod ),
                              ' ', $t{$m}{product}{$prod}{latest} // '' ];
                for my $os ( keys %{ $t{$m}{product}{$prod}{os} } ) {
                    for my $devid ( keys %{ $t{$m}{product}{$prod}{os}{$os}{dev} } ) {
                        my $d      = Device->retrieve( $devid );
                        my $oscell = ( $prod =~ /^\d+$/ && defined $os && length $os )
                                  ? sprintf( '<a href="%s">%s</a>', _devlink( product => $prod, os => $os ), _esc( $os ) )
                                  : _esc( $os // '' );
                        push @rows, [ ' ', ' ', _link( 'device', $devid, $d ? $d->fqdn : $devid ), $oscell ];
                    }
                }
            }
        }
        return ( \@headers, \@rows, 'Devices whose OS differs from the product recommended OS' );
    }

    if ( $rt eq 'downtime' ) {
        my @devices = Device->get_within_downtime();
        return _device_rows( \@devices, 'Devices in scheduled downtime' );
    }
    if ( $rt eq 'snmp_down' ) {
        my @devices = Device->search( snmp_down => 1 );
        return _device_rows( \@devices, "Devices in 'SNMP Down' state" );
    }
    if ( $rt eq 'duplex' ) {
        my $list = Interface->find_duplex_mismatches();
        my @rows;
        if ( !scalar @$list ) {
            return ( [ 'Interface', 'Admin Duplex', 'Oper Duplex', 'Speed' ],
                     [ ['No mismatches found.', '', '', ''] ], 'Duplex/speed mismatches on linked interfaces' );
        }
        for my $pair ( @$list ) {
            for my $id ( @$pair ) {
                my $int = Interface->retrieve($id);
                next unless $int;
                push @rows, [ _link('interface', $id, $int->get_label),
                              $int->admin_duplex // '', $int->oper_duplex // '', $int->speed_pretty // '' ];
            }
        }
        return ( [ 'Interface', 'Admin Duplex', 'Oper Duplex', 'Speed' ], \@rows, 'Duplex/speed mismatches on linked interfaces' );
    }
    if ( $rt eq 'vlan_mismatches' ) {
        my $res = Interface->find_vlan_mismatches();
        my @rows;
        if ( !defined $res || ref($res) ne 'HASH' || !keys %$res ) {
            return ( [ 'Interface', 'VLANs', 'Interface', 'VLANs' ],
                     [ ['No mismatches found.', '', '', ''] ], 'VLAN mismatches on linked interfaces' );
        }
        for my $iid ( sort { $res->{$a}{name} cmp $res->{$b}{name} } keys %$res ) {
            push @rows, [ _link('interface', $iid, $res->{$iid}{name}), $res->{$iid}{vlans} // '',
                          _link('interface', $res->{$iid}{n_id}, $res->{$iid}{n_name}), $res->{$iid}{n_vlans} // '' ];
        }
        return ( [ 'Interface', 'VLANs', 'Interface', 'VLANs' ], \@rows, 'VLAN mismatches on linked interfaces' );
    }

    return ( [ 'Report' ], [ ['Unknown report type'] ], '' );
}

# Render a list of Device objects using the brief-view columns (Name, Asset, Site,
# SNMP Target Address) - matches the Mason snmp_down / downtime "row" view. FK
# cells link to the related object's detail page (same as the device list).
sub _device_rows {
    my ( $devices, $desc ) = @_;
    my @cols    = ( 'name', 'asset_id', 'site', 'snmp_target' );
    my @headers = map { Netdot::Mojo::Registry::column_tag( 'Device', $_ ) } @cols;
    my %linkkey = map { $_ => Netdot::Mojo::Registry::column_link_key( 'Device', $_ ) } @cols;
    my @rows;
    for my $d ( @$devices ) {
        my @cells;
        for my $col (@cols) {
            my $v = eval { $d->$col };
            $v = undef if $@;
            my $label = Netdot::Mojo::Registry::format_value( $v );
            my $id    = ref( $v ) ? eval { $v->id } : $v;
            if ( $col eq 'name' ) {
                push @cells, sprintf( '<a href="/management/device/%s">%s</a>',
                                      $d->id, Netdot::Mojo::Registry::esc( $label ) );
                next;
            }
            push @cells, ( $linkkey{$col} && defined $id && $id =~ /^\d+$/ )
                ? sprintf( '<a href="/management/%s/%s">%s</a>',
                            $linkkey{$col}, $id, Netdot::Mojo::Registry::esc( $label ) )
                : Netdot::Mojo::Registry::esc( $label );
        }
        push @rows, \@cells;
    }
    return ( \@headers, \@rows, $desc );
}

# ---------------------------------------------------------------------------
# Asset inventory
# ---------------------------------------------------------------------------
my @ASSET_OPTS = (
    [ 'type_product', 'Type/Model Summary' ],
    [ 'detailed',     'Detailed' ],
);

sub asset ($c) {
    return if _guard($c);
    my $rt   = $c->param('report_type') // 'type_product';
    $rt = 'type_product' unless grep { $_->[0] eq $rt } @ASSET_OPTS;
    my $sort = $c->param('sort') // 'type';

    my ( $headers, $rows ) = _asset_report( $rt, $sort );

    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $headers, $rows, "asset_inventory_$rt.csv" );
    }

    my $form = qq{<form method="get" action="/reports/asset"> By }
             . _sel( 'report_type', $rt, @ASSET_OPTS )
             . qq{ <input type="submit" class="btn" value="Go"></form>};

    _render( $c, title => 'Asset Inventory', form_html => $form, headers => $headers, rows => $rows );
}

sub _asset_report {
    my ( $rt, $sort ) = @_;
    my ( @headers, @rows, @assets );
    my %t;
    my ( %pobj, %manuf );
    my $grandtotal = 0;

    my $dbh    = Netdot::Model->db_Main;
    my $assets = $dbh->selectall_arrayref(
        "SELECT asset.id, asset.serial_number, asset.inventory_number, asset.reserved_for,
                product.id, product.name, producttype.name
         FROM   asset, product, producttype
         WHERE  asset.product_id=product.id AND product.type=producttype.id");
    my $installed = Asset->get_installed_hash();

    for my $row ( @$assets ) {
        my ( $id, $sn, $inv, $res, $pid, $pname, $ptype ) = @$row;
        $t{$ptype}{total}++;
        $t{$ptype}{prod}{$pname}{total}++;
        $t{$ptype}{prod}{$pname}{id}  = $pid;
        $t{$ptype}{prod}{$pname}{assets}{$sn}{id}        = $id;
        $t{$ptype}{prod}{$pname}{assets}{$sn}{installed} = exists $installed->{$id} ? 1 : 0;
        $t{$ptype}{prod}{$pname}{assets}{$sn}{inv}       = $inv;
        $t{$ptype}{prod}{$pname}{assets}{$sn}{res}       = $res;
        $grandtotal++;
        if ( !exists $pobj{$pid} ) {
            $pobj{$pid}  = eval { Product->retrieve( $pid ) };
            $manuf{$pid} = $pobj{$pid} ? eval { $pobj{$pid}->manufacturer } : undef;
        }
    }

    if ( $rt eq 'type_product' ) {
        @headers = ( 'Type', 'Model', 'Vendor', 'Count' );
        push @rows, [ 'Total Assets:', '&nbsp;', '&nbsp;', $grandtotal ];
        for my $ptype ( sort keys %t ) {
            push @rows, [ "<strong>$ptype</strong>", '&nbsp;', '&nbsp;', '<strong>' . $t{$ptype}{total} . '</strong>' ];
            for my $pname ( sort keys %{ $t{$ptype}{prod} } ) {
                my $pid = $t{$ptype}{prod}{$pname}{id};
                push @rows, [ '&nbsp;', _link( 'product', $pid, $pname ),
                              _obj_html( $manuf{$pid} ), $t{$ptype}{prod}{$pname}{total} ];
            }
        }
    }
    else { # detailed
        my @colhdr = ( 'Type', 'Model', 'Vendor', 'S/N', 'Inventory', 'Installed?', 'Reserved For' );
        @headers   = map { _esc($_) } @colhdr;
        for my $ptype ( sort keys %t ) {
            for my $pname ( sort keys %{ $t{$ptype}{prod} } ) {
                my $pid = $t{$ptype}{prod}{$pname}{id};
                for my $sn ( sort keys %{ $t{$ptype}{prod}{$pname}{assets} } ) {
                    my $a = $t{$ptype}{prod}{$pname}{assets}{$sn};
                    push @rows, [ $ptype, _link( 'product', $pid, $pname ), _obj_html( $manuf{$pid} ),
                                  _link( 'asset', $a->{id}, $sn ),
                                  $a->{inv} // '', ( $a->{installed} ? 'yes' : 'no' ), $a->{res} // '' ];
                }
            }
        }
        my %pos; @pos{@colhdr} = ( 0 .. $#colhdr );
        my $pos = exists $pos{$sort} ? $pos{$sort} : 0;
        @rows = sort { ( $a->[$pos] // '' ) cmp ( $b->[$pos] // '' ) } @rows;
    }
    return ( \@headers, \@rows );
}

# ---------------------------------------------------------------------------
# IP reports (unused subnets / maxed subnets / unused statics)
# ---------------------------------------------------------------------------
my @IP_OPTS = (
    [ 'unused_subnets',   'Unused Subnets' ],
    [ 'unused_v4_subnets','Unused Subnets (v4)' ],
    [ 'unused_v6_subnets','Unused Subnets (v6)' ],
    [ 'maxed_v4_subnets', 'Maxed Out Subnets (v4)' ],
    [ 'maxed_v6_subnets', 'Maxed Out Subnets (v6)' ],
    [ 'unused_v4_statics','Unused Static Addresses' ],
);

sub ip ($c) {
    return if _guard($c);
    my $rt    = $c->param('report_type') // '';
    my $ver   = $c->param('version') // 4;
    my $days  = $c->param('days')    // 90;
    $days = 90 unless $days =~ /^\d+$/;
    $ver = ( $ver eq '4' || $ver eq '6' ) ? $ver : 4;

    my ( $headers, $rows, $desc );

    if ( $rt =~ /^unused_(v(\d)_)?(subnets)$/ ) {
        my $v = ( defined $2 && length $2 ) ? $2 : ( $ver );   # default version
        my @s = Ipblock->get_unused_subnets( version => $v );
        $desc = "The following subnets appear to be unused (IPv$v)";
        ( $headers, $rows ) = _ipblock_rows( \@s, "No unused subnets found." );
    }
    elsif ( $rt =~ /^maxed_(v(\d))_subnets$/ ) {
        my $v = $2;
        my $thr = Netdot::Model->config->get('SUBNET_USAGE_MINPERCENT') // '';
        my @pairs = Ipblock->get_maxed_out_subnets( version => $v );
        my @s = map { $_->[0] } @pairs;
        $desc = "The following subnets are below $thr% free (IPv$v)";
        ( $headers, $rows ) = _ipblock_rows( \@s, "No maxed-out subnets found." );
    }
    elsif ( $rt eq 'unused_v4_statics' ) {
        my $sqldate = Netdot::Model->sqldate_days_ago( $days );
        my $static  = IpblockStatus->search( name => 'Static' )->first;
        my @ips = $static
               ? Ipblock->search_where(
                     { status => $static->id, version => 4, last_seen => { '<', $sqldate } },
                     { order_by => 'address' } )
               : ();
        my @unused;
        for my $ip (@ips) {
            next if int( $ip->interface // 0 ) != 0;
            next if $ip->snmp_devices;
            next if $ip->is_multicast;
            push @unused, $ip;
        }
        $desc = "Static addresses not seen on the network in the past $days days";
        ( $headers, $rows ) = _ipblock_rows( \@unused, 'No unused IPs found.' );
    }
    else {
        $headers = [ 'Report' ];
        $rows    = [ ['Select a report type.'] ];
        $desc    = 'IP reports';
    }

    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $headers, $rows, "ip_reports_".($rt//'all').".csv" );
    }

    my $form = qq{<form method="get" action="/reports/ip">}
             . _sel( 'report_type', $rt, @IP_OPTS )
             . qq{ <input type="submit" class="btn" value="Go"></form>};

    _render( $c, title => 'IP Reports', desc => $desc, form_html => $form, headers => $headers, rows => $rows );
}

# Render a list of Ipblock objects (CIDR / status / used_by / version / last_seen).
sub _ipblock_rows {
    my ( $blocks, $empty ) = @_;
    my @rows;
    for my $b ( @$blocks ) {
        my $st = eval { $b->status };     # IpblockStatus (browsable -> value + link)
        my $vl = eval { $b->vlan };       # Vlan (browsable -> value + link)
        my $ub = eval { $b->used_by };    # Entity (browsable -> value + link)
        push @rows, [
            _link( 'ipblock', $b->id, $b->cidr ),
            $st ? _link( 'ipblockstatus', $st->id, eval { $st->name } // '' ) : '',
            $vl ? _link( 'vlan', $vl->id, eval { $vl->get_label } // '' ) : '',
            $ub ? _link( 'entity', $ub->id, eval { $ub->get_label } // '' ) : '',
            _esc( $b->description // '' ),
        ];
    }
    return ( [ 'Address', 'Status', 'Vlan', 'Used By', 'Description' ],
             @rows ? \@rows : [ [$empty] ] );
}

# ---------------------------------------------------------------------------
# MAC addresses by vendor
# ---------------------------------------------------------------------------
sub macs ($c) {
    return if _guard($c);
    my $topn   = $c->param('topn') // 100;
    my $type   = $c->param('type') // 'node';
    $topn = 100 unless $topn =~ /^\d+$/;
    $type = 'node' unless grep { $_ eq $type } qw(node infrastructure all);

    my $form = qq{<form method="get" action="/reports/macs"> Top }
             . qq{<input type="text" size="4" name="topn" value="$topn"> Vendors of type }
             . _sel( 'type', $type, [ 'node', 'Node' ], [ 'infrastructure', 'Infrastructure' ], [ 'all', 'All' ] )
             . qq{ <input type="submit" value="Submit" name="submit"></form>};

    my @headers = ( 'OUI', 'Vendor', 'Count', '%' );
    my @rows;
    my ( $stats, $total ) = PhysAddr->vendor_count($type);
    $total = 1 unless $total;
    push @rows, [ 'Total in Database', '', "<strong>$total</strong>", '&nbsp;' ];
    my $i = 0;
    for my $oui ( sort { $stats->{$b}{total} <=> $stats->{$a}{total} } keys %$stats ) {
        $i++;
        my $count = $stats->{$oui}{total};
        # OUI -> filtered PhysAddr list (address LIKE <OUI>%), Mason
        # search_obj.html?table=PhysAddr&address=<OUI>*&res=1 equivalent.
        my $addr_q   = url_escape( $oui . '*' );
        my $oui_cell = sprintf( '<a href="/management/physaddr?address=%s">%s</a>', $addr_q, _esc( $oui ) );
        push @rows, [ $oui_cell, _esc( $stats->{$oui}{vendor} ), $count, sprintf( '%02.2f', $count / $total * 100 ) ];
        last if $i == $topn;
    }

    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, \@headers, \@rows, "macs_by_vendor_$type.csv" );
    }

    _render( $c, title => "MAC Addresses by Vendor (top $topn)", form_html => $form,
             headers => \@headers, rows => \@rows );
}

# ---------------------------------------------------------------------------
# IP per building (IP par Batiment)
# ---------------------------------------------------------------------------
sub ipbat ($c) {
    return if _guard($c);
    my $site = $c->param('site') // '';
    $site = 0 unless $site =~ /^\d+$/;

    my $sites = Netdot::Model->raw_sql(
        "SELECT DISTINCT site.id, site.name FROM \`site\`, \`sitesubnet\` WHERE site.id=sitesubnet.site ORDER BY site.name"
    )->{rows};
    my ( $sel, $name ) = ( '', '' );
    for my $r ( @$sites ) {
        $sel = ' selected' if $r->[0] == $site;
        $name = $r->[1]     if $r->[0] == $site;
    }
    my $form = qq{<form method="get" action="/reports/ipbat"><strong>Batiment:</strong> }
             . _sel( 'site', $site, map { [ $_->[0], $_->[1] ] } @$sites )
             . qq{ <input type="submit" value="display"></form>};

    my ( $headers, $rows );
    if ( $site > 0 ) {
        my $res = Netdot::Model->raw_sql(
            "SELECT ipblock.id, ipblock.address, ipblock.used_by AS ub1, pblock.used_by AS ub2, rrptr.rr, rrptr.ptrdname
             FROM sitesubnet, ipblock, ipblock AS pblock, rrptr
             WHERE sitesubnet.site=$site AND ipblock.parent=sitesubnet.subnet
               AND (ipblock.status=3 OR ipblock.status=6)
               AND ipblock.id=rrptr.ipblock AND ipblock.parent=pblock.id
             ORDER BY ipblock.address"
        )->{rows};
        my %ub;
        for my $r ( @{ Netdot::Model->raw_sql("SELECT id, name FROM entity ORDER BY id")->{rows} } ) {
            $ub{ $r->[0] } = $r->[1];
        }
        $headers = [ 'IP Address', 'Host', 'UB' ];
        my @rows;
        for my $r ( @$res ) {
            my $ubid = $r->[2];
            $ubid = $r->[3] if !defined $ubid || $ubid == 0;
            push @rows, [ _ip_cell( $r->[1], $r->[0] ),
                          _link('rr', $r->[4], $r->[5] // '' ),
                          _link('entity', $ubid, $ub{$ubid} // '' ) ];
        }
        $rows = @rows ? \@rows : [ ['No data for this building.'] ];
    }
    else {
        $headers = [ 'IP Address', 'Host', 'UB' ];
        $rows    = [ ['Select a building.'] ];
    }

    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $headers, $rows, "ipbat_".($site//'all').".csv" );
    }

    _render( $c, title => 'Rapport IP par Batiment', desc => $name ? "Batiment: $name" : undef,
             form_html => $form, headers => $headers, rows => $rows );
}

# ---------------------------------------------------------------------------
# Green list (security report)
# ---------------------------------------------------------------------------
sub security ($c) {
    return if _guard($c);
    my $type = 'Verte';
    my $esc  = $type;
    $esc =~ s/'/''/g;

    my %ent;
    for my $r ( @{ Netdot::Model->raw_sql("SELECT id, name FROM entity")->{rows} } ) {
        $ent{ $r->[0] } = $r->[1];
    }

    my $main_sql = "SELECT record.*,
                           rraddr.ipblock, ipblock.address, ipblock.used_by, subnet.used_by
                    FROM (SELECT rr.id, rr.name AS host, zone.name AS domain, rr.info
                          FROM \`rr\`, \`zone\` WHERE rr.info LIKE 'Liste $esc%' AND rr.zone=zone.id) AS record
                    LEFT JOIN rraddr  ON rraddr.rr=record.id
                    LEFT JOIN ipblock ON rraddr.ipblock=ipblock.id
                    LEFT JOIN ipblock AS subnet ON ipblock.parent=subnet.id
                    ORDER BY record.host, record.domain";

    # CNAME resolution map: rr.id => { cname, ipblock, address, ub }.
    my $cname_sql = "SELECT record.id, record.cid, record.cname,
                            rraddr.ipblock, ipblock.address, ipblock.used_by, subnet.used_by
                     FROM (SELECT rr1.id, rr2.id AS cid, rr1.cname
                           FROM (SELECT rr.id, rrcname.cname
                                 FROM \`rr\`, \`zone\`, \`rrcname\`
                                 WHERE rr.info LIKE 'Liste $esc%' AND rr.zone=zone.id AND rr.id=rrcname.rr) AS rr1
                           LEFT JOIN (SELECT rr.id, concat(rr.name,'.', zone.name) AS hostname
                                      FROM rr, zone WHERE rr.zone=zone.id) AS rr2
                              ON rr1.cname = rr2.hostname) AS record
                     LEFT JOIN rraddr  ON rraddr.rr=record.cid
                     LEFT JOIN ipblock ON rraddr.ipblock=ipblock.id
                     LEFT JOIN ipblock AS subnet ON ipblock.parent=subnet.id";
    my %cname;
    for my $r ( @{ Netdot::Model->raw_sql($cname_sql)->{rows} } ) {
        $cname{ $r->[0] } = { cname => $r->[2], ipblock => $r->[3], address => $r->[4],
                              ub => defined $r->[5] ? $r->[5] : $r->[6] };
    }

    my $res  = Netdot::Model->raw_sql($main_sql)->{rows};
    my @rows;
    for my $r ( @$res ) {
        my $ubid   = defined $r->[6] ? $r->[6] : $r->[7];
        my $host   = ( $r->[1] // '' ) . '.' . ( $r->[2] // '' );
        my $ip_id  = $r->[4];
        my $nip    = NetAddr::IP->new( $r->[5] );
        my @info   = split /\n/, ( $r->[3] // '' );

        if ( my $cn = $cname{ $r->[0] } ) {
            $host   .= ' -> ' . ( $cn->{cname} // '' );
            $ip_id   = $cn->{ipblock};
            $ubid    = $cn->{ub};
            $nip     = NetAddr::IP->new( $cn->{address} );
        }

        my ( $list, $contact, $date ) = ( '', '', '' );
        for my $line (@info) {
            $list    = $1 if $line =~ /^(Liste.*)$/;
            $contact = $1 if $line =~ /^Responsable:\s+(.*)$/;
            $date    = $1 if $line =~ /^Date:\s+(.*)$/;
        }

        my $ip_cell = defined $nip
                   ? sprintf( '<a href="/management/ipblock/%s">%s</a>', $ip_id, _esc( $nip->short ) )
                   : '&nbsp;';
        push @rows, [ _link('rr', $r->[0], $host), $ip_cell,
                      _link('entity', $ubid, $ent{$ubid} // '' ),
                      _esc($list), _esc($contact), _esc($date) ];
    }

    my $sec_headers = [ 'Host', 'IP Address', 'UB', 'List', 'Contact', 'Date' ];
    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $sec_headers, \@rows, 'security_liste_verte.csv' );
    }
    _render( $c, title => 'Liste Verte', headers => $sec_headers,
             rows => \@rows, sortable => 1 );
}

# ---------------------------------------------------------------------------
# UNIL custom reports
# ---------------------------------------------------------------------------
sub custom ($c) {
    return if _guard($c);
    my $cpus = Netdot::Model->config->get('DEFAULT_HINFO_CPU_VALUES');
    $cpus = {} unless ref $cpus eq 'HASH';
    my @hinfo = sort keys %$cpus;
    $c->render( template => 'reports/custom', layout => 'default', title => 'UNIL Reports',
                cpus => \@hinfo );
}

sub hinfo ($c) {
    return if _guard($c);
    my $cpu = $c->param('cpu') // 'NONE';
    $cpu =~ s/'//g;
    my $res = Netdot::Model->raw_sql(
        "SELECT rr.id, rr.name, zone.name, ipblock.address, ipblock.id
         FROM rrhinfo, rr, zone, rraddr, ipblock
         WHERE rrhinfo.cpu='$cpu' AND rrhinfo.rr=rr.id AND rr.zone=zone.id
           AND rraddr.rr=rr.id AND rraddr.ipblock=ipblock.id
         ORDER BY zone.id, rr.name"
    )->{rows};
    my @rows;
    for my $r ( @$res ) {
        push @rows, [ _link('rr', $r->[0], ( $r->[1] // '' ) . '.' . ( $r->[2] // '' ) ),
                      _ip_cell( $r->[3], $r->[4] ) ];
    }
    my $total = scalar @$res;
    push @rows, [ '<strong>Total</strong>', '<strong>' . $total . '</strong>' ];
    my $hi_headers = [ 'Hostname', 'IP' ];
    my $hi_rows    = @rows ? \@rows : [ ['No HINFO records for this CPU.'] ];
    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $hi_headers, $hi_rows, "hinfo_$cpu.csv" );
    }
    _render( $c, title => "Hosts by HINFO for CPU=$cpu", headers => $hi_headers,
             rows => $hi_rows );
}

sub usedby ($c) {
    return if _guard($c);
    my $ver = $c->param('version') // 4;
    $ver = ( $ver eq '4' || $ver eq '6' ) ? $ver : 4;
    my $res = Netdot::Model->raw_sql(
        "SELECT entity.id, entity.name, table1.total FROM
           (SELECT if (child.used_by>0, child.used_by, parent.used_by) AS owner, count(child.address) AS total
            FROM ipblock AS child, ipblock AS parent
            WHERE (child.status=6 OR child.status=3) AND child.parent=parent.id AND child.version=$ver
            GROUP BY owner) AS table1, entity
         WHERE table1.owner=entity.id ORDER BY table1.total DESC"
    )->{rows};
    my $total = 0;
    $total += $_->[2] for @$res;
    $total = 1 unless $total;
    my @rows;
    for my $r ( @$res ) {
        push @rows, [ _link('entity', $r->[0], $r->[1] // '' ), $r->[2],
                      sprintf( '%.1f%%', $r->[2] / $total * 100 ) ];
    }
    push @rows, [ '<strong>Total</strong>', '<strong>' . $total . '</strong>', '<strong>100%</strong>' ];
    my $ub_headers = [ 'Entity', 'Count', '%' ];
    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, $ub_headers, \@rows, "used_by_ipv$ver.csv" );
    }
    _render( $c, title => "IP Addresses by Entity (IPv$ver)", headers => $ub_headers,
             rows => [ @rows ] );
}

# ---------------------------------------------------------------------------
# Database (MySQL table information)
# ---------------------------------------------------------------------------
sub database ($c) {
    return if _guard($c);
    my @headers = ( 'Table', 'Rows', 'Data Length', 'Index Length', 'Max Data Length', 'Data Free', 'Create Time', 'Update Time', 'Comment' );
    my $dbh  = Netdot::Model->db_Main;
    my $q    = $dbh->prepare("SHOW TABLE STATUS");
    $q->execute();
    my @rows;
    my ( $ds, $is, $fs ) = ( 0, 0, 0 );
    while ( my ( $name, $engine, $version, $row_format, $rows_n, $avg, $dl, $mdl, $il, $df,
                 $ai, $ct, $ut, $chk, $coll, $checksum, $copts, $comment ) = $q->fetchrow_array ) {
        $ds += $dl; $is += $il; $fs += $df;
        push @rows, [ _esc($name), $rows_n // '', _fmt_size($dl), _fmt_size($il), _fmt_size($mdl),
                      _fmt_size($df), $ct // '', $ut // '', _esc($comment) ];
    }
    push @rows, [ '<b>Total Size:</b>', '&nbsp;', "<b>" . _fmt_size($ds) . "</b>",
                  "<b>" . _fmt_size($is) . "</b>", '&nbsp;', "<b>" . _fmt_size($fs) . "</b>", '&nbsp;', '&nbsp;', '&nbsp;' ];
    if ( ( $c->param('format') // '' ) eq 'csv' ) {
        return _csv( $c, \@headers, \@rows, 'mysql_table_status.csv' );
    }
    _render( $c, title => 'Table Information', headers => [ @headers ], rows => \@rows );
}

# ---------------------------------------------------------------------------
# Topology graph + poll stats (RRD/GraphViz) — graceful fallback when the
# tooling / data is not available in this environment.
# ---------------------------------------------------------------------------
sub topology ($c) {
    return if _guard($c);
    my $netdot_path = Netdot::Model->config->get('NETDOT_PATH') // '';
    my $graph_dir   = "$netdot_path/htdocs/img/graphs";
    my $root        = Netdot::Model->config->get('NMS_DEVICE') // '';
    my $root_dev    = $root ? eval { Device->search( name => $root )->first } : undef;

    my %defs = (
        no_vlans   => { file => 'whole_network_no_vlans.png',  vlans => 0, title => 'Network Graph without VLANs' },
        with_vlans => { file => 'whole_network_with_vlans.png', vlans => 1, title => 'Network Graph with VLANs' },
    );

    my $show_names = $c->param('show_names') ? 1 : 0;
    my $minlen     = $c->param('minlen') // 1;
    $minlen = 1 unless $minlen =~ /^[123]$/;

    # Regenerate on demand (whole-network graph is resource-heavy).
    my $note  = '';
    my $regen = $c->param('regen') // '';
    if ( $root_dev && $regen ) {
        require Netdot::UI;
        my $ui    = Netdot::UI->new;
        my @which = ( $regen eq '1' ) ? ( qw(no_vlans with_vlans) ) : ( $regen );
        my @msg;
        for my $k (@which) {
            my $def = $defs{$k} or next;
            my $abs = "$graph_dir/$def->{file}";
            my $ok  = eval {
                $ui->build_device_topology_graph(
                    id => $root_dev->id, depth => 99999, show_vlans => $def->{vlans},
                    show_names => $show_names, minlen => $minlen, format => 'png', filename => $abs,
                );
                1;
            };
            push @msg, $def->{title} . ( $ok ? '' : " (failed: $@)" );
        }
        $note = 'Regenerated: ' . join( '; ', @msg );
    }

    my @cards;
    for my $k ( qw(no_vlans with_vlans) ) {
        my $def = $defs{$k};
        my $abs = "$graph_dir/$def->{file}";
        my $st  = ( -e $abs ) ? stat($abs) : undef;
        push @cards, { key => $k, title => $def->{title}, file => $def->{file},
                       exists => $st ? 1 : 0,
                       size   => $st ? $st->size : 0,
                       mtime  => $st ? scalar( localtime( $st->mtime ) ) : '' };
    }
    $c->render( template => 'reports/topology', layout => 'default', title => 'Network Topology Graph',
                root => $root, note => $note, cards => \@cards,
                show_names => $show_names, minlen => $minlen );
}

sub pollstats ($c) {
    return if _guard($c);
    $c->render( template => 'reports/pollstats', layout => 'default', title => 'Polling Stats' );
}

sub poll ($c) {
    return if _guard($c);
    my $type = $c->param('type') // 'addr';
    $type = 'addr' unless grep { $_ eq $type } qw(addr dev time);
    my %titles = ( addr => 'Network Addresses', dev => 'Devices', time => 'Poll Time' );
    my %img    = ( addr => 'poll_addr_%s.png', dev => 'poll_dev_%s.png', time => 'poll_time_%s.png' );

    # RRD graphs need the populated POLL_STATS_FILE_PATH RRD (written by the
    # Netdot pollers). When absent, degrade gracefully.
    my $netdot_path = Netdot::Model->config->get('NETDOT_PATH') // '';
    my $rrd_file    = "$netdot_path/" . ( Netdot::Model->config->get('POLL_STATS_FILE_PATH') // '' );
    my $rrd_avail   = ( -e $rrd_file ) ? 1 : 0;
    my @periods     = ( [ '-1d', 'day',   'Last day' ], [ '-1w', 'week',   'Last week' ],
                        [ '-1m', 'month', 'Last month' ], [ '-1y', 'year',  'Last year' ] );

    my @cards;
    if ( $rrd_avail ) {
        require Netdot::UI;
        my $ui = Netdot::UI->new;
        for my $p (@periods) {
            my ( $start, $tag, $label ) = @$p;
            my $img = sprintf( $img{$type}, $tag );
            my $ok  = eval { $ui->rrd_graph( type => $type, period => $start, web_path => '', img => $img,
                                              title => $titles{$type} ); 1 };
            push @cards, { label => $label, img => $img, ok => $ok };
        }
    }
    $c->render( template => 'reports/poll', layout => 'default', title => $titles{$type},
                type => $type, title => $titles{$type}, rrd_avail => $rrd_avail, rrd_file => $rrd_file,
                cards => \@cards );
}

1;
