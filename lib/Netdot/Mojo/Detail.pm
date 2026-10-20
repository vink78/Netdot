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
use Netdot::Mojo::Permissions;

# Attributes table: every non-sensitive column of the class's "all" view, in
# meta order, with user-friendly tags. FK values become links when the target
# type has a route (Registry::link_for).

=encoding utf8

=head1 NAME

Netdot::Mojo::Detail - Shared builders for read-only object detail pages

    Used by the generic Controller::Show and by the dedicated controllers
    (Zone, Contactlist, Closet, ...) so that the "attributes" table, the
    in-place edit forms and the "has_many relations" tables are built
    identically everywhere.

=head1 SYNOPSIS

    use Netdot::Mojo::Detail;

    my $attrs     = Netdot::Mojo::Detail::build_attrs( $obj, 'Zone' );
    my $relations = Netdot::Mojo::Detail::build_relations( $obj, $per, $off );

=head1 CLASS METHODS

=cut

=head2 build_attrs - Attributes table of a detail page

Arguments:  object, class (name or object)
Returns:    [ [tag, text, href], ... ]: every non-sensitive column of the
            class's "all" view, in meta order, with user-friendly tags. FK
            values become links when the target type has a route
            (Registry::link_for); boolean columns render as Yes/No.

=cut

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
=head2 build_edit_fields - Editable field specs of an object

Arguments:  object, class (name or object)
Returns:    [ {name, tag, kind, ...}, ... ] for the in-place edit form: the
            class's "all"-view columns that are non-sensitive. Scalar columns
            carry {name, tag, kind (text|number|textarea|checkbox|date),
            value}; FK columns carry {name, tag, kind=>'fk', target, max,
            cur_id, cur_label, options} — options are the full {id,label}
            list for a small target table (count <= DEFAULT_SELECTMAX),
            undef for a large one (the form renders a keyword search box that
            queries the API instead of dumping a dropdown). FK targets that
            are not a registered type, and system-managed timestamps, are
            skipped (they stay read-only in the attributes table).

=cut

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

# Editable field specs for a class (class-level, no per-object values): the
# same columns build_edit_fields offers, i.e. the class's "all"-view columns
# minus id / sensitive / system timestamps. Each entry: {name, tag, kind} plus,
# for a small FK target, the {id,label} options (a large target -> undef, so the
# client renders a keyword search instead of a dropdown). This is the single
# source of truth for what the bulk-edit UI offers AND what POST /api/<table>/
# batch accepts (Api.pm batch_edit derives its allowed-field set from here).
=head2 editable_field_specs - Class-level editable field specs

Arguments:  class (name or object)
Returns:    [ {name, tag, kind, ...}, ... ]: the same columns
            build_edit_fields offers (no per-object values) — the class's
            "all"-view columns minus id / sensitive / system timestamps.
            Single source of truth for what the bulk-edit UI offers AND what
            POST /api/<table>/batch accepts (the batch API derives its
            allowed-field set from here).

=cut

sub editable_field_specs {
    my ($class) = @_;
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
            my $options = _fk_options( $tclass, $maxselect );
            my %spec    = ( name => $col, tag => $tag, kind => 'fk', target => $target, max => $maxselect );
            $spec{options} = $options if $options;
            push @fields, \%spec;
            next;
        }

        my $type = Netdot::Mojo::Registry::column_type( $class, $col );
        next if defined $type && $type eq 'timestamp';
        my $kind =
            ( $type eq 'bool' )    ? 'checkbox'
          : ( $type eq 'integer' ) ? 'number'
          : ( $type eq 'text' )    ? 'textarea'
          : ( $type eq 'date' )    ? 'date'
          :                          'text';
        push @fields, { name => $col, tag => $tag, kind => $kind };
    }
    return \@fields;
}

# Current value of one editable field on an object, normalized for the
# bulk-edit table and the batch API: FK -> the target id (0 when unset — the
# relationship stringifies to its id under CDBI), bool -> 0/1, the rest raw.
=head2 bulk_edit_value - Current value of one editable field, normalized

Arguments:  field spec ({name, kind, ...}), object
Returns:    The value normalized for the bulk-edit table and the batch API:
            FK -> the target id (0 when unset), checkbox -> 0/1, date -> ''
            for the zero-date sentinel, everything else raw

