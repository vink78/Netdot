package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;

# Per-type filter columns for list pages (equivalent of Mason's
# search_obj.html?table=..&<col>=..&res=1). Only these columns may be passed.
# 'num' = numeric id only; 'str' = free string (the model quotes it). Filtering
# is done through the model's own search_like() (no hand-written SQL); the
# per-user 'view' rule is re-applied to the match set.
my %FILTERS = (
    device   => { site => 'num', product => 'num', os => 'str' },
    physaddr => { address => 'str' },
);

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

    # Optional column filters (Mason search_obj.html equivalent): resolved through
    # the model's own search_like(); the per-user 'view' rule is re-applied to the
    # (unbounded) match set, which is then paginated.
    my @filters;
    if ( my $spec = $FILTERS{$type} ) {
        for my $col ( keys %$spec ) {
            my $v = $c->param( $col );
            next unless defined $v && length $v;
            if ( $spec->{$col} eq 'num' ) {
                push @filters, ( $col => $v ) if $v =~ /^\d+$/;
            } else {   # 'str' - free string; the model quotes the value
                push @filters, ( $col => $v );
            }
        }
    }

    # Free-text search box (?search=, see list.html.ep): match the type's primary
    # display column via search_like (LIKE %v%; quote for exact, */? for wildcards).
    # The dedicated rr/physaddr/ipblock searches override this for richer logic.
    if ( my $q = $c->param('search') ) {
        $q =~ s/^\s+|\s+$//g;
        push @filters, ( $cols->[0] => $q ) if length $q;
    }

    my ( @objs, $total );
    if ( @filters ) {
        @objs  = $class->search_like( @filters );
        $total = scalar @objs;
        if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
            my $access = Netdot::Mojo::Permissions->allowed_objects( $class, $person );
            @objs = grep { Netdot::Mojo::Permissions->can( $class, $person, 'view', $_, $access ) } @objs;
            $total = scalar @objs;
        }
        my $end = $offset + $per;
        $end     = $total if $end > $total;
        @objs    = $offset < $total ? @objs[ $offset .. $end - 1 ] : ();
    } else {
        my $wc = $where_sql // '';
        ( $total ) = $dbh->selectrow_array( "SELECT COUNT(*) FROM $table $wc", undef, @binds );
        my $sth = $dbh->prepare( "SELECT id FROM $table $wc ORDER BY id LIMIT ? OFFSET ?" );
        $sth->execute( @binds, $per, $offset );
        @objs    = map { $class->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };
    }

    # May the current user delete objects of this type? (controls the delete form)
    my $can_delete = Netdot::Mojo::Permissions->has_action( $class, $person, 'delete' );

    # Per-column meta tags (headers) and foreign-key targets (for cell links).
    my %coltag  = map { $_ => Netdot::Mojo::Registry::column_tag( $class, $_ ) } @$cols;
    my %linkkey = map { $_ => Netdot::Mojo::Registry::column_link_key( $class, $_ ) } @$cols;
    my $first   = $cols->[0];

    # Build display rows: id (for the link) + the type's display columns. FK
    # columns render as links to the related object's detail page; the first
    # column stays raw (the template links it to the type's own detail page).
    my @rows;
    for my $obj (@objs) {
        my %row = ( id => $obj->id );
        for my $col (@$cols) {
            my $v = eval { $obj->$col };
            $v = undef if $@;
            my $label = Netdot::Mojo::Registry::format_value( $v );
            if ( $col eq $first ) {
                $row{$col} = $label;
                next;
            }
            my $id = ref( $v ) ? eval { $v->id } : $v;
            $row{$col} = ( $linkkey{$col} && defined $id && $id =~ /^\d+$/ )
                ? sprintf( '<a href="/management/%s/%s">%s</a>',
                            $linkkey{$col}, $id, Netdot::Mojo::Registry::esc( $label ) )
                : Netdot::Mojo::Registry::esc( $label );
        }
        push @rows, \%row;
    }

    my $start     = @rows ? $offset + 1 : 0;
    my $last_item = $offset + scalar(@rows);

    # Search box on the list page (list.html.ep): shown for every type. Generic
    # types search the primary column via ?search= (see search()); rr/physaddr
    # keep their dedicated richer searches; "Names within" shows only for rr.
    my %extra;
    $extra{search_url}         = $c->url_for( "${type}_search" );
    $extra{search_title}       = 'Search ' . $spec->{label};
    $extra{search_placeholder} = 'Filter by ' . Netdot::Mojo::Registry::column_tag( $class, $cols->[0] );
    if ( $type eq 'rr' ) {
        my @zones = Zone->retrieve_all;
        @zones = sort { $a->name cmp $b->name } @zones;
        $extra{zones}              = \@zones;
        $extra{search_title}       = 'Search DNS Records';
        $extra{search_placeholder} = 'Name / IP / MAC';
    } elsif ( $type eq 'physaddr' ) {
        $extra{search_title}       = 'Search MAC addresses';
        $extra{search_placeholder} = 'MAC address / OUI';
    }

    $c->render(
        template  => 'management/list',
        layout    => 'default',
        title     => ucfirst($type),
        type      => $type,
        cols      => $cols,
        coltags   => \%coltag,
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

# Generic per-type search box (route /management/<type>/search). Delegates to
# list(), which reads ?search= and filters the primary display column through
# the model's search_like(); the per-user 'view' rule is re-applied and the
# results are paginated and rendered by the same list template. The dedicated
# rr/physaddr/ipblock controllers override this for their richer multi-field
# searches (name / IP / MAC, hierarchical IP blocks, ...).
sub search ($c) { $c->list; }

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
    $h->content_disposition( 'attachment; filename="' . $type . '.csv"' );
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
