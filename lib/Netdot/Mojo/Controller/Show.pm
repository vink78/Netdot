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
    my $can_edit = $c->perm( 'edit', $obj );
    my $fields   = $can_edit ? Netdot::Mojo::Detail::build_edit_fields( $obj, $class ) : [];
    my $api_path = $can_edit ? $c->web_prefix . '/api/' . lc( $type ) . '/' . $id : '';

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
    );
}

# Picture binary (read-only): serve a SitePicture / FloorPicture bindata BLOB
# inline with its content type, so a picture's label links straight to the image.
# Mirrors Closet#picture (the ClosetPicture equivalent, which has its own route).
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

1;