=cut

sub bulk_edit_value {
    my ( $f, $o ) = @_;
    my $col = $f->{name};
    my $val = eval { $o->$col };
    $val = '' unless defined $val;
    if ( $f->{kind} eq 'fk' ) {
        # The relationship stringifies to its target id (CDBI); unset -> 0.
        my $fid = eval { int( $val ) };
        $fid = 0 unless defined $fid && $fid > 0;
        return $fid;
    }
    $val = '' if $f->{kind} eq 'date' && $val =~ /^0000-00-00/;    # zero-date sentinel = empty
    return $f->{kind} eq 'checkbox' ? ( $val ? 1 : 0 ) : $val;
}

# HTML for one editable cell of the dedicated bulk-edit table (the port of the
# legacy edit-multiple.html stage 2, rendered server-side): the field's input
# pre-filled with the object's current value ($val), tagged with $attr so the
# client can tell row cells (data-nd-f) from the "apply to all" row's cells
# (data-nd-apply). FKs render like the detail edit form (_edit_form.html.ep):
# a <select> of all options for a small target, or a keyword search box +
# <select> for a large one (.nd-fk-search, wired by initFkSearch) —
# $cur_label is the label of the current FK value, pre-filling that select.
=head2 bulk_edit_cell_html - HTML for one editable cell of the bulk-edit table

Arguments:  field spec ({name, kind, options, ...}), value, cur_label (label
            of the current FK value), attr (tag attribute: data-nd-f for row
            cells, data-nd-apply for the "apply to all" row)
Returns:    The field's input pre-filled with the value: a checkbox, a
            <select> (small FK target) or a keyword search box + <select>
            (large FK target, wired by initFkSearch), a textarea, or a text
            input (number / date / text)
Description: Port of the legacy edit-multiple.html stage 2, rendered
            server-side.

=cut

