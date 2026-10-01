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
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        $text = '' unless defined $text;
        push @attrs, [ $tag, $text, $href ];
    }
    return \@attrs;
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

        my @objs;
        eval { @objs = $obj->$rel };
        next unless @objs;

        my ( $cols, $show_label ) = rel_columns($related);
        my $total = scalar @objs;
        my $first = $offset;
        my $last  = $offset + $per - 1;
        $last  = $#objs if $last > $#objs;
        $first = 0 if $first > $#objs;
        my @page = ( $first <= $last ) ? @objs[ $first .. $last ] : ();

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
                    push @cells, [ Netdot::Mojo::Registry::format_value($v) // '', '' ];
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

1;
