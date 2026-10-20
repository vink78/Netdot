package Netdot::Mojo::Sessions;
#
# Server-side (flat-file) sessions for Netdot::Mojo.
#
# Replaces the default signed/encrypted cookie sessions with an *opaque*
# 128-bit random session id carried in a plain (unsigned) cookie, while the
# actual session data is stored on disk (one JSON file per session). This
# removes the symmetric-key dependency for sessions: the cookie holds
# nothing sensitive and cannot be "cracked" -- it only references a
# server-side file that exists only for valid, non-expired sessions.
#
# Security rests on:
#   - 128-bit random, unguessable ids (Crypt::URandom / /dev/urandom)
#   - plain cookie + HttpOnly + SameSite=Lax (+ Secure when SESSION_SECURE=1)
#   - strict id validation (path-traversal / injection guard) before ANY
#     file access on read
#   - 0600 files in a 0700 directory
#
# Works under Hypnotoad (multi-worker): every worker reads/writes the same
# files, so a session survives being served by a different worker.
#
# The data directory and the Secure flag come from Netdot config (see
# Default.conf / Site.conf): SESSION_DIR and SESSION_SECURE. The wiring in
# Netdot::Mojo passes them in via ->new(dir=>..., secure=>...).

use Mojo::Base 'Mojolicious::Sessions';

use Crypt::URandom;    # hard dependency (checked by `make testdeps`)
use Mojo::JSON         qw(decode_json);
use Mojo::File         qw(path);
use File::Temp         qw(tempfile);
use File::Path         qw(make_path);

my $SID_RE = qr/^[0-9a-f]{32}$/;   # 16 random bytes, lowercase hex

# Session data directory (set from config SESSION_DIR; last-resort fallback).
has dir => sub { '/tmp/sessions' };
# Seconds between opportunistic prunes of expired session files.
has purge_interval => 3600;

# 128-bit cryptographically secure random hex id (16 random bytes, hex).
sub _random_hex {
    return unpack 'H*', Crypt::URandom::urandom(16);
}

sub _ensure_dir {
    my $self = shift;
    my $dir  = $self->dir;
    make_path( $dir, { mode => 0700 } ) unless -d $dir;
    return $dir;
}

sub _file { path( $_[0]->dir )->child( $_[1] ) }

=encoding utf8

=head1 NAME

Netdot::Mojo::Sessions - Server-side (flat-file) sessions for Netdot::Mojo

    Replaces the default signed/encrypted cookie sessions with an opaque
    128-bit random session id carried in a plain (unsigned) cookie; the
    session data is stored on disk, one 0600 JSON file per session in a 0700
    directory (SESSION_DIR config). Works under Hypnotoad (multi-worker):
    every worker reads/writes the same files, so a session survives being
    served by a different worker. The engine is instantiated by Mojolicious
    and called with the controller as argument (see the header comment at
    the top of the file).

=head1 SYNOPSIS

    # Wired in Netdot::Mojo (dir/secure/idle from the Netdot config
    # SESSION_DIR / SESSION_SECURE / SESSION_IDLE):
    my $sessions = Netdot::Mojo::Sessions->new(
        dir    => '/var/lib/netdot/sessions',
        secure => 1,
    );

    # Called by Mojolicious on every request / session change:
    $sessions->load( $c );
    $sessions->store( $c );

=head1 INSTANCE METHODS

=cut

# Load session data from disk, keyed by the opaque id in the (plain) cookie.
=head2 load - Load session data from disk

Arguments:  Controller (reads the opaque session id from the plain cookie)
Returns:    1 when a valid, non-expired session file was loaded into the
            stash; nothing otherwise
Description: Part of the server-side flat-file session store (replacement of
            the signed/encrypted cookie sessions). The cookie holds only a
            128-bit random id (strictly validated before any file access:
            path-traversal / injection guard); the session data itself lives
            in a 0600 JSON file in a 0700 directory (SESSION_DIR config).
            Mirrors Mojolicious::Sessions sliding-expiry and flash handling.
            Works under Hypnotoad: every worker reads/writes the same files.

=cut

