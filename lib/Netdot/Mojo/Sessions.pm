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

# Load session data from disk, keyed by the opaque id in the (plain) cookie.
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

1;
