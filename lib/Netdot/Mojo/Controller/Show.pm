package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;

# Read-only detail page for one object: every non-empty, non-sensitive attribute.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    # ipblock: the detail shows the block + its children (hierarchy navigation).
    if ( $type eq 'ipblock' ) {
        my $o = eval { $class->retrieve( $id ) };
        return $c->reply->not_found unless $o;
        # ->children returns a Class::DBI::Iterator; iterate it (a bare list
        # assignment via eval() degrades to the iterator object itself).
        my @kids;
        my $it = eval { $o->children };
        if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
            while ( my $k = $it->next ) {
                push @kids, $k;
            }
        }
        # Direct list context (get_ancestors uses wantarray; eval{}//() degrades it).
        my @ancs = $o->get_ancestors;
        my @crumbs = ( { label => 'Roots', id => 0 } );
        push @crumbs, map { { label => $_->get_label, id => $_->id } } ( reverse @ancs );
        my $viewtype = @kids && eval { $kids[0]->is_address } ? 'address' : 'block';
        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => "Ipblock " . $o->get_label,
            viewtype   => $viewtype,
            blocks     => \@kids,
            current    => $o,
            breadcrumb => \@crumbs,
        );
        return;
    }

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;

    my @attrs;
    for my $col ( $class->columns ) {
        next if $col eq 'id';
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        next if $@;
        next unless defined $v;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        next if !defined $text || $text eq '';
        push @attrs, [ $col, $text, $href ];
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
