package Netdot::Mojo::Controller::Advanced;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use Netdot::Mojo::Permissions;

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Advanced - Changelog page (audit records)

    Port of the legacy changelog view: searchable (label LIKE), operation-
    filtered, paginated list of the audit table. Admin/Operator see every
    entry, any other user only their own.

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/changelog')->to('advanced#changelog');

=head1 INSTANCE METHODS

=cut

=head2 changelog - Changelog page: audit records with search + pagination

Arguments:  query params: C<< search >> (matched with label LIKE),
            C<< operation >> (insert|update|delete, anything else ignored),
            C<< offset >> (pagination offset)
Returns:    Renders the advanced/changelog template (rows, total, perpage,
            search/operation state for the pagination links)
Description: Admin/Operator see every audit entry; any other user sees only
            their own (audit.username = session username). Rows come from a
            raw SQL COUNT + SELECT ... ORDER BY tstamp DESC LIMIT/OFFSET on
            the audit table.

=cut

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

    # Changelog is an admin feature: Admin/Operator see every entry; any other
    # user sees only their own (audit.username == their username).
    my $person = $c->current_person;
    my $type   = Netdot::Mojo::Permissions->user_type( $person );
    if ( $type ne 'Admin' && $type ne 'Operator' ) {
        my $u = ( defined $person && ref $person ) ? eval { $person->username } : undef;
        if ( defined $u && length $u ) {
            push @where, 'username = ?';
            push @binds, $u;
        }
        else {
            push @where, '1 = 0';    # cannot determine user -> show nothing
        }
    }

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

=head1 AUTHOR

Vincent Magnin, C<< <Vincent.Magnin at unil.ch> >>

This code was written with the assistance of the Qwen 3.8-27b large
language model.

=head1 COPYRIGHT & LICENSE

Copyright 2026 University of Lausanne, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

# Make sure to return 1
1;