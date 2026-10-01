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
        my @objs;
        eval { @objs = $obj->$csv_rel };
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
    );
}

1;
