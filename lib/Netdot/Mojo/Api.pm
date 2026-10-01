package Netdot::Mojo::Api;

# Framework-agnostic JSON serializer for the Netdot REST API (port of
# Netdot::REST::get / _get_linked_from, which are Apache2-based). Produces
# plain hashrefs suitable for Mojolicious `render(json => ...)`.
#
# FK columns are rendered as:
#   "col"        => <label>          (depth 0)
#   "col_xlink"  => "Class/<id>"     (a resource path usable on this API)
# With depth > 0 the FK value becomes the full nested object instead.
# `linked_from => 1` adds a "linked_from" key with back-references
# (arrays of "Class/<id>", or nested objects when depth > 0).
#
# Errors are signalled by `die Netdot::Mojo::Api::Error->new(code=>,msg=>)`,
# caught by the controller and turned into a JSON error response.

use strict;
use warnings;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Permissions;

# ---------------------------------------------------------------------------
# Tiny exception carrying an HTTP status code + message.
# ---------------------------------------------------------------------------
package Netdot::Mojo::Api::Error;

sub new {
    my ( $class, %a ) = @_;
    return bless { code => ( $a{code} || 500 ), msg => ( $a{msg} || 'Error' ) }, $class;
}
sub code { $_[0]->{code} }
sub msg  { $_[0]->{msg} }
sub as_string { $_[0]->{msg} }

# ---------------------------------------------------------------------------
package Netdot::Mojo::Api;

# Serialize a Netdot object to a JSON-ready hashref.
#   $obj        - Netdot::Model object
#   $user       - Person (for permission checks)
#   $manager    - unused in the Mojolicious port (permissions via $user)
#   %opts       - depth => int (default 0), linked_from => 1
sub get {
    my ( $obj, $user, $manager, %argv ) = @_;

    $obj or _die(404, 'Object not found');

    # Per-object view permission (mirrors Netdot::REST::get).
    unless ( Netdot::Mojo::Permissions->can( $user, 'view', $obj ) ) {
        _die( 403, 'User not allowed to view this object' );
    }

    my $depth = defined $argv{depth} ? $argv{depth} : 0;
    $depth = 0 if $depth < 0;

    my %ret;
    $ret{id} = $obj->id;

    my %order;
    eval { %order = $obj->meta_data->get_column_order };
    my %linksto;
    eval { %linksto = $obj->meta_data->get_links_to };

    if ( $argv{linked_from} ) {
        $ret{linked_from} = _get_linked_from( $obj, $user, depth => $depth );
    }

    for my $col ( keys %order ) {
        if ( grep { $_ eq $col } keys %linksto ) {
            # Foreign key
            my $fid = eval { int( $obj->$col // 0 ) };
            $fid = 0 if !defined $fid || $fid < 0;
            if ($fid) {
                my $fclass = $linksto{$col};
                my $fobj   = eval { $obj->$col };
                if ($depth) {
                    $ret{$col} = $fobj
                        ? get( $fobj, $user, $manager, depth => $depth - 1, linked_from => $argv{linked_from} )
                        : undef;
                }
                else {
                    $ret{$col} = $fobj ? eval { $fobj->get_label } // '' : '';
                    $ret{ $col . '_xlink' } = $fclass . '/' . $fid;
                }
            }
            else {
                $ret{$col} = 0;
            }
        }
        else {
            $ret{$col} = eval { $obj->$col };
        }
    }

    return \%ret;
}

# Back-references: for each has_many relation pointing at $obj, list the
# related objects (as "Class/<id>" strings, or nested objects when depth > 0).
sub _get_linked_from {
    my ( $obj, $user, %argv ) = @_;
    my $depth = $argv{depth} || 0;

    my %linksfrom;
    eval { %linksfrom = $obj->meta_data->get_links_from };

    my %results;
    for my $i ( keys %linksfrom ) {
        my $rtables = $linksfrom{$i};
        next unless ref $rtables eq 'HASH';
        my ($rtable) = sort keys %$rtables;
        next unless $rtable && length $rtable;

        my @robjs;
        eval { @robjs = $obj->$i };

        if ($depth) {
            map { push @{ $results{$i} }, get( $_, $user, undef, depth => $depth - 1 ) } @robjs;
        }
        else {
            map { push @{ $results{$i} }, $rtable . '/' . $_->id } @robjs;
        }
    }
    return \%results if %results;
    return undef;
}

# Internal: raise a tagged API error.
sub _die {
    my ( $code, $msg ) = @_;
    die Netdot::Mojo::Api::Error->new( code => $code, msg => $msg );
}

1;