sub load {
    my ( $self, $c ) = @_;

    my $sid = $c->cookie( $self->cookie_name );
    return unless $sid && $sid =~ $SID_RE;        # path-traversal / injection guard

    my $file = $self->_file( $sid );
    $self->_ensure_dir;
    return unless -f $file->to_string;

    my $session = eval { decode_json( $file->slurp ) };
    return unless ref $session eq 'HASH';

    # Mirror Mojolicious::Sessions expiry handling (sliding "expiration").
    my $expiration = $session->{expiration} // $self->default_expiration;
    return if !( my $expires = delete $session->{expires} ) && $expiration;
    return if defined $expires && $expires <= time;

    my $stash = $c->stash;
    return unless $stash->{'mojo.active_session'} = keys %$session;
    $stash->{'mojo.session'} = $session;
    $session->{flash} = delete $session->{new_flash} if $session->{new_flash};
    return 1;
}

# Persist session data to disk + set the opaque id cookie.
=head2 store - Persist session data to disk

Arguments:  Controller (reads the session hash from the stash)
Returns:    1 when the session was stored (or the logout file/cookie was
            cleared); nothing when there is no session
Description: Persists the session hash as a JSON file (atomic write: temp
            file + rename, so a crash never leaves a partial file), reuses
            the client's session id when it is valid, otherwise mints a
            fresh 128-bit random id, and sets the plain cookie (HttpOnly,
            SameSite, Secure per SESSION_SECURE). On logout/expiry the file
            is removed and the cookie cleared. Also triggers the
            opportunistic prune of expired files (once per purge_interval).

=cut

sub store {
    my ( $self, $c ) = @_;

    my $stash = $c->stash;
    return unless my $session = $stash->{'mojo.session'};
    return unless keys %$session || $stash->{'mojo.active_session'};

    # Flash handling (same as the default store).
    my $old = delete $session->{flash};
    $session->{new_flash} = $old if $stash->{'mojo.static'};
    delete $session->{new_flash} unless keys %{ $session->{new_flash} };

    # "expires" from "expiration" if necessary (refreshed every request).
    my $expiration = $session->{expiration} // $self->default_expiration;
    my $default    = delete $session->{expires};
    $session->{expires} = $default || time + $expiration if $expiration || $default;

    my $name = $self->cookie_name;
    my %opts = (
        expires  => $session->{expires},
        httponly => 1,
        path     => $self->cookie_path,
        samesite => $self->samesite,
        secure   => $self->secure,
    );
    $opts{domain} = $self->cookie_domain if $self->cookie_domain;

    # Logout / expired: drop the file + clear the client cookie.
    my $exp = $session->{expires};
    if ( $exp && $exp <= time ) {
        my $old = $c->cookie( $name );
        $self->_file( $old )->remove if $old && $old =~ $SID_RE;
        $c->cookie( $name, '', { %opts, max_age => 0, expires => time - 1 } );
        return;
    }

    # Reuse the client's id when valid; otherwise start a fresh session.
    # $c->cookie() returns the cookie *value* ($c->req->cookie() would return
    # the Mojo::Cookie object, whose string form is "name=value" and would
    # never match $SID_RE -- causing a brand-new id (and file) every request).
    my $sid = $c->cookie( $name );
    $sid = _random_hex unless $sid && $sid =~ $SID_RE;

    my $file = $self->_file( $sid );
    $self->_ensure_dir;
    $self->_atomic_write( $file, $self->serialize->( $session ) );
    $c->cookie( $name, $sid, \%opts );

    $self->_maybe_purge;
    return 1;
}

# Write atomically (temp file + rename) so a crash never leaves a partial file.
sub _atomic_write {
    my ( $self, $file, $data ) = @_;
    my ( $fh, $tmp ) = tempfile( 'session_XXXXXX', DIR => $file->dirname->to_string, UNLINK => 0 );
    print {$fh} $data;
    close $fh;
    chmod 0600, $tmp;
    rename $tmp, $file->to_string;
    return;
}

# Cheap, opportunistic cleanup of expired session files (bounded to once per
# purge_interval across all workers).
sub _maybe_purge {
    my ($self) = @_;
    my $now = time;
    return if $now - ($Netdot::Mojo::Sessions::_last_purge // 0) < $self->purge_interval;
    $Netdot::Mojo::Sessions::_last_purge = $now;

    my $dir = $self->_ensure_dir;
    opendir my $dh, $dir or return;
    my $age = $self->default_expiration * 2;    # margin
    for my $name ( readdir $dh ) {
        next unless $name =~ $SID_RE;
        my @st = stat "$dir/$name" or next;
        unlink "$dir/$name" if $now - $st[9] > $age;    # [9] = mtime
    }
    closedir $dh;
    return;
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