package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;

# BOUNDED, paginated list of one object type (SQL LIMIT/OFFSET + retrieve by id).
# Reuses the Netdot model, out of Apache. Works for every type in the Registry.
sub list ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $table  = $class->table;
    my $dbh    = Netdot::Model->db_Main;

    # Per-user access: a User sees only the objects they may view (none by
    # default). Admin/Operator are unrestricted (view access to everything).
    my $person    = $c->current_person;
    my $where_sql = undef;    # e.g. " WHERE (id IN (?,?) OR zone IN (?))"
    my @binds;
    if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
        my ( $w, $b ) = Netdot::Mojo::Permissions->viewable_predicate( $class, $person );
        $where_sql = defined $w ? " WHERE $w" : undef;
        @binds     = defined $b ? @$b : ();
    }

    # ipblock: hierarchical view. The list shows the ROOT blocks only (parent is
    # NULL, version 4); clicking one shows its children (see Show#show).
    if ( $type eq 'ipblock' ) {
        # Direct list-context call: get_roots() uses wantarray, so it must NOT
        # be wrapped in eval{} // () (that degrades to scalar -> first root only).
        my @roots = $class->get_roots('all');
        if ( defined $where_sql ) {
            # A root is visible if it, any descendant, or an allowed block's
            # ancestor path includes it: i.e. keep the roots that lead down to a
            # viewable block, so the user can drill in.
            my %keep;
            my $sthv = $dbh->prepare( "SELECT id FROM $table $where_sql" );
            $sthv->execute(@binds);
            for my $row ( @{ $sthv->fetchall_arrayref } ) {
                my $ip = eval { $class->retrieve( $row->[0] ) };
                next unless $ip;
                $keep{ $row->[0] } = 1;
                $keep{ $_->id } = 1 for eval { $ip->get_ancestors } || ();
            }
            @roots = grep { $keep{ $_->id } } @roots;
        }
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

    my $wc = $where_sql // '';
    my ($total) = $dbh->selectrow_array( "SELECT COUNT(*) FROM $table $wc", undef, @binds );

    my $sth = $dbh->prepare( "SELECT id FROM $table $wc ORDER BY id LIMIT ? OFFSET ?" );
    $sth->execute( @binds, $per, $offset );
    my @objs = map { $class->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };

    # May the current user delete objects of this type? (controls the delete form)
    my $can_delete = Netdot::Mojo::Permissions->has_action( $class, $person, 'delete' );

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
        can_delete => $can_delete,
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

    # Per-user filter: a User exports only the objects they may view (none by
    # default). Admin/Operator export everything.
    my $person    = $c->current_person;
    my $where_sql = undef;
    my @binds;
    if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
        my ( $w, $b ) = Netdot::Mojo::Permissions->viewable_predicate( $class, $person );
        $where_sql = defined $w ? " WHERE $w" : undef;
        @binds     = defined $b ? @$b : ();
    }

    my $emit = sub {
        my ($o) = @_;
        my @vals;
        for my $cm (@colmeta) {
            my $col = $cm->{col};
            my $val = $cm->{links}
                     ? eval { my $fo = $o->$col; $fo ? $fo->get_label : '' }
                     : eval { $o->$col };
            push @vals, Netdot::Mojo::Registry::csv_field( defined $val ? $val : '' );
        }
        $csv .= join( ',', @vals ) . "\n";
    };

    my $table = $class->table;
    my $dbh   = Netdot::Model->db_Main;
    if ( defined $where_sql ) {
        my $sth = $dbh->prepare( "SELECT id FROM $table $where_sql ORDER BY id" );
        $sth->execute(@binds);
        my $ids = $sth->fetchall_arrayref;
        $emit->( $class->retrieve( $_->[0] ) ) for @$ids;
    } else {
        my $iter = $class->retrieve_all;
        while ( my $o = $iter->next ) { $emit->($o); }
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

    # Only delete objects the current user may delete (Admin: all).
    my $person = $c->current_person;
    my $access = Netdot::Mojo::Permissions->user_type( $person ) eq 'Admin'
               ? undef
               : Netdot::Mojo::Permissions->allowed_objects( $person );

    my $deleted = 0;
    for my $id (@ids) {
        my $o = eval { $class->retrieve( $id ) };
        next unless $o;
        next unless Netdot::Mojo::Permissions->can( $person, 'delete', $o, $access );
        $deleted++ if eval { $o->delete };
    }

    # Back to the list with a small confirmation.
    $c->redirect_to( $c->url_for( "${type}_list" ) . "?msg=deleted-$deleted" );
}

1;
