package Netdot::Mojo::Controller::Home;

use Mojo::Base 'Mojolicious::Controller', -signatures;

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Home - Home page

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/')->to('home#index')

=head1 INSTANCE METHODS

=cut

=head2 index - Home page

Arguments:  Controller
Returns:    Renders the index template

=cut

sub index ($c) {
    $c->render( template => 'index', layout => 'default', title => 'Home' );
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