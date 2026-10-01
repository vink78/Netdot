package Netdot::Mojo::Controller::Closet;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Detail page for a Closet (port of cable_plant/closet.html, read-only).
# Sections:
#   - Closet info: a curated two-column layout (physical attributes) + info comment.
#   - Device List: devices in the closet's room (room -> floor -> site).
#   - Backbone Cable: backbones_start + backbones_end merged (read-only).
#   - Horizontal Cable: horizontalcables (read-only).
# Write actions ([new]/[edit]/picture upload) are omitted (edit interface not
# migrated); the backbone/horizontal link types are deprecated (see TODO), so
# their names are shown as plain text rather than deep links.
my @LEFT_FIELDS  = qw(name room dimensions racks outlets shared_with hvac_type ground_buss asbestos_tiles);
my @RIGHT_FIELDS = qw(ru_avail patch_panels ot_blocks ss_blocks catv_taps access_key_type rack_type pair_count converted_patch_panels work_needed);

sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { Closet->retrieve($id) };
    return $c->reply->not_found unless $o;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $perpage = eval { $o->config->get('DEFAULT_PERPAGE') };
    $perpage = 50 unless $perpage && $perpage > 0;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    $c->render(
        template   => 'management/closet',
        layout     => 'default',
        title      => 'Closet ' . ( $o->get_label // $id ),
        type       => 'closet',
        id         => $id,
        left       => _curated( $o, \@LEFT_FIELDS ),
        right      => _curated( $o, \@RIGHT_FIELDS ),
        info       => _text( $o, 'info' ),
        devices    => _devices( $o ),
        backbones  => _backbones( $o ),
        horizontal => _horizontal( $o ),
        perpage    => $perpage,
        offset     => $offset,
    );
}

# Curated field list -> [tag, text, href] rows (empty values shown blank).
sub _curated {
    my ( $o, $fields ) = @_;
    my $class = ref $o;
    my @out;
    for my $col (@$fields) {
        my $tag = Netdot::Mojo::Registry::column_tag( $class, $col );
        my $v   = eval { $o->$col };
        $v = undef if $@;
        my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for($v) };
        $text = '' unless defined $text;
        push @out, [ $tag, $text, $href ];
    }
    return \@out;
}

# Devices located in the closet's room (room -> floor -> site).
sub _devices {
    my ($o) = @_;
    my $room  = eval { $o->room };
    my $floor = $room ? eval { $room->floor } : undef;
    my $site  = $floor ? eval { $floor->site } : undef;
    return [] unless $site;
    my @devs = eval { @{ Device->search( site => $site->id, room => $room->id ) } } || ();
    my @rows;
    for my $d (@devs) {
        my ( $dt, $dh ) = @{ Netdot::Mojo::Registry::link_for($d) };
        push @rows, [
            [ $dt // '', $dh // '' ],
            [ Netdot::Mojo::Registry::format_value( eval { $d->ipv4 } ) // '', '' ],
            [ Netdot::Mojo::Registry::format_value( eval { $d->ipv6 } ) // '', '' ],
        ];
    }
    return \@rows;
}

# Backbone cables touching this closet (start + end), merged and sorted by name.
sub _backbones {
    my ($o) = @_;
    my @b = @{ _arr( eval { $o->backbones_start } ) };
    my @e = @{ _arr( eval { $o->backbones_end } ) };
    my @all = sort { _nm($a) cmp _nm($b) } (@b, @e);
    my @rows;
    for my $bb (@all) {
        push @rows, [
            [ _txt( eval { $bb->name } ), '' ],
            [ _txt( _fk( eval { $bb->type } ) ), '' ],
            [ _cell( eval { $bb->start_closet } ) ],
            [ _cell( eval { $bb->end_closet } ) ],
            [ _txt( _fk( eval { $bb->owner } ) ), '' ],
        ];
    }
    return \@rows;
}

# Horizontal cables in this closet, sorted by jack id.
sub _horizontal {
    my ($o) = @_;
    my @h = sort { _nj($a) cmp _nj($b) } @{ _arr( eval { $o->horizontalcables } ) };
    my @rows;
    for my $x (@h) {
        push @rows, [
            [ _txt( eval { $x->jackid } ), '' ],
            [ _txt( _fk( eval { $x->type } ) ), '' ],
            [ _cell( eval { $x->room } ) ],
        ];
    }
    return \@rows;
}

# --- small helpers ---------------------------------------------------------
sub _arr { my $v = shift; return ( ref $v eq 'ARRAY' ) ? $v : []; }

sub _nm { my $o = shift; my $n = eval { $o->name }; return defined $n ? $n : ''; }
sub _nj { my $o = shift; my $n = eval { $o->jackid }; return defined $n ? $n : ''; }

# A related (FK) object rendered as a [text, href] cell (no link if type has no
# route, e.g. deprecated cable types).
sub _cell {
    my ($v) = @_;
    return [ '', '' ] unless ref $v;
    my ( $t, $h ) = @{ Netdot::Mojo::Registry::link_for($v) };
    return [ $t // '', $h // '' ];
}

# Resolve a value that may be an FK object or a scalar to display text.
sub _fk {
    my ($v) = @_;
    return $v unless ref $v;
    my $lbl = eval { $v->get_label };
    return ( defined $lbl && length $lbl ) ? $lbl : ( eval { "$v" } // '' );
}

sub _txt { my $v = shift; $v = Netdot::Mojo::Registry::format_value($v); return defined $v ? $v : ''; }

sub _text {
    my ( $o, $col ) = @_;
    my $v = eval { $o->$col };
    return ( defined $v ? $v : '' );
}

1;
