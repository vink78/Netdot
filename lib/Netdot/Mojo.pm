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

    # One list + one detail route per browsable type (see Netdot::Mojo::Registry).
    for my $t (qw(ipblock device vlan zone interface person)) {
        $r->get("/management/$t")->to('browse#list', type => $t)->name("${t}_list");
        $r->get("/management/$t/:id")->to('show#show', type => $t)->name("${t}_show");
    }
    $r->get('/login')->to('auth#login_form')->name('login');
    $r->post('/login')->to('auth#login_submit');
    $r->get('/logout')->to('auth#logout')->name('logout');
}

1;
