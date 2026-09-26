package Netdot::Mojo::Controller::Home;

use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    $c->render( template => 'index', layout => 'default', title => 'Home' );
}

1;
