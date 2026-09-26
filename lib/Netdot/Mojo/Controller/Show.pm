package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;

# Read-only detail page for one object: every non-empty, non-sensitive attribute.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->rendered(404);
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->rendered(404);

    my $obj = eval { $class->retrieve($id) };
    return $c->rendered(404) unless $obj;

    my @attrs;
    for my $col ( $class->columns ) {
        next if $col eq 'id';
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        next if $@;
        next unless defined $v;
        my $val = Netdot::Mojo::Registry::format_value($v);
        next if $val eq '';
        push @attrs, [ $col, $val ];
    }

    $c->render(
        template => 'management/detail',
        layout   => 'default',
        title    => ucfirst($type) . " #$id",
        type     => $type,
        id       => $id,
        attrs    => \@attrs,
    );
}

1;
