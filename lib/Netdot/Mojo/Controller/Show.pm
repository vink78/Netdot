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
    );
}

1;
