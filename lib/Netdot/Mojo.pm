package Netdot::Mojo;

use Mojo::Base 'Mojolicious', -signatures;

use File::Basename qw(dirname);
use Cwd          qw(abs_path);

use Netdot::Model;    # loads Netdot (config + meta) and connects to the DB

sub startup ($self) {

    # ---- Template path: project's htdocs/ convention (like Mason) ----
    # __FILE__ = <root>/lib/Netdot/Mojo.pm  =>  <root> = 3 dirname
    my $root   = abs_path( dirname( dirname( dirname( __FILE__ ) ) ) );
    my $htdocs = "$root/htdocs";
    push @{ $self->renderer->paths }, $htdocs;

    # ---- Sessions / cookies ----
    $self->secrets([ $ENV{NETDOT_MOCK} // 'netdot-mojo-dev-change-me' ]);

    # ---- Routes ----
    my $r = $self->routes;
    $r->get('/')->to('home#index')->name('home');
    $r->get('/management/ipblock_list')->to('browse#ipblock_list')->name('ipblock_list');
    $r->get('/management/device')->to('browse#device_list')->name('device_list');
    $r->get('/login')->to('auth#login_form')->name('login');
    $r->post('/login')->to('auth#login_submit');
    $r->get('/logout')->to('auth#logout')->name('logout');
}

1;
