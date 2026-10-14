package Netdot::Mojo::Controller::Help;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use File::Path qw(make_path);

my $ROOT = sub { Netdot->config->get('NETDOT_PATH') };

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Help - Help pages (manual + database schema)

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/help')->to('help#index')
    #   ->get('/help/manual')->to('help#manual')
    #   ->get('/help/database')->to('help#database')
    #   ->get('/help/database/graph')->to('help#graph')

=head1 INSTANCE METHODS

=cut

# Help landing page: links to Manual + Database schema.
=head2 index - Help landing page

Arguments:  Controller
Returns:    Renders the help/index template (links to Manual + Database
            schema)

=cut

sub index {
    my $c = shift;
    $c->render(
        template => 'help/index',
        layout   => 'default',
        title    => 'Help',
    );
}

# User Manual: serve the static pandoc-generated HTML document.
=head2 manual - Serve the User Manual

Arguments:  Controller
Returns:    The static pandoc-generated HTML document
            (NETDOT_PATH/doc/manual/netdot-manual.html), or the help page
            with an error when the file is missing

=cut

sub manual {
    my $c    = shift;
    my $file = $ROOT->() . '/doc/manual/netdot-manual.html';

    unless ( -r $file ) {
        $c->render(
            template => 'help/index',
            layout   => 'default',
            title    => 'Help',
            error    => 'Manual file not found: ' . $file,
        );
        return;
    }

    $c->reply->file($file);
}

# Database schema (HTML) via Netdot::Meta::SQLT.
=head2 database - Database schema (HTML)

Arguments:  Controller
Returns:    Renders the help/database template with the HTML schema produced
            by Netdot::Meta::SQLT->html_schema (error shown in-page on
            failure)

=cut

sub database {
    my $c    = shift;
    my $html = '';
    my $err;
    eval {
        require Netdot::Meta::SQLT;
        my $sqlt = Netdot::Meta::SQLT->new;
        $html = $sqlt->html_schema();
        1;
    } or do { $err = $@; };

    $c->render(
        template => 'help/database',
        layout   => 'default',
        title    => 'Database Schema',
        schema   => $html,
        error    => $err,
    );
}

# Database schema (GraphViz PNG) via Netdot::Meta::SQLT.
=head2 graph - Database schema (GraphViz PNG)

Arguments:  Controller
Returns:    Renders the help/graph template; generates the GraphViz PNG
            (NETDOT_PATH/htdocs/img/graphs/schema.png) via
            Netdot::Meta::SQLT->graphviz_schema before rendering

=cut

sub graph {
    my $c    = shift;
    my $dir  = $ROOT->() . '/htdocs/img/graphs';
    my $file = "$dir/schema.png";
    my $err;

    eval {
        make_path($dir) unless -d $dir;
        require Netdot::Meta::SQLT;
        my $sqlt = Netdot::Meta::SQLT->new;
        $sqlt->graphviz_schema( out_file => $file, output_type => 'png', width => 40, height => 30 );
        1;
    } or do { $err = $@; };

    $c->render(
        template => 'help/graph',
        layout   => 'default',
        title    => 'Database Schema (Graph)',
        img      => $err ? undef : $c->web_prefix . '/img/graphs/schema.png',
        error    => $err,
    );
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