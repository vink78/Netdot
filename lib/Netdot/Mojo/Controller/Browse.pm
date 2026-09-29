package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;

# BOUNDED, paginated list of one object type (SQL LIMIT/OFFSET + retrieve by id).
# Reuses the Netdot model, out of Apache. Works for every type in the Registry.
sub list ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $table = $class->table;

    # ipblock: hierarchical view. The list shows the ROOT blocks only (parent is
    # NULL, version 4); clicking one shows its children (see Show#show).
    if ( $type eq 'ipblock' ) {
        # Direct list-context call: get_roots() uses wantarray, so it must NOT
        # be wrapped in eval{} // () (that degrades to scalar -> first root only).
        my @roots = $class->get_roots('all');
        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => 'IP Blocks',
            viewtype   => 'block',
            blocks     => \@roots,
            breadcrumb => [],
        );
        return;
    }

    my $per    = eval { Netdot::Model->config->get('DEFAULT_PERPAGE') } || 50;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    my $dbh   = Netdot::Model->db_Main;
    my ($total) = $dbh->selectrow_array("SELECT COUNT(*) FROM $table");

    my $sth = $dbh->prepare("SELECT id FROM $table ORDER BY id LIMIT ? OFFSET ?");
    $sth->execute($per, $offset);
    my @objs = map { $class->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };

    # Build display rows: id (for the link) + the type's display columns.
    my @rows;
    for my $obj (@objs) {
        my %row = ( id => $obj->id );
        for my $col (@$cols) {
            my $v = eval { $obj->$col };
            $row{$col} = $@ ? '' : Netdot::Mojo::Registry::format_value($v);
        }
        push @rows, \%row;
    }

    my $start     = @rows ? $offset + 1 : 0;
    my $last_item = $offset + scalar(@rows);

    # Search boxes on the list page (mac.html / host_tasks.html). The box is
    # generic (see list.html.ep); "Names within" only shows when zones are given.
    my %extra;
    if ( $type eq 'rr' ) {
        my @zones = Zone->retrieve_all;
        @zones = sort { $a->name cmp $b->name } @zones;
        $extra{zones}              = \@zones;
        $extra{search_url}         = $c->url_for( 'rr_search' );
        $extra{search_title}       = 'Search DNS Records';
        $extra{search_placeholder} = 'Name / IP / MAC';
    } elsif ( $type eq 'physaddr' ) {
        $extra{search_url}         = $c->url_for( 'physaddr_search' );
        $extra{search_title}       = 'Search MAC addresses';
        $extra{search_placeholder} = 'MAC address / OUI';
    }

    $c->render(
        template  => 'management/list',
        layout    => 'default',
        title     => ucfirst($type),
        type      => $type,
        cols      => $cols,
        rows      => \@rows,
        total     => $total,
        per       => $per,
        offset    => $offset,
        start     => $start,
        last_item => $last_item,
        %extra,
    );
}

# CSV export of ALL objects of one type (header line + every row), streamed from
# the model iterator. Relationships are rendered via ->get_label (like viewtext.html).
sub csv ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $meta  = $class->meta_data;

    # Pre-compute per-column metadata once (header tag + whether it is a relationship).
    my @colmeta;
    for my $col (@$cols) {
        my $tag   = Netdot::Mojo::Registry::column_tag( $class, $col );
        my $links = eval { $meta->get_column( $col )->links_to };
        push @colmeta, { col => $col, tag => $tag, links => $links };
    }

    my $csv  = join( ',', map { Netdot::Mojo::Registry::csv_field( $_->{tag} ) } @colmeta ) . "\n";
    my $iter = $class->retrieve_all;
    while ( my $o = $iter->next ) {
        my @vals;
        for my $cm (@colmeta) {
            my $col = $cm->{col};
            my $val = $cm->{links}
                     ? eval { my $fo = $o->$col; $fo ? $fo->get_label : '' }
                     : eval { $o->$col };
            push @vals, Netdot::Mojo::Registry::csv_field( defined $val ? $val : '' );
        }
        $csv .= join( ',', @vals ) . "\n";
    }

    my $h = $c->res->headers;
    $h->content_type( 'text/csv' );
    $h->content_disposition( 'attachment', filename => "$type.csv" );
    $c->render( data => $csv );
}

# Delete the checked objects of one type (batch: params named "<type>__<id>").
sub delete ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my @ids;
    for my $name ( @{ $c->req->params->names } ) {
        my ($id) = $name =~ /^\Q$type\E__(\d+)$/;
        push @ids, $id if $id;
    }

    my $deleted = 0;
    for my $id (@ids) {
        my $o = eval { $class->retrieve( $id ) };
        next unless $o;
        $deleted++ if eval { $o->delete };
    }

    # Back to the list with a small confirmation.
    $c->redirect_to( $c->url_for( "${type}_list" ) . "?msg=deleted-$deleted" );
}

1;