sub bulk_edit_cell_html {
    my ( $f, $val, $cur_label, $attr ) = @_;
    $attr = 'data-nd-f' unless $attr;
    $val  = ( defined $val ) ? $val : '';
    my ( $n, $e ) = ( $f->{name}, sub { Netdot::Mojo::Registry::esc( $_[0] // '' ) } );
    if ( $f->{kind} eq 'checkbox' ) {
        return '<input type="checkbox" ' . $attr . '="' . $n . '"' . ( $val ? ' checked' : '' ) . '>';
    }
    if ( $f->{kind} eq 'fk' ) {
        my $cur = eval { int( $val ) };
        $cur = 0 unless defined $cur && $cur > 0;
        if ( $f->{options} ) {
            my $h = '<select class="nd-fk-select" ' . $attr . '="' . $n . '">'
                  . '<option value="">' . "\x{2014}" . '</option>';
            for my $op ( @{ $f->{options} } ) {
                $h .= '<option value="' . $op->{id} . '"' . ( $cur && $cur == $op->{id} ? ' selected' : '' )
                    . '>' . $e->( $op->{label} ) . '</option>';
            }
            return $h . '</select>';
        }
        my $h = '<span class="nd-fk-search">'
              . '<input type="text" class="nd-fk-kw" placeholder="Search' . "\x{2026}" . '" data-nd-target="' . $f->{target}
              . '" data-nd-max="' . ( $f->{max} // 100 ) . '">'
              . '<button type="button" class="btn nd-fk-go">List</button>'
              . '<select class="nd-fk-select" ' . $attr . '="' . $n . '">'
              . '<option value="">' . "\x{2014}" . '</option>';
        $h .= '<option value="' . $cur . '" selected>' . $e->( $cur_label // $cur ) . '</option>' if $cur;
        return $h . '</select></span>';
    }
    if ( $f->{kind} eq 'textarea' ) {
        return '<textarea ' . $attr . '="' . $n . '" rows="2">' . $e->( $val ) . '</textarea>';
    }
    if ( $f->{kind} eq 'number' ) {
        return '<input type="text" data-nd-int ' . $attr . '="' . $n . '" value="' . $e->( $val ) . '">';
    }
    if ( $f->{kind} eq 'date' ) {
        return '<input type="date" ' . $attr . '="' . $n . '" value="' . $e->( $val ) . '">';
    }
    return '<input type="text" ' . $attr . '="' . $n . '" value="' . $e->( $val ) . '">';
}

# Label for an FK option: the object's get_label (falls back to "#id").
sub _fk_label {
    my ($o) = @_;
    my $l = eval { $o->get_label };
    return ( defined $l && length $l ) ? $l : '#' . ( eval { $o->id } // '' );
}

# <select> options for an FK column's target table: all {id,label} when the
# target is small (count <= DEFAULT_SELECTMAX); undef when large (the form then
# renders a keyword search box that queries the API — the dropdown is never
# dumped). Shared by the edit and create field builders.
sub _fk_options {
    my ( $tclass, $maxselect ) = @_;
    my $count = eval { $tclass->count_all } // 0;
    return undef unless $count <= $maxselect;
    my @all = eval { $tclass->retrieve_all };    # list context (no "||" — it scalarizes)
    @all    = sort { _fk_label( $a ) cmp _fk_label( $b ) } @all;
    return [ map { { id => $_->id, label => _fk_label( $_ ) } } @all ];
}

# Field specs for a NEW object of $class (the generic list page's "New <type>"
# create box): same shape as build_edit_fields but every value blank (FKs
# unselected, scalars empty). Uses the class's BRIEF-view columns (the key
# fields only) to keep the UI light; the model's insert() validates the
# required fields (a missing one -> 400 with the model's own message) and fills
# the rest with defaults. Timestamps are excluded (system-managed).
=head2 build_create_fields - Field specs for a NEW object

Arguments:  class (name or object)
Returns:    [ {name, tag, kind, ...}, ... ] (the generic list page's "New
            <type>" create box): same shape as build_edit_fields but every
            value blank (FKs unselected, scalars empty). Uses the class's
            BRIEF-view columns (the key fields only) to keep the UI light;
            the model's insert() validates the required fields (a missing
            one -> 400 with the model's own message) and fills the rest with
            defaults.

=cut

sub build_create_fields {
    my ( $class ) = @_;
    my @fields;
    my $maxselect = eval { Netdot->config->get('DEFAULT_SELECTMAX') } || 100;
    for my $cd ( @{ Netdot::Mojo::Registry::display_brief_columns( $class ) } ) {
        my ( $col, $tag ) = @$cd;
        next if Netdot::Mojo::Registry::is_sensitive( $col );

        my $target = Netdot::Mojo::Registry::column_link_key( $class, $col );
        if ($target) {
            my $tspec  = Netdot::Mojo::Registry::spec( $target );
            my $tclass = $tspec ? $tspec->{class} : undef;
            next unless $tclass;
            push @fields, {
                name      => $col,
                tag       => $tag,
                kind      => 'fk',
                target    => $target,
                max       => $maxselect,
                cur_id    => 0,
                cur_label => '',
                options   => _fk_options( $tclass, $maxselect ),
            };
            next;
        }

        my $type = Netdot::Mojo::Registry::column_type( $class, $col );
        next if defined $type && $type eq 'timestamp';
        my $kind =
            ( $type eq 'bool' )    ? 'checkbox'
          : ( $type eq 'integer' ) ? 'number'
          : ( $type eq 'text' )    ? 'textarea'
          : ( $type eq 'date' )    ? 'date'
          :                          'text';
        push @fields, {
            name  => $col,
            tag   => $tag,
            kind  => $kind,
            value => ( $kind eq 'checkbox' ? 0 : '' ),
        };
    }
    return \@fields;
}

# Generic "Add" specs for the has_many relations of the generic detail page —
# the port of the legacy view.html [add] links (one per section:
# edit.html?table=<child>&<fk>=<parent>): the child's create fields (brief
# view, same shape as build_create_fields) with the parent FK pre-filled as a
# hidden field. detail.html.ep renders each spec through the shared _edit_form
# partial (create mode) which POSTs to /api/<table>; initForms (netdot.js)
# handles the submit and reloads the page on success.
=head2 relation_adds - Create-field specs for the relation "Add" forms

Arguments:  object, person (the logged-in Netdot::Model::Person)
Returns:    [ {rel, related, table, fields}, ... ] sorted by relation name:
            one spec per relation that can be added to
Description: Skipped: relations with more than one FK column; child classes
            never offered as in-page adds (Circuit / HorizontalCable /
            BackboneCable - deprecated, moved to Netbox; DhcpScopeUse - scope
            templates, template_edit descoped; picture classes - binary
            uploads need a file form); and classes the person may not create
            (class-level 'edit', same gate as the list "New <type>" boxes -
            the API re-enforces it at write time via _can_create).

=cut

sub relation_adds {
    my ( $obj, $person ) = @_;

    my %linksfrom;
    eval { %linksfrom = ref($obj)->meta_data->get_links_from };

    # Child classes never offered as in-page adds (see the description above).
    my %noadd = map { $_ => 1 } qw(
        Circuit HorizontalCable BackboneCable
        DhcpScopeUse
        SitePicture FloorPicture
    );

    my @adds;
    for my $rel ( sort keys %linksfrom ) {
        my $rtables = $linksfrom{$rel};
        next unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        next unless $related && length $related;
        my $fk = $rtables->{$related};
        next unless defined $fk && !ref $fk && length $fk;    # single FK column
        next if $noadd{$related};

        my $tclass = "Netdot::Model::$related";
        my $ttable = eval { $tclass->table };
        next unless $ttable;
        next unless Netdot::Mojo::Permissions->has_action( $tclass, $person, 'edit' );

        my @fields = @{ build_create_fields($tclass) };
        # The parent FK is fixed to this object: a hidden pre-filled field.
        # Replace the column when the brief view lists it, otherwise prepend it.
        my $seen;
        for my $f (@fields) {
            if ( $f->{name} eq $fk ) {
                $f = { name => $fk, tag => $f->{tag}, kind => 'hidden', value => $obj->id };
                $seen = 1;
            }
        }
        unshift @fields, { name => $fk, tag => ucfirst($related), kind => 'hidden',
                           value => $obj->id }
            unless $seen;
        push @adds, { rel     => $rel,
                      related => $related,
                      table   => $ttable,
                      fields  => \@fields };
    }
    return \@adds;
}

# has_many relations (like the old Mason view.html "View" section): one table
# per non-empty relation. Columns from _rel_columns (brief view; for join /
# connector tables whose label IS the FK set the FK columns are shown as
# clickable cells). Rows paginated via $offset; $per is the page size.
=head2 build_relations - has_many relation tables of a detail page

Arguments:  object, perpage, offset
Returns:    [ {title, cols, rows, total, per, offset, start, last_item,
            csv_rel}, ... ]: one table per non-empty relation (like the old
            Mason view.html "View" section). Rows are fetched ordered +
            paginated in SQL (see relation_objects); columns come from the
            related class's brief view; the leading label column links to
            the related object's detail page (FK columns link to their
            target).

=cut

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
=head2 relation_objects - Ordered, paginated objects of one relation

Arguments:  object, relation name, perpage (undef/0 = no LIMIT, all rows —
            used for the CSV export), offset
Returns:    ( \@objs, $total ): the current page of target objects and the
            full count
Description: Looks up the relation's target class + FK column (meta
            get_links_from) and delegates to the SQL fetch: ORDER BY matches
            the on-screen first column (Ipblock orders by the exact integer
            address so IPv4 comes before IPv6; a relationship first column
            is ordered via a LEFT JOIN on the related label).

=cut

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
=head2 rel_columns - Columns to display for a has_many relation

Arguments:  related class name
Returns:    ( $cols, $show_label ): normally the brief-view columns (minus
            the label columns, which the leading get_label column already
            covers — $show_label = 1). A CONNECTOR / join table has only FK
            columns, which ARE the label: there the FK columns are kept
            (rendered as clickable cells) and the combined label column is
            dropped ($show_label = 0).

=cut

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
=head2 obj_text - Display text for a related (FK) object

Arguments:  object (undef is fine)
Returns:    The display text: IP blocks are shown as a CIDR (e.g.
            10.0.0.0/24 via ->cidr) instead of the generic get_label;
            everything else uses its link text (label, or "type #id")

=cut

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