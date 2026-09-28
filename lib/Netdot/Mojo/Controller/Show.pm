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

    # has_many relations (like the old Mason view.html "View" section): for each
    # relation declared in netdot.meta links_to { method => ... }, show a table of
    # the related objects. Brief columns; first column = the object's label linked
    # to its own detail page. Row count capped at DEFAULT_PERPAGE.
    my %linksfrom;
    eval { %linksfrom = $class->meta_data->get_links_from };
    my $perpage   = eval { $obj->config->get('DEFAULT_PERPAGE') };
    $perpage = 50 unless $perpage && $perpage > 0;
    my @relations;
    for my $rel ( sort keys %linksfrom ) {
        my $rtables = $linksfrom{$rel};
        next unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        next unless $related && length $related;

        my @objs;
        eval { @objs = $obj->$rel };
        next unless @objs;

        my $bcols = _brief_columns($related);
        # Drop brief columns already shown by the object label (1st column).
        my @labels;
        eval { @labels = $related->meta_data->get_labels };
        my %labelcols = map { $_ => 1 } @labels;
        $bcols = [ grep { !$labelcols{ $_->[0] } } @$bcols ];
        my $max   = $perpage - 1;
        $max      = $#objs if $max > $#objs;
        my @rows;
        for my $o2 ( @objs[ 0 .. $max ] ) {
            my ( $lt, $lh ) = @{ Netdot::Mojo::Registry::link_for($o2) };
            my @cells;
            push @cells, [ $lt // ( '#' . ( eval { $o2->id } // '' ) ), $lh // '' ];
            for my $cd ( @$bcols ) {
                my ( $col ) = @$cd;
                my $v = eval { $o2->$col };
                $v = undef if $@;
                if ( ref $v ) {
                    my ( $ct, $ch ) = @{ Netdot::Mojo::Registry::link_for($v) };
                    push @cells, [ $ct // '', $ch // '' ];
                } else {
                    push @cells, [ Netdot::Mojo::Registry::format_value($v) // '', '' ];
                }
            }
            push @rows, \@cells;
        }
        push @relations, {
            title => sprintf( '%s (%d)', $rel, scalar @objs ),
            cols  => [ ucfirst($related), map { $_->[1] } @$bcols ],
            rows  => \@rows,
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

1;
