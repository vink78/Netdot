package Netdot::Mojo;

use Mojo::Base 'Mojolicious', -signatures;

use File::Basename qw(dirname);
use Cwd          qw(abs_path);

use Netdot::Model;    # loads Netdot (config + meta) and connects to the DB
use Netdot::Mojo::Registry;

sub startup ($self) {

    # ---- Template path: project's htdocs/ convention (like Mason) ----
    # __FILE__ = <root>/lib/Netdot/Mojo.pm  =>  <root> = 3 dirname
    my $root   = abs_path( dirname( dirname( dirname( __FILE__ ) ) ) );
    my $htdocs = "$root/htdocs";
    push @{ $self->renderer->paths }, $htdocs;
    push @{ $self->static->paths },   $htdocs;    # static assets (css, img, js)

    # ---- Sessions / cookies ----
    $self->secrets([ $ENV{NETDOT_MOCK} // 'netdot-mojo-dev-change-me' ]);

    # ---- Routes ----
    my $r = $self->routes;
    $r->get('/')->to('home#index')->name('home');

    # Per browsable type: list, CSV export, batch delete, then detail (see Registry).
    # csv/delete are declared before :id so they win over the id placeholder.
    for my $t ( Netdot::Mojo::Registry::types() ) {
        $r->get("/management/$t")->to('browse#list', type => $t)->name("${t}_list");
        $r->get("/management/$t/csv")->to('browse#csv', type => $t)->name("${t}_csv");
        $r->post("/management/$t/delete")->to('browse#delete', type => $t)->name("${t}_delete");
        # ipblock has a dedicated detail controller; the rest use the generic one.
        my $show_ctrl = $t eq 'ipblock' ? 'ipblock' : 'show';
        $r->get("/management/$t/:id")->to("${show_ctrl}#show", type => $t)->name("${t}_show");
    }
    $r->get('/login')->to('auth#login_form')->name('login');
    $r->post('/login')->to('auth#login_submit');
    $r->get('/logout')->to('auth#logout')->name('logout');

    # ---- Authentication: redirect (302) unauthenticated requests to /login ----
    # Public paths (login/logout and static assets) are exempt.
    $self->hook( before_dispatch => sub {
        my ($c)  = @_;
        my $path = $c->req->url->path;
        return if $path eq '/login' || $path eq '/logout';
        return if $path =~ m{^/(?:css|img|java_script)(?:/|$)};
        return if $path eq '/favicon.ico';
        $c->redirect_to( $c->url_for('login') ) unless $c->session('username');
    });

    # Expose the browsable types to the layout (navbar + home menu): [type, label, desc].
    $self->hook( before_render => sub {
        my ($c) = @_;
        $c->stash( nav => [ map {
            my $s = Netdot::Mojo::Registry::spec( $_ );
            [ $_, $s->{label}, $s->{desc} ]
        } Netdot::Mojo::Registry::types() ] );
    });
}

1;
