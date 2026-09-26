package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;

# BOUNDED list of one object type (SQL LIMIT + retrieve by id -> inflated objects).
# Reuses the Netdot model, out of Apache. Works for every type in Netdot::Mojo::Registry.
sub list ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->rendered(404);
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $limit = 50;

    my $table = $class->table;
    my $dbh   = Netdot::Model->db_Main;
    my ($total) = $dbh->selectrow_array("SELECT COUNT(*) FROM $table");

    my $sth = $dbh->prepare("SELECT id FROM $table LIMIT ?");
    $sth->execute($limit);
    my @objs = map { $class->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };

    # Build display rows: id (linked) + the type's display columns.
    my @rows;
    for my $obj (@objs) {
        my %row = ( id => $obj->id );
        for my $col (@$cols) {
            my $v = eval { $obj->$col };
            $row{$col} = $@ ? '' : Netdot::Mojo::Registry::format_value($v);
        }
        push @rows, \%row;
    }

    $c->render(
        template => 'management/list',
        layout   => 'default',
        title    => ucfirst($type),
        type     => $type,
        cols     => $cols,
        rows     => \@rows,
        total    => $total,
        limit    => $limit,
    );
}

1;
