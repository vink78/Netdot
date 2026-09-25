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
    return Netdot->config->get($key);
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
