package Netdot::Mojo::Detail;

# Shared builders for read-only object detail pages. Used by the generic
# Controller::Show and by dedicated controllers (Zone, ContactList, Closet)
# so that the "attributes" table and the "has_many relations" tables are built
# identically everywhere.
#
# build_attrs($obj, $class)        -> [ [tag, text, href], ... ]
# build_relations($obj, $per, $off)-> [ {title, cols, rows, total, per, offset,
#                                          start, last_item, csv_rel}, ... ]

use strict;
use warnings;

use Netdot;
use Netdot::Mojo::Registry;

# Attributes table: every non-sensitive column of the class's "all" view, in
# meta order, with user-friendly tags. FK values become links when the target
# type has a route (Registry::link_for).
sub build_attrs {
    my ($obj, $class) = @_;
    my @attrs;
    for my $cd ( @{ Netdot::Mojo::Registry::display_columns($class) } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        $v = undef if $@;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::attr_display( $class, $col, $v ) };
        push @attrs, [ $tag, $text, $href ];
    }
    return \@attrs;
}

# Editable field specs for the in-place edit form: the class's "all"-view columns
# that are non-sensitive. Scalar columns (text|number|textarea|checkbox) carry
# { name, tag, kind, value } (checkbox value => 0/1). FK columns carry
# { name, tag, kind=>'fk', target, max, cur_id, cur_label, options }:
#   - small target table (count <= DEFAULT_SELECTMAX): options = all {id,label}
#     (the form renders a plain <select>).
#   - large target (RR, Ipblock, ...): options = undef (the form renders a
#     keyword search box that queries the API; the dropdown is never dumped).
# FK targets that are not a registered type are skipped (field stays read-only).
# Drives the form for every generic detail page (Controller::Show).
sub build_edit_fields {
    my ( $obj, $class ) = @_;
    my @fields;
    my $maxselect = eval { Netdot->config->get('DEFAULT_SELECTMAX') } || 100;
    for my $cd ( @{ Netdot::Mojo::Registry::display_columns( $class ) } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive( $col );

        my $target = Netdot::Mojo::Registry::column_link_key( $class, $col );    # FK registry key or undef
        if ($target) {
            my $tspec  = Netdot::Mojo::Registry::spec( $target );
            my $tclass = $tspec ? $tspec->{class} : undef;
            next unless $tclass;
            my $cur_id  = eval { int( $obj->$col // 0 ) };
            $cur_id     = 0 unless defined $cur_id && $cur_id > 0;
            my $cur_obj = $cur_id ? eval { $obj->$col } : undef;
            my $count   = eval { $tclass->count_all } // 0;
            my $options;
            if ( $count <= $maxselect ) {
                my @all = eval { $tclass->retrieve_all };    # list context (no "||" — it scalarizes)
                @all    = sort { _fk_label( $a ) cmp _fk_label( $b ) } @all;
                $options = [ map { { id => $_->id, label => _fk_label( $_ ) } } @all ];
            }
            push @fields, {
                name      => $col,
                tag       => $tag,
                kind      => 'fk',
                target    => $target,
                max       => $maxselect,
                cur_id    => $cur_id,
                cur_label => $cur_obj ? _fk_label( $cur_obj ) : '',
                options   => $options,
            };
            next;
        }

        my $type = Netdot::Mojo::Registry::column_type( $class, $col );
        # System-managed timestamps (Last ARP / Last FWT / Last Updated /
        # First Discovered / …) are informational, not user-editable — the
        # Mason Basics view renders them edit=>0. Keep them read-only (they
        # still show in the attributes table). `date` fields (Down From/Until)
        # stay editable.
        next if defined $type && $type eq 'timestamp';
        my $kind =
            ( $type eq 'bool' )    ? 'checkbox'
          : ( $type eq 'integer' ) ? 'number'
          : ( $type eq 'text' )    ? 'textarea'
          : ( $type eq 'date' )    ? 'date'
          :                          'text';
        my $val  = eval { $obj->$col };
        $val     = '' unless defined $val;
        $val     = '' if $kind eq 'date' && $val =~ /^0000-00-00/;   # zero-date sentinel = empty
        push @fields, {
            name  => $col,
            tag   => $tag,
            kind  => $kind,
            value => ( $kind eq 'checkbox' ? ( $val ? 1 : 0 ) : $val ),
        };
    }
    return \@fields;
}

# Label for an FK option: the object's get_label (falls back to "#id").
sub _fk_label {
    my ($o) = @_;
    my $l = eval { $o->get_label };
    return ( defined $l && length $l ) ? $l : '#' . ( eval { $o->id } // '' );
}

# has_many relations (like the old Mason view.html "View" section): one table
# per non-empty relation. Columns from _rel_columns (brief view; for join /
# connector tables whose label IS the FK set the FK columns are shown as
# clickable cells). Rows paginated via $offset; $per is the page size.
sub build_relations {
    my ($obj, $per, $offset) = @_;
    $offset = 0 unless defined $offset && $offset > 0;

    my %linksfrom;
    eval { %linksfrom = ref($obj)->meta_data->get_links_from };

    my @relations;
    for my $rel ( sort keys %linksfrom ) {
        my $rtables = $linksfrom{$rel};
        next unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        next unless $related && length $related;

        # Fetch the relation ordered + paginated in SQL (ORDER BY + LIMIT/OFFSET),
        # so the ordering is consistent across pages and Ipblock orders by the
        # exact integer address (IPv4 before IPv6). $page is the current page;
        # $total is the full count.
        my ( $page_ref, $total ) = relation_objects( $obj, $rel, $per, $offset );
        next unless $total;
        my @page = @{ $page_ref };

        my ( $cols, $show_label ) = rel_columns($related);
        # In the no-label-column case (all brief cols are label cols), the object's
        # own scalar label column links to its detail page (FK label cols still
        # link to their target via the ref branch below).
        my %islabel;
        eval { %islabel = map { $_ => 1 } $related->meta_data->get_labels } unless $show_label;

        my @rows;
        for my $o2 (@page) {
            my @cells;
            if ($show_label) {
                my ( $lt, $lh ) = @{ Netdot::Mojo::Registry::link_for($o2) };
                push @cells, [ $lt // ( '#' . ( eval { $o2->id } // '' ) ), $lh // '' ];
            }
            for my $cd ( @$cols ) {
                my ( $col ) = @$cd;
                my $v = eval { $o2->$col };
                $v = undef if $@;
                if ( ref $v ) {
                    my ( $ct, $ch ) = @{ Netdot::Mojo::Registry::link_for($v) };
                    $ct = obj_text($v);
                    push @cells, [ $ct // '', $ch // '' ];
                } else {
                    my $text = Netdot::Mojo::Registry::format_value($v) // '';
                    my $href = '';
                    if ( !$show_label && $islabel{$col} ) {
                        my ( $lt, $lh ) = @{ Netdot::Mojo::Registry::link_for($o2) };
                        $href = $lh // '';
                    }
                    push @cells, [ $text, $href ];
                }
            }
            push @rows, \@cells;
        }
        push @relations, {
            title     => sprintf( '%s (%d)', $rel, $total ),
            cols      => $show_label
                              ? [ ucfirst($related), map { $_->[1] } @$cols ]
                              : [ map { $_->[1] } @$cols ],
            rows      => \@rows,
            total     => $total,
            per       => $per,
            offset    => $offset,
            start     => $total ? $offset + 1 : 0,
            last_item => $offset + scalar( @page ),
            csv_rel   => $rel,
        };
    }
    return \@relations;
}

# Ordered relation objects via SQL. Looks up the relation's target class + FK and
# delegates to _relation_fetch. $per undef/0 = no LIMIT (all rows, for CSV).
# Returns ( \@objs, $total ).
sub relation_objects {
    my ( $obj, $rel, $per, $offset ) = @_;
    my %linksfrom;
    eval { %linksfrom = ref( $obj )->meta_data->get_links_from };
    my $rtables = $linksfrom{$rel};
    return ( [], 0 ) unless ref $rtables eq 'HASH';
    my ($related) = sort keys %$rtables;
    return ( [], 0 ) unless $related && length $related;
    my $fk = $rtables->{$related};
    return _relation_fetch( $obj, $related, $fk, $per, $offset );
}

# SQL fetch of a relation: ordered (ORDER BY) + paginated (LIMIT/OFFSET). For
# connector / join tables, the object's referenced column is ordered via a JOIN
# (so e.g. a site's subnets order by the ipblock's integer address). Returns the
# page of target objects + the total count.
sub _relation_fetch {
    my ( $obj, $target, $fk, $per, $offset ) = @_;
    my $tclass = "Netdot::Model::$target";
    my $tmeta  = eval { $tclass->meta_data };
    return ( [], 0 ) unless $tmeta;
    my $ttable = ( eval { $tclass->table } ) // lc $target;
    my $dbh    = Netdot::Model->db_Main();

    # Sort expression + optional JOIN. Connector / join tables order by the
    # referenced object's label (joined via the connector's own FK); direct
    # relations order by their own first label column.
    my ( $sort_sql, $join_sql ) = ( 't.id', '' );
    if ( my $is_join = eval { $tmeta->is_join } ) {
        my %linksto;
        eval { %linksto = $tmeta->get_links_to };
        my ( $obj_fk ) = sort grep { defined $linksto{$_} && $_ ne $fk } keys %linksto;
        if ( defined $obj_fk && $linksto{$obj_fk} ) {
            my $obj_class = $linksto{$obj_fk};
            my $obj_table = ( eval { "Netdot::Model::$obj_class"->table } ) // lc $obj_class;
            my ( $o_sort ) = _rel_label_sort( $obj_class, 'o' );
            $sort_sql = $o_sort;
            $join_sql = "JOIN $obj_table o ON t.$obj_fk = o.id";
        }
    }
    else {
        ( $sort_sql, $join_sql ) = _rel_label_sort( $target, 't' );
    }

    my $where = "t.$fk = ?";
    my $total = 0;
    eval {
        $total = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM $ttable t $join_sql WHERE $where", undef, $obj->id
        );
        $total = 0 unless defined $total;
    };
    return ( [], 0 ) unless $total;

    my $lim = ( defined $per && $per > 0 ) ? 'LIMIT ? OFFSET ?' : '';
    my $sql = "SELECT t.id FROM $ttable t $join_sql WHERE $where ORDER BY $sort_sql $lim";
    my @pks;
    eval {
        my $rows = $lim
          ? $dbh->selectall_arrayref( $sql, undef, $obj->id, $per, $offset )
          : $dbh->selectall_arrayref( $sql, undef, $obj->id );
        @pks = map { $_->[0] } @$rows if ref $rows eq 'ARRAY';
    };
    my @objs;
    for my $pk (@pks) {
        my $o = eval { $tclass->retrieve($pk) };
        push @objs, $o if $o;
    }
    return ( \@objs, $total );
}

# ( $sort_sql, $join_sql ) to order a table (aliased $alias) by its first
# label column, so the SQL ORDER BY matches the on-screen first column:
#   Ipblock -> integer `address` (natural IP order, IPv4 before IPv6).
#   If the first label column is itself a RELATIONSHIP (an FK, e.g.
#     device.name -> rr), the related table is LEFT JOINed (alias o) and the
#     related object's first label is ordered instead -- i.e. a device is
#     ordered by its DNS name (rr.name, the value shown as the label), not the
#     numeric FK nor the SNMP-reported sysname.
# Every other class orders by its first label column. $alias prefixes the
# column (t. for the relation table, o. for a joined object).
sub _rel_label_sort {
    my ( $class, $alias ) = @_;
    return ( "$alias.address", '' ) if $class eq 'Ipblock';
    my $meta   = eval { "Netdot::Model::$class"->meta_data };
    my @labels;
    eval { @labels = $meta->get_labels } if $meta;
    my $col = @labels ? $labels[0] : 'name';
    my $links = eval { $meta->get_column( $col )->links_to } if $meta;
    if ( $links && $links =~ /^[A-Za-z_][A-Za-z0-9_]*$/ ) {
        my $reltab = $links->table;
        my @lbl;  @lbl = eval { $links->meta_data->get_labels };
        my $relcol = ( grep { /^[A-Za-z_][A-Za-z0-9_]*$/ } @lbl )[0] // 'id';
        return ( "o.$relcol", "LEFT JOIN $reltab o ON $alias.$col = o.id" );
    }
    return ( "$alias.$col", '' );
}

# Brief-view columns of a class (falls back to the all view), ordered, with
# user-friendly tags; excludes id and sensitive columns.
sub _brief_columns {
    my ($class) = @_;
    my $meta = eval { $class->meta_data };
    return [] unless $meta;
    my %order;
    eval { %order = $meta->get_column_order( view => 'brief' ) };
    unless (%order) {
        eval { %order = $meta->get_column_order( view => 'all' ) };
    }
    my @cols = sort { $order{$a} <=> $order{$b} } keys %order;
    @cols = grep { $_ ne 'id' } @cols;
    @cols = grep { !Netdot::Mojo::Registry::is_sensitive($_) } @cols;
    return [ map { [ $_, Netdot::Mojo::Registry::column_tag( $class, $_ ) ] } @cols ];
}

# Columns to display for a has_many relation. Returns ( $cols, $show_label ).
# Normally the object's get_label is shown as a leading column (linked to its
# detail page) and the label columns are dropped from $cols to avoid duplication
# ($show_label = 1). But a CONNECTOR / join table has only its FK columns, which
# ARE the label: there we keep the FK columns (rendered as clickable cells) and
# drop the combined label column ($show_label = 0).
sub rel_columns {
    my ($related) = @_;
    my $bcols = _brief_columns($related);
    my @labels;
    eval { @labels = $related->meta_data->get_labels };
    my %labelcols = map { $_ => 1 } @labels;
    my $rest = [ grep { !$labelcols{ $_->[0] } } @$bcols ];
    return ( $rest, 1 ) if @$rest;
    return ( $bcols, 0 );
}

# Display text for a related (FK) object. IP blocks are shown as a CIDR
# (e.g. 10.0.0.0/24 via ->cidr) instead of the generic get_label.
sub obj_text {
    my ($v) = @_;
    return '' unless ref $v;
    my $cidr = eval { $v->cidr };
    return $cidr if defined $cidr && length $cidr;
    my ($t) = @{ Netdot::Mojo::Registry::link_for($v) };
    return $t // '';
}

# Numeric-aware comparator (both numeric -> <=>, else case-insensitive text),
# mirroring the list pages and the client-side tablesort.js.
sub _kcmp {
    my ( $x, $y ) = @_;
    $x = '' unless defined $x;
    $y = '' unless defined $y;
    if ( $x =~ /^-?\d+(?:\.\d+)?$/ && $y =~ /^-?\d+(?:\.\d+)?$/ ) { return $x <=> $y; }
    return lc( $x ) cmp lc( $y );
}

1;
