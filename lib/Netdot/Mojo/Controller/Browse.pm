package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;

# Liste BORNEE des ipblocks, reutilise le modele Netdot (hors Apache).
# NB : la table ipblock est grosse (centaines de milliers) -> LIMIT en SQL,
# puis retrieval par id pour obtenir des objets inflates (address = IP lisible).
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

1;
