package Netdot::Mojo::Controller::Zone;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Detail page for a DNS zone (port of zone.html, read-only). Beyond the plain
# attributes + has_many tables, the original shows a record-type count summary,
# the apex (@) record's A/NS/MX entries, and the zone's recent DNS/DHCP change
# history (HostAudit). Write actions ([add]/[edit]/[import]) are omitted (edit
# interface not yet migrated).
sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Zone->retrieve($id) };
    return $c->reply->not_found unless $o;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $perpage = eval { $o->config->get('DEFAULT_PERPAGE') };
    $perpage = 50 unless $perpage && $perpage > 0;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    my $attrs = Netdot::Mojo::Detail::build_attrs( $o, 'Zone' );
    # In-place edit form (same as the generic detail): scalar + FK fields, written
    # via the JSON API (PATCH) — no server-side form handler.
    my $can_edit = $c->perm( 'edit', $o );
    my $fields   = $can_edit ? Netdot::Mojo::Detail::build_edit_fields( $o, 'Zone' ) : [];
    my $api_path = $can_edit ? $c->web_prefix . '/api/zone/' . $id : '';
    my $count = _record_count( $o );
    my $apex  = _apex_records( $o, $id );
    my $relations = Netdot::Mojo::Detail::build_relations( $o, $perpage, $offset );
    my $recent  = _recent_changes( $o );

    $c->render(
        template    => 'management/zone',
        layout      => 'default',
        title       => 'Zone ' . ( $o->name // $id ),
        type        => 'zone',
        id          => $id,
        attrs       => $attrs,
        can_edit    => $can_edit,
        fields      => $fields,
        api_path    => $api_path,
        count       => $count,
        apex        => $apex,
        relations   => $relations,
        recent      => $recent,
        recent_total => scalar @$recent,
    );
}

# Record-type summary: { total => N, rows => [ [TYPE, count], ... ] }.
sub _record_count {
    my ($o) = @_;
    my $count = eval { $o->get_record_count };
    $count = {} unless ref $count eq 'HASH';
    my $total = 0;
    my @rows;
    for my $rtype ( sort keys %$count ) {
        my $n = $count->{$rtype} // 0;
        $total += $n;
        push @rows, [ uc($rtype), $n ];
    }
    return { total => $total, rows => \@rows };
}

# The zone's apex (@) record and its A / NS / MX entries, as [text, href] pairs.
# Returns undef when the zone has no apex record.
sub _apex_records {
    my ($o, $id) = @_;
    my $at = eval { RR->search( name => '@', zone => $id )->first };
    return undef unless $at;

    my ( @a, @ns, @mx );
    for my $r ( eval { $at->a_records } ) {
        my $ip = eval { $r->ipblock };
        push @a, [ ( $ip ? ( $ip->address // '' ) : '' ), $ip ? Netdot::Mojo::Registry::set_uri( '/management/ipblock/' . $ip->id ) : '' ];
    }
    for my $r ( eval { $at->ns_records } ) {
        push @ns, [ ( eval { $r->nsdname } // '' ), '' ];
    }
    for my $r ( eval { $at->mx_records } ) {
        my $exch = eval { $r->exchange } // '';
        my $pref = eval { $r->preference };
        push @mx, [ $exch . ( defined $pref ? " ($pref)" : '' ), '' ];
    }
    return {
        id   => $at->id,
        a    => \@a,
        ns   => \@ns,
        mx   => \@mx,
    };
}

# Recent DNS/DHCP change history for this zone (HostAudit, most recent first,
# capped at 50). Rows: [ tstamp, pending, scope_html ].
sub _recent_changes {
    my ($o) = @_;
    my @rows;
    eval {
        my $it = HostAudit->search_where(
            { zone => $o->name },
            { order_by => 'tstamp DESC', limit_dialect => 'LimitXY', limit => 50 },
        );
        while ( my $r = $it->next ) {
            my $tstamp = eval { $r->tstamp } // '';
            my $pend   = eval { $r->pending } ? 'yes' : 'no';
            my $scope  = eval { $r->scope };
            my $scope_html;
            if ( ref $scope ) {
                my ( $t, $h ) = @{ Netdot::Mojo::Registry::link_for($scope) };
                $scope_html = $h ? '<a href="' . $h . '">' . Netdot::Mojo::Registry::esc($t // '') . '</a>'
                                 : Netdot::Mojo::Registry::esc( $t // '' );
            }
            push @rows, [ $tstamp, $pend, $scope_html // '' ];
        }
    };
    return \@rows;
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