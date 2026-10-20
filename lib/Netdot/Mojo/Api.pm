package Netdot::Mojo::Api;

# Framework-agnostic JSON serializer for the Netdot REST API (port of
# Netdot::REST::get / _get_linked_from, which are Apache2-based). Produces
# plain hashrefs suitable for Mojolicious `render(json => ...)`.
#
# FK columns are rendered as a nested lightweight reference:
#   "col" => { id, url, ...label fields }
# i.e. the target's id/url plus its label fields (get_hashref): e.g.
#   { id, url, name } for a Zone, { id, url, address, prefix } for an Ipblock.
# A foreign key that points at nothing (null FK) is rendered as null.
# With depth > 0 the FK value becomes the full nested object instead.
# `linked_from => 1` adds a "linked_from" key with back-references
# (arrays of the same {id, url, ...label fields} references, or nested objects
#  when depth > 0).
#
# Errors are signalled by `die Netdot::Mojo::Api::Error->new(code=>,msg=>)`,
# caught by the controller and turned into a JSON error response.

use strict;
use warnings;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Permissions;
use Netdot::Mojo::Registry;
use JSON::PP ();

=encoding utf8

=head1 NAME

Netdot::Mojo::Api - Framework-agnostic JSON serializer for the Netdot REST API

    Port of Netdot::REST::get / _get_linked_from (which were Apache2-based),
    producing plain hashrefs suitable for Mojolicious render(json => ...).
    Foreign keys are rendered as lightweight nested references (the
    target's id, url and label fields); see the header comment at the top of
    the file for the full rendering rules (depth, linked_from). Errors are
    signalled by C<< die Netdot::Mojo::Api::Error->new(code =>, msg =>) >>
    and caught by the controller, which turns them into a JSON error
    response.

=head1 SYNOPSIS

    use Netdot::Mojo::Api;

    # Serialize one object (FKs as lightweight references):
    my $hashref = Netdot::Mojo::Api::get( $obj, $person );
    $c->render( json => $hashref );

    # FK values as full nested objects instead of references:
    my $full = Netdot::Mojo::Api::get( $obj, $person, undef, depth => 1 );

=head1 CLASS METHODS

=cut

# ---------------------------------------------------------------------------
# Tiny exception carrying an HTTP status code + message.
# ---------------------------------------------------------------------------
package Netdot::Mojo::Api::Error;

=head2 new - Create an API error

Arguments:  C<< Error->new(code => HTTP_code, msg => message) >>
Returns:    Blessed Netdot::Mojo::Api::Error object

=cut

sub new {
    my ( $class, %a ) = @_;
    return bless { code => ( $a{code} || 500 ), msg => ( $a{msg} || 'Error' ) }, $class;
}

=head2 code - Return the HTTP status code carried by the error

Arguments:  None
Returns:    HTTP status code (default 500)

=cut

sub code { $_[0]->{code} }

=head2 msg - Return the error message

Arguments:  None
Returns:    Human-readable error message

=cut

sub msg  { $_[0]->{msg} }

=head2 as_string - Stringify the error (used when it is $@)

Arguments:  None
Returns:    The error message

=cut

sub as_string { $_[0]->{msg} }

# ---------------------------------------------------------------------------
package Netdot::Mojo::Api;

# Cached API base path: WEB_BASE_URL + '/api' (e.g. '/netdot/api', or a full
# URL when WEB_BASE_URL is an absolute URL). Computed once.
my $_API_BASE;
sub _api_base {
    return $_API_BASE if defined $_API_BASE;
    my $b = eval { Netdot->config->get('WEB_BASE_URL') };
    $b = '' unless defined $b && !ref $b;
    $b =~ s{/*$}{};
    $_API_BASE = $b . '/api';
    return $_API_BASE;
}

# Resource URL: <base>/<lc table>/<id>/  (matches the API routes, which key
# tables by lc(db_name) == lc(short_class)).
sub _api_url {
    my ($obj) = @_;
    return _api_base() . '/' . lc( $obj->short_class ) . '/' . $obj->id . '/';
}

# A lightweight nested reference for a foreign key: { id, url, ...label fields }.
# The id/url plus the target's label fields (get_hashref): e.g. {name} for a Zone,
# {address, prefix} for an Ipblock, {name, zone} for an RR.
#   $fobj   - the referenced object (may be undef if the FK id is set but the
#             object cannot be loaded)
#   $fclass - short class of the target (e.g. 'Zone'), used to build the URL
#             when $fobj is unavailable
#   $fid    - the referenced object id
sub _ref {
    my ( $fobj, $fclass, $fid ) = @_;
    my %r = (
        id  => $fid,
        url => $fobj ? _api_url( $fobj ) : _api_base() . '/' . lc( $fclass ) . '/' . $fid . '/',
    );
    if ($fobj) {
        my $h = eval { $fobj->get_hashref } // {};
        $h = {} unless ref $h eq 'HASH';
        %r = ( %r, %$h );
    }
    return \%r;
}

# Serialize a Netdot object to a JSON-ready hashref.
#   $obj        - Netdot::Model object
#   $user       - Person (for permission checks)
#   $manager    - unused in the Mojolicious port (permissions via $user)
#   %opts       - depth => int (default 0), linked_from => 1
=head2 get - Serialize a Netdot object into a JSON-ready hashref

Arguments:  $obj (Netdot::Model object), $user (Person, for permission checks),
            $manager (unused in the Mojolicious port), %opts:
            C<< depth => int >> (default 0: FK columns are rendered as a
            lightweight C<< {id, url, ...label fields} >> reference; >0: the FK
            value becomes the full nested object), C<< linked_from => 1 >>
            (adds a "linked_from" key holding the back-references, as arrays of
            references or of nested objects when depth > 0)
Returns:    Hashref ready for C<< render(json => ...) >>: the object id, its
            url, every non-sensitive column (boolean columns as real JSON
            true/false) and, per FK, a nested reference (null when the FK is
            null)
Exceptions: 404 if $obj is undef; 403 if $user may not view the object

=cut

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
    $ret{id}  = $obj->id;
    $ret{url} = _api_url( $obj );

    my %order;
    eval { %order = $obj->meta_data->get_column_order };
    my %linksto;
    eval { %linksto = $obj->meta_data->get_links_to };

    if ( $argv{linked_from} ) {
        $ret{linked_from} = _get_linked_from( $obj, $user, depth => $depth );
    }

    for my $col ( keys %order ) {
        # Never serialize secrets / raw credentials (password, snmp keys, ...) —
        # same guard the HTML detail views use (Registry::is_sensitive).
        next if Netdot::Mojo::Registry::is_sensitive( $col );
        if ( grep { $_ eq $col } keys %linksto ) {
            # Foreign key -> nested lightweight reference {id, url, name}.
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
                    $ret{$col} = _ref( $fobj, $fclass, $fid );
                }
            }
            else {
                $ret{$col} = undef;   # null FK -> no reference object
            }
        }
        else {
            my $v = eval { $obj->$col };
            if ( Netdot::Mojo::Registry::column_type( $obj, $col ) eq 'bool' ) {
                # Boolean column -> real JSON true/false (not a 0/1 number).
                $ret{$col} = defined $v ? ( $v ? JSON::PP::true : JSON::PP::false ) : undef;
            }
            else {
                $ret{$col} = $v;
            }
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
            map { push @{ $results{$i} }, _ref( $_, $rtable, $_->id ) } @robjs;
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