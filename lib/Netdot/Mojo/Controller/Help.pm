package Netdot::Mojo::Controller::Help;

use Mojo::Base 'Mojolicious::Controller';
use Netdot::Model;
use File::Path qw(make_path);

my $ROOT = sub { Netdot->config->get('NETDOT_PATH') };

# Help landing page: links to Manual + Database schema.
sub index {
    my $c = shift;
    $c->render(
        template => 'help/index',
        layout   => 'default',
        title    => 'Help',
    );
}

# User Manual: serve the static pandoc-generated HTML document.
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
        img      => $err ? undef : '/img/graphs/schema.png',
        error    => $err,
    );
}

1;
