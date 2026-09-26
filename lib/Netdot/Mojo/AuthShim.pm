package Netdot::Mojo::AuthShim;

use strict;
use warnings;

# Simule l'objet requete Apache ($r) attendu par Netdot::LDAP et Netdot::AuthLocal :
#   ->dir_config(nom) : renvoie la valeur depuis la config Netdot (etc/Site.conf)
#   ->log_error(msg)  : log via le logger Mojolicious
#   ->warn(msg)       : idem
#
# Permet de reutiliser l'auth existante hors Apache sans la modifier.

sub new {
    my ( $class, %args ) = @_;
    return bless { app => $args{app} }, $class;
}

sub dir_config {
    my ( $self, $key ) = @_;
    require Netdot;
    # Netdot::Config->get croake si la cle est absente ; Apache dir_config renvoie
    # undef. On renvoie donc undef (sans exception) si la cle n'est pas definie.
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
