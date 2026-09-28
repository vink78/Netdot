package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;

# Read-only detail page for a generic object: every non-empty, non-sensitive
# attribute, with FK values rendered as links when their type has a route.
# IP blocks have their own dedicated controller (Netdot::Mojo::Controller::Ipblock),
# the only browsable type with custom detail logic so far.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;

    # Display fields follow netdot.meta "views" { all } (order + user-friendly
    # tags). All listed fields are shown (empty ones blank), like view.html; FK
    # values become links when their type has a route.
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

    # has_many relations (like the old Mason view.html "View" section): one table
    # per non-empty relation. Columns from _rel_columns (brief view; for join
    # tables whose label IS the FK set the FK columns are shown as clickable
    # cells). Rows paginated via a shared `offset` param; `?csv=<rel>` exports a
    # relation as CSV.
    my %linksfrom;
    eval { %linksfrom = $class->meta_data->get_links_from };

    # CSV export of one relation: ?csv=<rel> (all rows, not just the current page)
    if ( my $csv_rel = $c->param('csv') ) {
        my $rtables = $linksfrom{$csv_rel};
        return $c->reply->not_found unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        return $c->reply->not_found unless $related;
        my @objs;
        eval { @objs = $obj->$csv_rel };
        my ( $cols, $show_label ) = _rel_columns($related);
        my @header = $show_label
            ? ( ucfirst($related), map { $_->[1] } @$cols )
            : ( map { $_->[1] } @$cols );
        my $csv = join( ',', map { Netdot::Mojo::Registry::csv_field($_) } @header ) . "\n";
        for my $o2 (@objs) {
            my @vals;
            if ($show_label) {
                my ($lt) = @{ Netdot::Mojo::Registry::link_for($o2) };
                push @vals, $lt // ( '#' . ( eval { $o2->id } // '' ) );
            }
            for my $cd ( @$cols ) {
                my $col = $cd->[0];
                my $v   = eval { $o2->$col };
                if ( ref $v ) { $v = _obj_text($v); }
                push @vals, ( defined $v ? $v : '' );
            }
            $csv .= join( ',', map { Netdot::Mojo::Registry::csv_field($_) } @vals ) . "\n";
        }
        $c->res->headers->content_type( 'text/csv' );
        $c->res->headers->content_disposition( 'attachment', filename => "$type-$csv_rel.csv" );
        return $c->render( data => $csv );
    }

    my $offset = int( $c->param('offset') // 0 );
    $offset     = 0 if $offset < 0;
    my $perpage = eval { $obj->config->get('DEFAULT_PERPAGE') };
    $perpage    = 50 unless $perpage && $perpage > 0;

    my @relations;
    for my $rel ( sort keys %linksfrom ) {
        my $rtables = $linksfrom{$rel};
        next unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        next unless $related && length $related;

        my @objs;
        eval { @objs = $obj->$rel };
        next unless @objs;

        my ( $cols, $show_label ) = _rel_columns($related);
        my $total = scalar @objs;
        my $first = $offset;
        my $last  = $offset + $perpage - 1;
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
                    $ct = _obj_text($v);
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
            per       => $perpage,
            offset    => $offset,
            start     => $total ? $offset + 1 : 0,
            last_item => $offset + scalar( @page ),
            csv_rel   => $rel,
        };
    }

    # Title: prefer the object's own label (built from netdot.meta "label" columns
    # by ->get_label), falling back to "Type #id" when the label is empty.
    my $label = eval { $obj->get_label } // '';
    $label = undef unless defined $label && length $label;

    $c->render(
        template => 'management/detail',
        layout   => 'default',
        title    => $label // ( ucfirst($type) . " #$id" ),
        type     => $type,
        id       => $id,
        attrs    => \@attrs,
        relations => \@relations,
    );
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
    return [ map {
        my $tag = eval { $meta->get_column( $_ )->tag };
        [ $_, ( defined $tag && length $tag ? $tag : $_ ) ];
    } @cols ];
}

# Columns to display for a has_many relation. Returns ( $cols, $show_label ).
# $cols = the brief-view columns (ordered, tagged). Normally the object's
# get_label is shown as a leading column (linked to its detail page) and the
# label columns are dropped from $cols to avoid duplication ($show_label = 1).
# But a CONNECTOR / join table (e.g. SiteSubnet) has only its FK columns, which
# ARE the label: dropping them would leave nothing. So in that case we keep the
# FK columns in $cols (rendered as clickable cells -> Ipblock, Site, ...) and
# drop the combined label column ($show_label = 0).
sub _rel_columns {
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
# (e.g. 10.0.0.0/24 via ->cidr) instead of the generic get_label (which would
# read "10.0.0.0, 24"); any other object falls back to its get_label.
sub _obj_text {
    my ($v) = @_;
    return '' unless ref $v;
    my $cidr = eval { $v->cidr };
    return $cidr if defined $cidr && length $cidr;
    my ($t) = @{ Netdot::Mojo::Registry::link_for($v) };
    return $t // '';
}

1;
