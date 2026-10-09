package Netdot::Mojo::AuthShim;

use strict;
use warnings;

# Emulates the Apache request object ($r) expected by Netdot::LDAP and Netdot::AuthLocal:
#   ->dir_config(key): returns the value from Netdot config (etc/Site.conf)
#   ->log_error(msg) : logs via the Mojolicious logger
#   ->warn(msg)      : same
#
# Allows reusing the existing auth out of Apache without modifying it.

sub new {
    my ( $class, %args ) = @_;
    return bless { app => $args{app} }, $class;
}

sub dir_config {
    my ( $self, $key ) = @_;
    require Netdot;
    # Netdot::Config->get croaks if the key is absent; Apache dir_config returns
    # undef. So we return undef (without an exception) if the key is not defined.
    my $val = eval { Netdot->config->get($key) };
    return $val;
}

sub log_error {
    my ( $self, $msg ) = @_;
    $self->{app}->log->warn( "[netdot-auth] $msg" ) if $self->{app};
    return;
}

sub warn {
    my ( $self, $msg ) = @_;
    $self->{app}->log->warn( "[netdot-auth] $msg" ) if $self->{app};
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