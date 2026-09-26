package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;

# BOUNDED list of ipblocks, reusing the Netdot model (out of Apache).
# NB: the ipblock table is large (hundreds of thousands) -> SQL LIMIT,
# then retrieve by id to get inflated objects (address = readable IP).
sub ipblock_list ($c) {
    my $limit = 50;

    my $dbh   = Netdot::Model->db_Main;
    my ($total) = $dbh->selectrow_array("SELECT COUNT(*) FROM ipblock");

    my $sth  = $dbh->prepare("SELECT id FROM ipblock LIMIT ?");
    $sth->execute($limit);
    my @objs = map { Ipblock->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };

    $c->render(
        template => 'management/ipblock_list',
        layout   => 'default',
        title    => 'Ipblocks',
        ipblocks => \@objs,
        total    => $total,
        limit    => $limit,
    );
}

# BOUNDED list of devices (LIMIT query + retrieve by id, inflated objects).
sub device_list ($c) {
    my $limit = 50;

    my $dbh   = Netdot::Model->db_Main;
    my ($total) = $dbh->selectrow_array("SELECT COUNT(*) FROM device");

    my $sth  = $dbh->prepare("SELECT id FROM device LIMIT ?");
    $sth->execute($limit);
    my @objs = map { Device->retrieve( $_->[0] ) } @{ $sth->fetchall_arrayref };

    $c->render(
        template => 'management/device',
        layout   => 'default',
        title    => 'Devices',
        devices  => \@objs,
        total    => $total,
        limit    => $limit,
    );
}

1;
