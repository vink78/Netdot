package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Read-only detail page for a generic object: every non-empty, non-sensitive
# attribute, with FK values rendered as links when their type has a route.
# IP blocks have their own dedicated controller (Netdot::Mojo::Controller::Ipblock),
# the only browsable type with custom detail logic so far.

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Show - Generic detail page (registered types without a dedicated controller) + picture binaries

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/management/<type>/:id')->to('show#show', type => <type>)
    #   ->get('/management/sitepicture/:id')->to('show#picture', type => 'sitepicture')
    #   ->get('/management/floorpicture/:id')->to('show#picture', type => 'floorpicture')

=head1 INSTANCE METHODS

=cut

=head2 show - Generic detail page

Arguments:  Controller (stash: type; params: id, offset, csv)
Returns:    Renders the management/detail template, or a CSV download when
            ?csv=<rel> is given (one has_many relation, all rows)
Description: Read-only detail for any registered type: every attribute of
            the netdot.meta "all" view (FK values become links when their
            type has a route), the in-place edit form (written via
            PATCH /api/<table>/<id> where table is the DB table name) and
            the has_many relation tables (paginated via offset). Editors
            additionally get, in each addable relation's tab, an in-place
            "Add" form creating a child row via POST /api/<child table>
            (the port of the legacy view.html [add] links; see
            Detail::relation_adds) - the tab stays visible even for an
            empty relation so its first row can be created. On person
            pages, Admins additionally get a dedicated "Password" box (the
            sensitive password column is excluded from the generic edit
            form): it PATCHes the same endpoint with the new plaintext,
            which the model's trigger hashes.

=cut

sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;
    return if $c->deny_unless( 'view', $obj );    # per-object access (User: none by default)

    # Display fields follow netdot.meta "views" { all } (order + user-friendly
    # tags). All listed fields are shown (empty ones blank), like view.html; FK
    # values become links when their type has a route.
    my $attrs = Netdot::Mojo::Detail::build_attrs( $obj, $class );

    # Edit form (phase 2): editable scalar fields + the API endpoint the form
    # PATCHes to. Writes go through the JSON API (single path), not a server-side
    # form handler. FKs are excluded from the form (see Detail::build_edit_fields).
    # The API table is the DB table name ($class->table), NOT lc($type): the two
    # differ for DhcpScope (registry key "dhcscope" vs table "dhcpscope").
    my $table      = $class->table;
    my $can_edit   = $c->perm( 'edit', $obj );
    my $fields     = $can_edit ? Netdot::Mojo::Detail::build_edit_fields( $obj, $class ) : [];
    my $api_path   = $can_edit ? $c->web_prefix . '/api/' . $table . '/' . $id : '';
    # Page-level delete (same generic mechanism as the RR detail page): shown when
    # the user may delete this object; redirects to the list afterwards.
    my $can_delete = $c->perm( 'delete', $obj );
    my $del_path   = $can_delete ? $c->web_prefix . '/api/' . $table . '/' . $id : '';
    my $del_goto   = $can_delete ? Netdot::Mojo::Registry::set_uri( "/management/$type" ) : '';
    # Person pages only, Admins only: a dedicated "Password" box. The generic
    # edit form excludes the sensitive `password` column, so setting a password
    # has its own small form (netdot.js initSetPassword) that PATCHes the
    # person's API endpoint with {password: <plaintext>}; the model's
    # deflate trigger hashes it (Person::_encrypt_passwd).
    my $setpass_api = ( $type eq 'person' && $c->user_type eq 'Admin' )
        ? $c->web_prefix . '/api/' . $table . '/' . $id : '';
    # DhcpScope pages, editors only: an "Add attribute" form in the attributes
    # tab (wired by netdot.js initAttrAdd). It creates the dhcpattr row via
    # POST /api/dhcpattr with {name: <option name>, scope: <this id>, value};
    # the model resolves the option name to the dhcpattrname row. The name
    # select is the full DhcpAttrName list (small, static). Mirrors the legacy
    # scope.html [add] link on the attributes section
    # (edit.html?table=DhcpAttr&scope=<id>), gated on 'edit' of the scope.
    my $attr_names;
    if ( $type eq 'dhcscope' && $can_edit ) {
        my @names;
        my $ok = eval { @names = DhcpAttrName->retrieve_all; 1 };
        $attr_names = [ map { { id => $_->id, name => $_->name } } sort { $a->name cmp $b->name } @names ]
            if $ok && @names;
    }

    # has_many relations (like the old Mason view.html "View" section): one table
    # per non-empty relation. Columns from the related class's brief view. Rows
    # paginated via a shared `offset` param; `?csv=<rel>` exports a relation as
    # CSV.
    my %linksfrom;
    eval { %linksfrom = $class->meta_data->get_links_from };

    # CSV export of one relation: ?csv=<rel> (all rows, not just the current page)
    if ( my $csv_rel = $c->param('csv') ) {
        my $rtables = $linksfrom{$csv_rel};
        return $c->reply->not_found unless ref $rtables eq 'HASH';
        my ($related) = sort keys %$rtables;
        return $c->reply->not_found unless $related;
        # All rows, ordered the same way as the on-screen table (SQL ORDER BY).
        my ( $objs_ref ) = Netdot::Mojo::Detail::relation_objects( $obj, $csv_rel, 0, 0 );
        my @objs = @{ $objs_ref // [] };
        my ( $cols, $show_label ) = Netdot::Mojo::Detail::rel_columns($related);
        my @header = $show_label
            ? ( ucfirst($related), map { $_->[1] } @$cols )
            : ( map { $_->[1] } @$cols );
        my $csv = join( ',', map { Netdot::Mojo::Registry::csv_field($_) } @header ) . "\n";
        for my $o2 (@objs) {
            my @vals;
            if ($show_label) {
                my ($lt) = @{ Netdot::Mojo::Registry::link_for($o2) };
                push @vals, $lt // ( '#' . ( eval { $o2->id } // '' ) );
            }
            for my $cd ( @$cols ) {
                my $col = $cd->[0];
                my $v   = eval { $o2->$col };
                if ( ref $v ) { $v = Netdot::Mojo::Detail::obj_text($v); }
                push @vals, ( defined $v ? $v : '' );
            }
            $csv .= join( ',', map { Netdot::Mojo::Registry::csv_field($_) } @vals ) . "\n";
        }
        $c->res->headers->content_type( 'text/csv' );
        $c->res->headers->content_disposition( 'attachment; filename="' . $type . '-' . $csv_rel . '.csv"' );
        return $c->render( data => $csv );
    }

    my $offset = int( $c->param('offset') // 0 );
    $offset     = 0 if $offset < 0;
    my $perpage = eval { $obj->config->get('DEFAULT_PERPAGE') };
    $perpage    = 50 unless $perpage && $perpage > 0;

    my $relations = Netdot::Mojo::Detail::build_relations( $obj, $perpage, $offset );

    # Generic relation "Add" forms (editors only): one create form per
    # addable has_many relation, rendered in the relation's tab (see
    # detail.html.ep; specs from Detail::relation_adds). Mirrors the legacy
    # view.html [add] links (edit.html?table=<child>&<fk>=<parent>).
    my $rel_adds = $can_edit
        ? Netdot::Mojo::Detail::relation_adds( $obj, $c->current_person )
        : [];

    # Addable relations keep their tab visible even when empty (legacy showed
    # the [add] link on empty sections too; without this the relation's first
    # row could never be created from the page).
    my %have_rel = map { $_->{csv_rel} => 1 } @$relations;
    for my $a ( @$rel_adds ) {
        next if $have_rel{ $a->{rel} };
        my ( $cols, $show_label ) = Netdot::Mojo::Detail::rel_columns( $a->{related} );
        push @$relations, {
            title     => sprintf( '%s (0)', $a->{rel} ),
            cols      => $show_label
                            ? [ ucfirst( $a->{related} ), map { $_->[1] } @$cols ]
                            : [ map { $_->[1] } @$cols ],
            rows      => [],
            total     => 0,
            per       => $perpage,
            offset    => 0,
            start     => 0,
            last_item => 0,
            csv_rel   => $a->{rel},
        };
    }
    @$relations = sort { $a->{csv_rel} cmp $b->{csv_rel} } @$relations;

    # Relation name -> Add spec (for the form in the relation's tab).
    my %rel_adds_by_rel = map { $_->{rel} => $_ } @$rel_adds;

    # DhcpScope: keep the attributes tab (and its Add form) visible even when
    # the scope has no attributes yet (empty relations are skipped otherwise);
    # legacy showed the [add] link on empty sections too.
    if ( $type eq 'dhcscope' && $attr_names ) {
        unless ( grep { $_->{csv_rel} eq 'attributes' } @$relations ) {
            unshift @$relations, {
                title   => 'Attributes (0)',
                cols    => [ 'DhcpAttr', 'Scope' ],
                rows    => [],
                total   => 0,
                per     => $perpage,
                offset  => 0,
                start   => 0,
                last_item => 0,
                csv_rel => 'attributes',
            };
        }
        @$relations = sort { $a->{csv_rel} cmp $b->{csv_rel} } @$relations;
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
        attrs    => $attrs,
        relations => $relations,
        can_edit => $can_edit,
        fields   => $fields,
        api_path => $api_path,
        can_delete => $can_delete,
        del_path   => $del_path,
        del_goto   => $del_goto,
        setpass_api => $setpass_api,
        attr_names  => $attr_names,
        rel_adds    => \%rel_adds_by_rel,
    );
}

# Picture binary (read-only): serve a SitePicture / FloorPicture bindata BLOB
# inline with its content type, so a picture's label links straight to the image.
# Mirrors Closet#picture (the ClosetPicture equivalent, which has its own route).
=head2 picture - Serve a Site/Floor picture's binary data

Arguments:  Controller (stash: type = sitepicture | floorpicture; param: id)
Returns:    The picture BLOB with its stored content type (inline download)
Description: Read-only; gated on the right to view the owning site/floor.
            An unknown/invalid stored content type falls back to
            application/octet-stream. Mirrors Closet#picture.

=cut

sub picture ($c) {
    my %class  = ( sitepicture => 'Netdot::Model::SitePicture',
                   floorpicture => 'Netdot::Model::FloorPicture' );
    my %parent = ( sitepicture => 'site', floorpicture => 'floor' );
    my $ptype  = $c->stash('type');
    my $class  = $class{$ptype} or return $c->reply->not_found;
    my $id     = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $pic = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $pic;
    my $parent = eval { $pic->( $parent{$ptype} // '' ) };
    return if $parent && $c->deny_unless( 'view', $parent );
    my $data  = eval { $pic->bindata }  // '';
    my $ctype = eval { $pic->filetype } // '';
    $ctype = 'application/octet-stream' unless $ctype =~ /^\w+(?:\/\w+)*$/;
    my $fn    = eval { $pic->filename } // '';
    $c->res->headers->content_type( $ctype );
    $c->res->headers->content_disposition( qq{inline; filename="$fn"} ) if $fn;
    return $c->render( data => $data );
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