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

    # ---- Public path prefix (base path) ----
    # WEB_BASE_URL is the prefix the app is mounted under (dev + prod). It may be
    # a bare path ('/netdot') or a full URL (https://host/netdot); keep the path
    # part. '' = served at the domain root.
    my $wbu  = eval { Netdot->config->get('WEB_BASE_URL') };
    $wbu     = '' unless defined $wbu && !ref $wbu;
    my $base = $wbu;
    $base    =~ s{^https?://[^/]+}{};   # full URL -> keep only the path
    $base    =~ s{/+$}{};               # strip trailing slash(es)
    $base    = '' if $base eq '/';
    # Templates use web_prefix() to prefix the few hard-coded root asset/route
    # links (url_for() already carries the prefix because routes are mounted under
    # $base). set_uri() prefixes any internal root-absolute path (see Registry).
    $self->helper( web_prefix => sub { $base } );
    $self->helper( set_uri    => sub ($c, $uri) { Netdot::Mojo::Registry::set_uri( $uri ) } );

    # ---- Logging: info by default (captures the ACCESS/LOGIN lines below);
    # override with MOJO_LOG_LEVEL=debug|trace to troubleshoot. ----
    $self->log->level( $ENV{MOJO_LOG_LEVEL} // 'info' );

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

    # deny_unless($action, $resource): render a 403 and return 1 if the current
    # user may not $action $resource; otherwise return 0 (proceed).
    $self->helper(deny_unless => sub ($c, $action, $resource) {
        my $p = $c->current_person;
        return 0 if $p && Netdot::Mojo::Permissions->can($p, $action, $resource);
        $c->render(
            template => 'error_403',
            layout   => 'default',
            title    => 'Access denied',
            status   => 403,
        );
        return 1;
    });

    # Brand the generic Mojolicious error pages with Netdot. The framework's
    # default handlers render its own "mojo/debug"/"mojo/not_found" templates;
    # override the HTML variants to render our error_<code> pages instead.
    #
    # The JSON API is JSON-aware end to end: ANY path under /api answers with
    # JSON (404/405/500), whatever the Accept header, so /api behaves like a
    # pure REST API even for HTML clients. Non-API paths keep the branded HTML
    # error pages; the JSON variants share the same {error,path} shape.
    $self->helper( api_json_err => sub ( $c, $code, $msg ) {
        $c->render( json => { error => $msg, path => $c->req->url->path }, status => $code );
    } );
    my $is_api = sub { $_[0]->req->url->path =~ m{^\Q$base\E/api(?:/|$)} };

    $self->helper('reply.html_not_found' => sub ($c) {
        return $c->api_json_err( 404, 'Not found' ) if $is_api->($c);
        $c->render( template => 'error_404', layout => 'default', title => 'Page not found (404)', status => 404 );
    });
    $self->helper('reply.json_not_found' => sub ($c) {
        $c->api_json_err( 404, 'Not found' );
    });
    $self->helper(
        'reply.html_method_not_allowed' => sub ($c) {
            return $c->api_json_err( 405, 'Method not allowed' ) if $is_api->($c);
            $c->render( text => 'Method not allowed', status => 405 );
        }
    );
    $self->helper('reply.json_method_not_allowed' => sub ($c) {
        $c->api_json_err( 405, 'Method not allowed' );
    });
    $self->helper('reply.html_exception' => sub ( $c, $e ) {
        $c->app->log->error( ref $e ? $e->inspect : "unhandled exception: $e" );
        return $c->api_json_err( 500, 'Internal server error' ) if $is_api->($c);
        $c->stash( exception => $e );
        $c->render( template => 'error_500', layout => 'default', title => 'Internal Server Error (500)', status => 500 );
    });
    $self->helper('reply.json_exception' => sub ( $c, $e ) {
        $c->app->log->error( ref $e ? $e->inspect : "unhandled exception: $e" );
        $c->api_json_err( 500, 'Internal server error' );
    });

    # ---- Routes ----
    # Mount every route under the public prefix ($base) when set, so url_for()
    # (and thus every generated link) carries it. With no prefix, routes are at
    # the domain root as before.
    my $r = $base ne '' ? $self->routes->under( $base ) : $self->routes;
    $r->get('/')->to('home#index')->name('home');

    # Per browsable type: list, search, CSV export, batch delete, then detail.
    # (see Registry). search/csv/delete are declared before :id so they win over
    # the id placeholder. Types with custom search/detail logic get a dedicated
    # controller; the rest use the generic ones.
    my %show_ctrl   = ( ipblock => 'ipblock', rr => 'rr', physaddr => 'physaddr', interface => 'interface', device => 'device', zone => 'zone', contactlist => 'contactlist', closet => 'closet' );
    my %search_ctrl = ( ipblock => 'ipblock', rr => 'rr', physaddr => 'physaddr' );
    # Types with a dedicated LANDING page (not the generic list): vlan shows the
    # VLAN Groups + Ungrouped VLANs view (port of the original vlan.html).
    my %list_ctrl = ( vlan => 'vlan' );
    for my $t ( Netdot::Mojo::Registry::types() ) {
        my $lc = $list_ctrl{$t} // 'browse';
        $r->get("/management/$t")->to("${lc}#list", type => $t)->name("${t}_list");
        # Per-type search: dedicated controllers for the rich multi-field ones
        # (ipblock/rr/physaddr); a generic free-text search (browse#search) for
        # every other type.
        my $sc = $search_ctrl{$t};
        $r->get("/management/$t/search")
           ->to( $sc ? "$sc#search" : 'browse#search', type => $t )
           ->name("${t}_search");
        $r->get("/management/$t/csv")->to('browse#csv', type => $t)->name("${t}_csv");
        $r->post("/management/$t/delete")->to('browse#delete', type => $t)->name("${t}_delete");
        my $ctrl = $show_ctrl{$t} // 'show';
        $r->get("/management/$t/:id")->to("${ctrl}#show", type => $t)->name("${t}_show");
    }
    # Interface sub-views: FDB / ARP entries at a given timestamp (ports of
    # i_fdb.html / i_arp.html).
    # Picture binaries (read-only): serve the bindata BLOB inline so a picture's
    # label links straight to the image. closet#picture handles ClosetPicture;
    # show#picture handles the SitePicture / FloorPicture equivalents.
    $r->get('/management/closetpicture/:id')->to('closet#picture')->name('closet_picture');
    $r->get('/management/sitepicture/:id')->to('show#picture', type => 'sitepicture')->name('site_picture');
    $r->get('/management/floorpicture/:id')->to('show#picture', type => 'floorpicture')->name('floor_picture');
    $r->get('/management/interface/:id/fdb')->to('interface#fdb')->name('interface_fdb');
    $r->get('/management/interface/:id/arp')->to('interface#arp')->name('interface_arp');
    # Reports (Admin + Operator; see Reports controller guard).
    $r->get('/reports')->to('reports#index')->name('reports_index');
    for my $rep ( qw(device asset ip macs topology pollstats poll database custom ipbat security hinfo usedby) ) {
        $r->get("/reports/$rep")->to("reports#$rep")->name("reports_${rep}");
    }
    # Export 3rd-party configs (BIND/NAMED/RFC952/DHCPD); write-rights (Permissions::can_export).
    # GET renders the form; POST runs the requested exports and shows the captured log.
    $r->any('/export')->to('export#index')->name('export');

    # Advanced: changelog (audit log).
    $r->get('/changelog')->to('advanced#changelog')->name('changelog');
    # Global search (IP / MAC / hostname detection).
    $r->get('/search')->to('search#index')->name('search');
    # Help: manual + database schema (Admin + Operator; see Help controller).
    $r->get('/help')->to('help#index')->name('help_index');
    $r->get('/help/manual')->to('help#manual')->name('help_manual');
    $r->get('/help/database')->to('help#database')->name('help_database');
    $r->get('/help/database/graph')->to('help#graph')->name('help_graph');

    # ---- JSON API (port of the legacy /rest handlers + Netdot::REST) ----
    # Specific / static endpoints first (so they win over the generic
    # /api/:table placeholders), then the generic resource router.
    # Bare /api -> JSON index (a "real API" landing point).
    $r->any('/api')->to('api#root')->name('api_index');
    $r->get('/api/openapi.yaml')->to('api#spec')->name('api_spec');
    $r->get('/api/docs')->to('api#docs')->name('api_docs');
    $r->get('/api/devinfo')->to('api#devinfo');
    $r->get('/api/host_contacts')->to('api#host_contacts');
    $r->get('/api/ipattr')->to('api#ipattr');
    $r->any('/api/host')->to('api#host');
    $r->any('/api/host_like')->to('api#host_like');
    $r->post('/api/updatedev')->to('api#updatedev');
    $r->any('/api/:table')->to('api#generic');
    $r->any('/api/:table/:id')->to('api#generic');

    $r->get('/login')->to('auth#login_form')->name('login');
    $r->post('/login')->to('auth#login_submit');
    $r->get('/logout')->to('auth#logout')->name('logout');

    # Static assets under the prefix (css, img, java_script). The default static
    # fallback only serves the raw request path, so with a prefix we serve these
    # explicitly. Guarded: a missing file -> not_found (reply->static would croak).
    for my $d (qw(css img java_script)) {
        $r->get( "$d/*file" )->to(
            cb => sub ($c) {
                my $file = "$d/" . $c->stash('file');
                return $c->reply->not_found unless $c->app->static->file($file);
                $c->reply->static($file);
            }
        );
    }

    # ---- Authentication: redirect (302) unauthenticated requests to /login ----
    # Public paths (login/logout and static assets) are exempt.
    $self->hook( before_dispatch => sub {
        my ($c)  = @_;
        my $path = $c->req->url->path;
        return if $path eq "$base/login" || $path eq "$base/logout";
        return if $path =~ m{^\Q$base\E(?:/(?:css|img|java_script))(?:/|$)};
        return if $path eq "$base/favicon.ico";
        # Set REMOTE_USER from the session for the audit trail (Model::_audit
        # reads it; the old Apache layer provided it). Covers both the HTML app
        # and the JSON API, which both authenticate via the session.
        $ENV{REMOTE_USER} = $c->session('username') if $c->session('username');
        # The JSON API handles auth itself (JSON 401) rather than the HTML login
        # redirect.
        return if $path =~ m{^\Q$base\E/api(?:/|$)};
        $c->redirect_to( $c->url_for('login') ) unless $c->session('username');
    });

    # ---- Access log: who (IP + user) accessed which function ----
    # One line per request (static assets + favicon skipped), via the app logger
    # (-> journald under systemd). Read:  journalctl -u netdot | grep ACCESS
    #   ACCESS <ip> <user> <method> <controller>#<action> <path> <status>
    $self->hook( after_dispatch => sub ($c) {
        my $path = $c->req->url->path;
        return if $path =~ m{^\Q$base\E(?:/(?:css|img|java_script))(?:/|$)};
        return if $path eq "$base/favicon.ico";
        my $ip   = $c->tx->remote_address  // '-';
        my $user = $c->session('username') // '-';
        my $fn   = defined $c->stash('controller')
                 ? $c->stash('controller') . '#' . $c->stash('action')
                 : $path;
        my $method = $c->req->method;
        my $code   = $c->res->code // '-';
        $c->app->log->info( "ACCESS $ip $user $method $fn $path $code" );
    });

    # Build the 5-section navigation (Registry::menu), filtering each sub-menu by
    # what the current user may view: Admin/Operator see every type; a User sees
    # only the types they hold 'view' on (none by default). Sections with no
    # visible sub-menu are hidden. allowed_objects is fetched once per render.
    $self->hook( before_render => sub {
        my ($c)     = @_;
        my $person  = $c->current_person;
        my $utype   = Netdot::Mojo::Permissions->user_type( $person );
        my $access;
        $access = Netdot::Mojo::Permissions->allowed_objects( $person )
            unless $utype eq 'Admin' || $utype eq 'Operator';

        my @sections;
        for my $sec ( Netdot::Mojo::Registry::menu() ) {
            my ( $key, $meta ) = @$sec;

            # Reports: fixed sub-menu (Registry::reports_menu), Admin + Operator only
            # (the original gates it with the access_section permission).
            if ( $key eq 'reports' ) {
                next unless $utype eq 'Admin' || $utype eq 'Operator';
                my @items = map { { label => $_->{label}, url => $base . "/reports/$_->{key}" } }
                            Netdot::Mojo::Registry::reports_menu();
                next unless @items;
                push @sections, { key => $key, title => $meta->{title}, url => $items[0]{url}, items => \@items };
                next;
            }

            # Export: write-rights section (single "Configurations" action). Shown only
            # to people who hold write rights on DNS records (Permissions::can_export).
            if ( $key eq 'export' ) {
                next unless Netdot::Mojo::Permissions->can_export( $person );
                my @items = ( { label => 'Configurations', url => $base . '/export' } );
                push @sections, { key => $key, title => $meta->{title}, url => $items[0]{url}, items => \@items };
                next;
            }

            # Advanced: changelog (audit log). Single item, all users.
            if ( $key eq 'generic' ) {
                my @items = ( { label => 'Changelog', url => $base . '/changelog' } );
                push @sections, { key => $key, title => $meta->{title}, url => $items[0]{url}, items => \@items };
                next;
            }

            # Help: manual + database schema. Admin + Operator only.
            if ( $key eq 'help' ) {
                next unless $utype eq 'Admin' || $utype eq 'Operator';
                my @items = (
                    { label => 'User Manual',       url => $base . '/help/manual' },
                    { label => 'Database Schema',   url => $base . '/help/database' },
                    { label => 'Database Graph',    url => $base . '/help/database/graph' },
                );
                push @sections, { key => $key, title => $meta->{title}, url => $items[0]{url}, items => \@items };
                next;
            }

            my @items;
            for my $t ( @{ $meta->{types} } ) {
                my $spec = Netdot::Mojo::Registry::spec( $t ) or next;
                next unless ( $spec->{nav} // 1 );
                my $visible = ( $utype eq 'Admin' || $utype eq 'Operator' )
                            ? 1
                            : Netdot::Mojo::Permissions::has_action_on( $spec->{class}, $access, 'view' );
                next unless $visible;
                my $label = Netdot::Mojo::Registry::nav_label( $t ) // $spec->{label};
                push @items, { type => $t, label => $label, url => $c->url_for( "${t}_list" ) };
            }
            next unless @items;
            push @sections, {
                key   => $key,
                title => $meta->{title},
                url   => $items[0]{url},
                items => \@items,
            };
        }
        $c->stash( nav => \@sections );
    });
}

1;
