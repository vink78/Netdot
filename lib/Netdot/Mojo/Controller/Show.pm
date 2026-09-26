package Netdot::Mojo::Controller::Show;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::UI;
use Netdot::Mojo::Registry;

# Read-only detail page for one object: every non-empty, non-sensitive attribute.
sub show ($c) {
    my $type = $c->stash('type');
    my $spec = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};

    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;

    # ipblock: hierarchical detail with a view-format flag (list | block | tree).
    if ( $type eq 'ipblock' ) {
        my $o = eval { $class->retrieve( $id ) };
        return $c->reply->not_found unless $o;

        my $cfg    = Netdot->config;
        my $status = eval { $o->status->name } // '';
        my $prefix = $o->prefix;
        my $v4     = ( $o->version == 4 );

        # View modes available for this block (rules from ip.html):
        #   list always; block for v4 when prefix >= MAX; tree for v4 containers.
        my $max = $status eq 'Subnet' ? $cfg->get('SUBNET_BLOCK_VIEW_MAX_PREFIX')
                 : ( $status eq 'Container' ? $cfg->get('CONTAINER_BLOCK_VIEW_MAX_PREFIX') : undef );
        my @modes = ( 'list' );
        push @modes, 'block' if ( $v4 && $max && $prefix >= $max );
        push @modes, 'tree'  if ( $v4 && $status eq 'Container' );

        # Effective view: requested (sanitized), defaulting to the config value,
        # forced to an available mode (so v6 / too-large blocks fall back to list).
        my $vfmt = $c->param('view_format');
        $vfmt = $cfg->get('DEFAULT_IPBLOCK_VIEW') || 'block' unless $vfmt;
        $vfmt = 'list' unless $vfmt =~ /^(list|block|tree)$/;
        $vfmt = 'list' unless grep { $_ eq $vfmt } @modes;

        # Objects to display, depending on the effective view.
        my ( @blocks, $viewtype, $tree_html );
        if ( $vfmt eq 'list' ) {
            if ( $status eq 'Subnet' ) {
                @blocks   = $o->get_addresses_by('Address');   # individual addresses
                $viewtype = @blocks ? 'address' : 'block';
            } else {
                @blocks   = _ipblock_children( $o );            # contained IP blocks
                $viewtype = @blocks && eval { $blocks[0]->is_address } ? 'address' : 'block';
            }
        } else {  # block or tree: the descendant subnets (no individual addresses)
            my $ref    = eval { $o->get_descendants( no_addresses => 1 ) };
            @blocks    = ref( $ref ) eq 'ARRAY' ? @$ref : ();
            @blocks    = grep { $_ && $_->prefix > $prefix } @blocks;  # proper descendants
            $viewtype  = 'block';
            if ( $vfmt eq 'tree' ) {
                my $ui = eval { Netdot::UI->new() };
                $tree_html = ( $ui && $ref ) ? eval { $ui->build_ip_tree_graph_html( id => $o->id, list => $ref ) } : undef;
            }
        }

        my @ancs   = $o->get_ancestors;
        my @crumbs = ( { label => 'Roots', id => 0 } );
        push @crumbs, map { { label => $_->get_label, id => $_->id } } ( reverse @ancs );
        my $devs   = $viewtype eq 'address' ? ( eval { Device->get_ips_from_all() } || {} ) : undef;

        $c->render(
            template   => 'management/ipblock',
            layout     => 'default',
            title      => "Ipblock " . $o->get_label,
            viewtype   => $viewtype,
            viewformat => $vfmt,
            modes      => \@modes,
            tree_html  => $tree_html,
            blocks     => \@blocks,
            current    => $o,
            breadcrumb => \@crumbs,
            devs       => $devs,
        );
        return;
    }

    my $obj = eval { $class->retrieve($id) };
    return $c->reply->not_found unless $obj;

    my @attrs;
    for my $col ( $class->columns ) {
        next if $col eq 'id';
        next if Netdot::Mojo::Registry::is_sensitive($col);
        my $v = eval { $obj->$col };
        next if $@;
        next unless defined $v;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        next if !defined $text || $text eq '';
        push @attrs, [ $col, $text, $href ];
    }

    $c->render(
        template => 'management/detail',
        layout   => 'default',
        title    => ucfirst($type) . " #$id",
        type     => $type,
        id       => $id,
        attrs    => \@attrs,
    );
}

# Direct children of an ipblock. ->children returns a Class::DBI::Iterator, so it
# must be iterated (a plain list assignment via eval() degrades to the iterator).
sub _ipblock_children {
    my ($o) = @_;
    my @kids;
    my $it = eval { $o->children };
    if ( $it && $it->isa( 'Class::DBI::Iterator' ) ) {
        while ( my $k = $it->next ) {
            push @kids, $k;
        }
    }
    return @kids;
}

1;
