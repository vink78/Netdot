package Netdot::Mojo;

use Mojo::Base 'Mojolicious', -signatures;

use File::Basename qw(dirname);
use Cwd          qw(abs_path);

use Netdot::Model;    # loads Netdot (config + meta) and connects to the DB
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;

sub startup ($self) {

    # ---- Template path: project's htdocs/ convention (like Mason) ----
    # __FILE__ = <root>/lib/Netdot/Mojo.pm  =>  <root> = 3 dirname
    my $root   = abs_path( dirname( dirname( dirname( __FILE__ ) ) ) );
    my $htdocs = "$root/htdocs";
    push @{ $self->renderer->paths }, $htdocs;
    push @{ $self->static->paths },   $htdocs;    # static assets (css, img, js)

    # ---- Sessions / cookies ----
    $self->secrets([ $ENV{NETDOT_MOCK} // 'netdot-mojo-dev-change-me' ]);

    # ---- Current user + permissions (mirrors the old Apache2::SiteControl manager) ----
    # current_person: the logged-in Person (resolved from the session username, cached per request).
    $self->helper(current_person => sub ($c) {
        my $un = $c->session('username') or return undef;
        return $c->stash('__person') if defined $c->stash('__person');
        my $p = eval { Person->search(username => $un)->first };
        $c->stash('__person' => $p);
        return $p;
    });
    # user_type: 'Admin' | 'Operator' | 'User' | '' (not logged in / unset).
    $self->helper(user_type => sub ($c) {
        my $p = $c->current_person or return '';
        return Netdot::Mojo::Permissions->user_type($p);
    });
    # perm($action, $resource): is the current user allowed? (allowed_objects cached per request)
    # (named "perm" to avoid clashing with UNIVERSAL::can, which Mojolicious uses for dispatch)
    $self->helper(perm => sub ($c, $action, $resource) {
        my $p = $c->current_person or return 0;
        my $access;
        if ( Netdot::Mojo::Permissions->user_type($p) ne 'Admin' ) {
            $access = $c->stash('__allowed');
            if ( !defined $access ) {
                $access        = Netdot::Mojo::Permissions->allowed_objects($p);
                $c->stash('__allowed', $access);
            }
        }
        return Netdot::Mojo::Permissions->can($p, $action, $resource, $access);
    });

    # ---- Routes ----
    my $r = $self->routes;
    $r->get('/')->to('home#index')->name('home');

    # Per browsable type: list, search, CSV export, batch delete, then detail.
    # (see Registry). search/csv/delete are declared before :id so they win over
    # the id placeholder. Types with custom search/detail logic get a dedicated
    # controller; the rest use the generic ones.
    my %show_ctrl   = ( ipblock => 'ipblock', rr => 'rr', physaddr => 'physaddr', interface => 'interface', device => 'device' );
    my %search_ctrl = ( ipblock => 'ipblock', rr => 'rr', physaddr => 'physaddr' );
    for my $t ( Netdot::Mojo::Registry::types() ) {
        $r->get("/management/$t")->to('browse#list', type => $t)->name("${t}_list");
        if ( my $sc = $search_ctrl{$t} ) {
            $r->get("/management/$t/search")->to("$sc#search", type => $t)->name("${t}_search");
        }
        $r->get("/management/$t/csv")->to('browse#csv', type => $t)->name("${t}_csv");
        $r->post("/management/$t/delete")->to('browse#delete', type => $t)->name("${t}_delete");
        my $ctrl = $show_ctrl{$t} // 'show';
        $r->get("/management/$t/:id")->to("${ctrl}#show", type => $t)->name("${t}_show");
    }
    # Interface sub-views: FDB / ARP entries at a given timestamp (ports of
    # i_fdb.html / i_arp.html).
    $r->get('/management/interface/:id/fdb')->to('interface#fdb')->name('interface_fdb');
    $r->get('/management/interface/:id/arp')->to('interface#arp')->name('interface_arp');
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
        # Nav only lists the main browsable types; "nav => 0" types (e.g. Product)
        # are routable/linkable but hidden from the nav and home menu.
        $c->stash( nav => [ map {
            my $s = Netdot::Mojo::Registry::spec( $_ );
            [ $_, $s->{label}, $s->{desc} ]
        } grep { ( Netdot::Mojo::Registry::spec( $_ )->{nav} // 1 ) }
                Netdot::Mojo::Registry::types() ] );
    });
}

1;
