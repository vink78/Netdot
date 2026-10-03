package Netdot::Mojo::Controller::Vlan;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;

# VLAN landing page (port of the original vlan.html SHOW_GROUPS action): two
# sections -- "VLAN Groups" and "Ungrouped VLANs". A Vlan's detail page is the
# generic one (show#show); this controller only builds the landing list.
sub list ($c) {
    my $person = $c->current_person;

    # Per-user 'view' fragments (RAW, un-prefixed; combined by the model via
    # _combine_where). undef = unrestricted (Admin/Operator), '0' = none.
    my $frag_group = undef;
    my $frag_vlan  = undef;
    if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
        my ($wg) = Netdot::Mojo::Permissions->viewable_predicate( 'VlanGroup', $person );
        my ($wv) = Netdot::Mojo::Permissions->viewable_predicate( 'Vlan',      $person );
        $frag_group = $wg;
        $frag_vlan  = $wv;
    }

    # VLAN Groups: all groups (bounded), ordered by the range start (like the
    # original sortresults sort => 'start_vid'). No pagination (few rows).
    my @groups = 'VlanGroup'->search_page( where => $frag_group, order_by => 'start_vid', limit => 0 );

    # Ungrouped VLANs: vlans with no vlangroup (vlangroup IS NULL). The model's
    # generic search_page can't express IS NULL, so fetch the bounded set ordered
    # by vid and keep only the ungrouped ones.
    my @vlans = 'Vlan'->search_page( where => $frag_vlan, order_by => 'vid', limit => 0 );
    @vlans = grep { ! eval { $_->vlangroup } } @vlans;

    my $spec_g = Netdot::Mojo::Registry::spec( 'vlangroup' );
    my $spec_v = Netdot::Mojo::Registry::spec( 'vlan' );

    # Table rows: id + the type's display columns; FK cells become links.
    # NB: @objs is passed as a flattened list, so pop the two trailing scalar
    # args (spec, type) first -- a plain "my ( @objs, $spec, $type ) = @_" would
    # (object arrayref, spec, type) -- an arrayref for the objects avoids the
    # flattened-list pitfall where a leading @array swallows the trailing args.
    my $build_rows = sub {
        my ( $objs, $spec, $type ) = @_;
        my $class  = $spec->{class};
        my @cols   = @{ $spec->{cols} };
        my $first  = $cols[0];
        my %linkkey = map { $_ => Netdot::Mojo::Registry::column_link_key( $class, $_ ) } @cols;
        my @rows;
        for my $o (@$objs) {
            my %row = ( id => $o->id );
            for my $col (@cols) {
                my $v = eval { $o->$col };
                $v = undef if $@;
                my $label = Netdot::Mojo::Registry::format_value( $v );
                if ( $col eq $first ) {
                    $row{$col} = $label;
                    next;
                }
                my $id = ref( $v ) ? eval { $v->id } : $v;
                $row{$col} = ( $linkkey{$col} && defined $id && $id =~ /^\d+$/ )
                    ? sprintf( '<a href="%s">%s</a>',
                               Netdot::Mojo::Registry::set_uri( "/management/$linkkey{$col}/$id" ),
                               Netdot::Mojo::Registry::esc( $label ) )
                    : Netdot::Mojo::Registry::esc( $label );
            }
            push @rows, \%row;
        }
        return ( \@rows, \@cols );
    };

    my ( $grows, $gcols ) = $build_rows->( \@groups, $spec_g, 'vlangroup' );
    my ( $vrows, $vcols ) = $build_rows->( \@vlans,  $spec_v, 'vlan' );

    $c->render(
        template  => 'management/vlan',
        layout    => 'default',
        title     => 'VLANs',
        gcols     => $gcols,
        grows     => $grows,
        vcols     => $vcols,
        vrows     => $vrows,
    );
}

1;
