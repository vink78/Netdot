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

1;
