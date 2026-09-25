package Netdot::Mojo::Controller::Home;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    $c->redirect_to( $c->url_for('ipblock_list') );
}

1;
