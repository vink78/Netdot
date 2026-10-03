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

# Numeric-aware sort key for a display value: both-numeric -> numeric compare,
# otherwise case-insensitive text compare (mirrors the client-side tablesort.js).
sub _kcmp {
    my ( $x, $y ) = @_;
    $x = '' unless defined $x;
    $y = '' unless defined $y;
    if ( $x =~ /^-?\d+(?:\.\d+)?$/ && $y =~ /^-?\d+(?:\.\d+)?$/ ) { return $x <=> $y; }
    return lc( $x ) cmp lc( $y );
}

# All ids of $table ordered by the first display column (id tie-break), applying
# $wc (a " WHERE ..." clause, or '') with @binds. A relationship first column
# (FK) is ordered by the related object's label via a LEFT JOIN (the predicate is
# wrapped in a subquery so its bare column names stay unambiguous); a scalar
# column is ordered in SQL. Returns (\@ids, $total).
sub _ordered_ids {
    my ( $dbh, $table, $first, $linkkey0, $sort_col, $wc, @binds ) = @_;
    my $w  = defined $wc ? $wc : '';
    my @all;
    if ( $linkkey0 ) {
        my $rel    = Netdot::Mojo::Registry::spec( $linkkey0 )->{class};
        my $reltab = $rel->table;
        my @lbl;
        @lbl = eval { $rel->meta_data->get_labels };    # list context (no || ())
        my $rellab = ( grep { /^[A-Za-z_][A-Za-z0-9_]*$/ } @lbl )[0] // 'id';
        my $pred   = $w ne '' ? " WHERE d.id IN ( SELECT id FROM $table $w )" : '';
        my $sql    = "SELECT d.id, $reltab.$rellab AS sk FROM $table d "
                    . "LEFT JOIN $reltab ON d.$first = $reltab.id $pred";
        my $sth    = $dbh->prepare( $sql );
        $sth->execute( @binds );
        my $rows   = $sth->fetchall_arrayref || [];
        my @pairs  = map { [ $_->[0], defined $_->[1] ? $_->[1] : '' ] } @$rows;
        @pairs     = sort { _kcmp( $a->[1], $b->[1] ) } @pairs;
        @all       = map { $_->[0] } @pairs;
    }
    else {
        my $sql  = "SELECT id FROM $table $w ORDER BY $sort_col ASC, id";
        my $sth  = $dbh->prepare( $sql );
        $sth->execute( @binds );
        @all = map { $_->[0] } @{ $sth->fetchall_arrayref || [] };
    }
    return ( \@all, scalar @all );
}

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

    # Default server-side ordering: the type's FIRST display column (the label),
    # id as a stable tie-breaker. Needed because the list is paginated -- the
    # client-side tablesort.js only sorts the current page, so a global order must
    # come from the data. If the first column is a relationship (FK, e.g.
    # device.name -> RR) the raw column holds the FK id, so ordering by it would
    # be wrong; instead sort by the related object's label via a LEFT JOIN. The
    # column names come from the trusted spec/meta (never the user) and are
    # validated anyway.
    my $first    = $cols->[0];
    my $linkkey0 = Netdot::Mojo::Registry::column_link_key( $class, $first );
    my $sort_col = $first;
    $sort_col = 'id' unless $sort_col =~ /^[A-Za-z_][A-Za-z0-9_]*$/;

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
        # Root filters (port of ip.html rootversion + show_ch_util): an IPv4/IPv6
        # selector and a utilization toggle. Defaults keep the current behaviour
        # (all versions, utilization shown). show_ch_util is a checkbox backed by
        # a hidden =0 field, so it is present after any submit; absent on a fresh
        # load (default ON).
        my $rootversion = $c->param('rootversion') // 'all';
        $rootversion = '4' unless $rootversion =~ /^(?:4|6|all)$/;
        my $su        = $c->param('show_ch_util');
        my $show_util = defined $su ? ( $su eq '1' ? 1 : 0 ) : 1;
        # Direct list-context call: get_roots() uses wantarray, so it must NOT
        # be wrapped in eval{} // () (that degrades to scalar -> first root only).
        my @roots = $class->get_roots($rootversion);
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
            template    => 'management/ipblock',
            layout      => 'default',
            title       => 'IP Blocks',
            viewtype    => 'block',
            blocks      => \@roots,
            breadcrumb  => [],
            rootversion => $rootversion,
            show_util   => $show_util,
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

    # Free-text search box (?search=, see list.html.ep): a raw, parameterised
    # LIKE %q% on the type's primary display column, combined with the per-user
    # 'view' predicate. Deliberately NOT search_like() -- that method is
    # overridden per class (e.g. Device::search_like(name=>..) matches DNS RR
    # names / aliases, not device.name), so a uniform free-text box needs the raw
    # query. The dedicated rr/physaddr/ipblock searches override this.
    my $q = $c->param('search');
    $q = '' unless defined $q;
    $q =~ s/^\s+|\s+$//g;

    my ( @objs, $total );
    if ( length $q ) {
        my $like = "%$q%";
        my $wc   = defined $where_sql
                 ? "$where_sql AND ( $first LIKE ? )"
                 : " WHERE $first LIKE ? ";
        my @qb   = ( @binds, $like );
        my ( $all, $t );
        my $ok = eval { ( $all, $t ) = _ordered_ids( $dbh, $table, $first, $linkkey0, $sort_col, $wc, @qb ); 1 };
        if ( $ok && defined $all ) {
            my $last = $offset + $per - 1;
            $last    = $#$all if $last > $#$all;
            @objs   = map { $class->retrieve( $_ ) } @$all[ $offset .. $last ];
            $total  = $t;
        }
        else {    # bad/missing column: show nothing (never leak the unfiltered set)
            $c->app->log->error( "list search on $table.$first failed: $@" );
            ( @objs, $total ) = ( (), 0 );
        }
    }
    elsif ( @filters ) {
        @objs  = $class->search_like( @filters );
        # Same first-column order as the SQL paths above (search_like has no
        # ORDER BY). No-op if @objs holds an iterator (->col fails -> '' keys),
        # so it cannot break the non-list return some classes use.
        my $skey = sub { my $v = eval { $_[0] -> $sort_col }; $v = undef if $@;
                         Netdot::Mojo::Registry::format_value( $v ) // '' };
        @objs   = sort { _kcmp( $skey->($a), $skey->($b) ) } @objs;
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
        my ( $all, $t ) = _ordered_ids( $dbh, $table, $first, $linkkey0, $sort_col, $where_sql // '', @binds );
        my $last = $offset + $per - 1;
        $last    = $#$all if $last > $#$all;
        @objs   = map { $class->retrieve( $_ ) } @$all[ $offset .. $last ];
        $total  = $t;
    }

    # May the current user delete objects of this type? (controls the delete form)
    my $can_delete = Netdot::Mojo::Permissions->has_action( $class, $person, 'delete' );

    # Per-column meta tags (headers) and foreign-key targets (for cell links).
    # ($first / $linkkey0 / $sort_col are computed above, before the queries.)
    my %coltag  = map { $_ => Netdot::Mojo::Registry::column_tag( $class, $_ ) } @$cols;
    my %linkkey = map { $_ => Netdot::Mojo::Registry::column_link_key( $class, $_ ) } @$cols;

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
                ? sprintf( '<a href="%s">%s</a>',
                           Netdot::Mojo::Registry::set_uri( "/management/$linkkey{$col}/$id" ),
                           Netdot::Mojo::Registry::esc( $label ) )
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

    # Export in the same first-column order as the list view.
    my $sort_col = $cols->[0];
    $sort_col = 'id' unless $sort_col =~ /^[A-Za-z_][A-Za-z0-9_]*$/;

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
    my $first    = $cols->[0];
    my $linkkey0 = Netdot::Mojo::Registry::column_link_key( $class, $first );
    my ( $ids )  = _ordered_ids( $dbh, $table, $first, $linkkey0, $sort_col, $where_sql // '', @binds );
    $emit->( $class->retrieve( $_ ) ) for @$ids;

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
