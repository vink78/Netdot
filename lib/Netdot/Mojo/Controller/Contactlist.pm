package Netdot::Mojo::Controller::Contactlist;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Detail page for a Contact List (port of generic/contactlist.html, read-only).
# The "contacts" has_many is rendered as a dedicated section (one row per role:
# the linked Person + contact type + notify/escalation fields), sorted by the
# person's label. All other has_many relations are shown as generic tables.
# Write actions ([new]/[edit]/[delete]) are omitted (edit interface not migrated).

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Contactlist - Contact List detail page (port of generic/contactlist.html)

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/management/contactlist/:id')->to('contactlist#show', type => 'contactlist')

=head1 INSTANCE METHODS

=cut

=head2 show - Contact List detail page

Arguments:  Controller (params: id, offset)
Returns:    Renders the management/contactlist template
Description: Port of generic/contactlist.html. Shows the contact list
            attributes (meta "all" view), the in-place edit form (written
            via PATCH /api/contactlist/<id>) and the contact roles (linked
            Person + contact type + notify/escalation fields, sorted by the
            person's label) as a dedicated section. Every other has_many
            relation is rendered as a generic table (read-only).

=cut

sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { ContactList->retrieve($id) };
    return $c->reply->not_found unless $o;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $perpage = eval { $o->config->get('DEFAULT_PERPAGE') };
    $perpage = 50 unless $perpage && $perpage > 0;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    my $attrs = Netdot::Mojo::Detail::build_attrs( $o, 'ContactList' );
    # In-place edit form (same as the generic detail): scalar + FK fields, written
    # via the JSON API (PATCH) — no server-side form handler.
    my $can_edit = $c->perm( 'edit', $o );
    my $fields   = $can_edit ? Netdot::Mojo::Detail::build_edit_fields( $o, 'ContactList' ) : [];
    my $api_path = $can_edit ? $c->web_prefix . '/api/contactlist/' . $id : '';
    my $contacts = _contacts( $o );

    # Generic has_many tables, minus the specially-rendered `contacts` relation.
    my $relations = Netdot::Mojo::Detail::build_relations( $o, $perpage, $offset );
    $relations = [ grep { $_->{csv_rel} ne 'contacts' } @$relations ];

    $c->render(
        template  => 'management/contactlist',
        layout    => 'default',
        title     => 'Contact List ' . ( $o->get_label // $id ),
        type      => 'contactlist',
        id        => $id,
        attrs     => $attrs,
        can_edit  => $can_edit,
        fields    => $fields,
        api_path  => $api_path,
        contacts  => $contacts,
        relations => $relations,
    );
}

# Contact roles of this list, sorted by the person's label. Each row: the linked
# Person plus the role's contact type and notify/escalation fields.
sub _contacts {
    my ($o) = @_;
    my @roles = eval { $o->contacts };
    @roles = sort { _p_label($a) cmp _p_label($b) } @roles;

    my @rows;
    for my $r (@roles) {
        my $person   = eval { $r->person };
        my $plabel   = eval { $person->get_label } // '';
        my $phref    = $person ? Netdot::Mojo::Registry::set_uri( '/management/person/' . $person->id ) : '';
        my $ct       = eval { $r->contacttype };
        push @rows, {
            person           => [ $plabel, $phref ],
            contacttype      => eval { $ct->name } // '',
            notify_email     => _str( $r, 'notify_email' ),
            notify_pager     => _str( $r, 'notify_pager' ),
            notify_voice     => _str( $r, 'notify_voice' ),
            escalation_level => _str( $r, 'escalation_level' ),
        };
    }
    return \@rows;
}

sub _p_label {
    my ($r) = @_;
    my $p = eval { $r->person };
    return eval { $p->get_label } // '';
}

sub _str {
    my ($o, $col) = @_;
    my $v = eval { $o->$col };
    return ( defined $v ? $v : '' );
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