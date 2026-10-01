package Netdot::Mojo::Controller::Advanced;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;

# Changelog: audit records with search (label LIKE) + operation filter + pagination.
sub changelog {
    my $c      = shift;
    my $per    = eval { Netdot::Model->config->get('DEFAULT_PERPAGE') } || 50;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    my $search    = $c->param('search') // '';
    $search =~ s/^\s+|\s+$//g;
    my $operation = $c->param('operation') // '';
    $operation = '' unless $operation =~ /^(insert|update|delete)$/;

    # WHERE clause (same pattern as Browse#list).
    my @where;
    my @binds;
    if ( length $search ) {
        push @where, 'label LIKE ?';
        push @binds, "%$search%";
    }
    if ( length $operation ) {
        push @where, 'operation = ?';
        push @binds, $operation;
    }
    my $wc = @where ? ' WHERE ' . join ' AND ', @where : '';

    my $dbh   = Audit->db_Main;
    my $total = 0;
    eval {
        ( $total ) = $dbh->selectrow_array( "SELECT COUNT(*) FROM audit $wc", undef, @binds );
    };
    $total = 0 unless $total;

    my @rows;
    eval {
        my $sth = $dbh->prepare(
            "SELECT tstamp, username, tablename, label, operation, fields, vals
             FROM audit $wc ORDER BY tstamp DESC LIMIT ? OFFSET ?"
        );
        $sth->execute( @binds, $per, $offset );
        while ( my $r = $sth->fetchrow_hashref ) {
            push @rows, $r;
        }
    };

    my $start     = @rows ? $offset + 1 : 0;
    my $last_item = $offset + scalar @rows;

    $c->render(
        template  => 'advanced/changelog',
        layout    => 'default',
        title     => 'Changelog',
        rows      => \@rows,
        total     => $total,
        per       => $per,
        offset    => $offset,
        start     => $start,
        last_item => $last_item,
        search    => $search,
        operation => $operation,
    );
}

1;
