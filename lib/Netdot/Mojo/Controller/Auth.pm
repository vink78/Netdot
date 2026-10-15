package Netdot::Mojo::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::OAuth;
use Netdot::Mojo::AuthShim;

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Auth - Login / logout (web session)

    Login via Netdot::LDAP (with the Netdot::Mojo::AuthShim emulating the
    Apache request object); a successful login sets the session (username,
    login_time) through Netdot::Mojo::Sessions.

=head1 SYNOPSIS

    # Wired in Netdot::Mojo:
    #   ->get('/login')->to('auth#login_form')
    #   ->post('/login')->to('auth#login_submit')
    #   ->get('/logout')->to('auth#logout')
    #   ->get('/auth/oauth')->to('auth#oauth_login')

=head1 INSTANCE METHODS

=cut

=head2 login_form - Render the login page

Arguments:  Controller
Returns:    Renders the login template (navigation hidden, no error)
Description: When OAuth login is enabled and configured (see auth#oauth_login),
             the template also gets the provider button (label + URL).

=cut

sub login_form ($c) {
    # OAuth button: shown only when the feature is enabled AND the plugin is
    # registered (fully configured — Netdot::Mojo registers it at startup).
    # The plugin is looked up at request time: a disabled deployment has no
    # `oauth2` helper at all.
    my $oauth;
    if ( ( Netdot->config->get('NetdotOAuthEnabled') // '' ) eq 'yes'
         && eval { defined $c->oauth2->providers->{netdot}{key} } ) {
        $oauth = {
            label => ( Netdot->config->get('NetdotOAuthLabel') || 'OAuth' ),
            url   => $c->url_for('oauth_login')->to_string,
        };
    }
    $c->render(
        template => 'login',
        layout   => 'default',
        title    => 'Login',
        hide_nav => 1,
        is_login => 1,
        username => '',
        oauth    => $oauth,
    );
}

=head2 login_submit - Authenticate and start a web session

Arguments:  Controller (params: username, password)
Returns:    Nothing; on success sets the session (username, login_time) and
            redirects to home, on failure re-renders the login page with an
            error message
Description: Tries Netdot::LDAP::check_credentials (which itself falls back to
            local auth when NetdotLDAPFailToLocal=yes); when the LDAP module
            is unavailable (Net::LDAP missing) falls back directly to
            Netdot::AuthLocal::check_credentials. Every attempt is logged with
            the client IP (X-Forwarded-For honored only from trusted proxies).

=cut

sub login_submit ($c) {
    my $user = $c->param('username') // '';
    my $pass = $c->param('password') // '';

    my $shim = Netdot::Mojo::AuthShim->new( app => $c->app );

    # LDAP (Netdot::LDAP itself falls back to local auth if NetdotLDAPFailToLocal=yes).
    my $ok = eval {
        require Netdot::LDAP;
        Netdot::LDAP::check_credentials( $shim, $user, $pass );
    };

    # Fallback: if the LDAP module is unavailable (Net::LDAP missing), direct local auth.
    if ( !$ok && ( $@ || '' ) =~ m{Can't locate Net/LDAP} ) {
        $ok = eval {
            require Netdot::AuthLocal;
            Netdot::AuthLocal::check_credentials( $shim, $user, $pass );
        };
    }

    # Log every login attempt (IP + user + outcome) for the audit trail.
    # client_ip honors X-Forwarded-For only from trusted proxies (see Netdot::Mojo).
    my $ip = $c->client_ip;
    $c->app->log->info( "LOGIN $ip user=$user " . ( $ok ? 'success' : 'FAILED' ) );

    if ($ok) {
        $c->session( username => $user, login_time => time );
        $c->redirect_to( $c->url_for('home') );
    }
    else {
        $c->render(
            template => 'login',
            layout   => 'default',
            title    => 'Login',
            hide_nav => 1,
            is_login => 1,
            username => $user,
            error    => 'Authentication failed',
        );
    }
}

=head2 oauth_login - OAuth2 (OpenID Connect) login: initiate and callback

Arguments:  Controller (params: code + state on the callback leg)
Returns:    Nothing; on the initiate leg a 302 to the provider's authorize
            URL, on the callback leg the session (username, login_time) is
            set and the user is redirected to home — or the login page is
            re-rendered with an error
Description: Thin glue around Netdot::OAuth (the engine, same model as
             Netdot::LDAP / Netdot::AuthLocal): when the feature is not
             configured (or the provider was unreachable at startup) the
             login page shows a clean error; otherwise, without a `code`
             param, Netdot::OAuth::initiate redirects the browser to the
             provider (random state stored in the session), and with one,
             Netdot::OAuth::handle_callback verifies the state, exchanges the
             code, checks the signed id_token and resolves the username
             (claim, email -> LDAP uid when NetdotOAuthEmailToLDAP=yes,
             Person auto-filled). On success the audit line is logged (same
             shape as login_submit, with an "(oauth)" marker), the session
             is started and the user is redirected to home.

=cut

sub oauth_login ($c) {
    return _oauth_fail( $c, 'OAuth login is not available (see the server log).' )
        unless Netdot::OAuth::is_configured( $c );
    my $code = $c->param('code');
    if ( defined $code && length $code ) {
        Netdot::OAuth::handle_callback( $c )
            ->then( sub { _oauth_success( $c, $_[0] ) } )
            ->catch( sub { _oauth_fail( $c, $_[0] // 'OAuth token exchange failed' ) } );
        return;
    }
    Netdot::OAuth::initiate( $c );
}

# Callback success: audit trail + web session (the username was resolved and
# the Person auto-filled by Netdot::OAuth::handle_callback).
sub _oauth_success ($c, $username) {
    my $ip = $c->client_ip;
    $c->app->log->info( "LOGIN $ip user=$username success (oauth)" );
    $c->session( username => $username, login_time => time );
    $c->redirect_to( $c->url_for('home') );
}

# OAuth failure: log + re-render the login page with the error message.
sub _oauth_fail ($c, $msg) {
    my $ip = $c->client_ip;
    $c->app->log->info( "LOGIN $ip OAuth FAILED: $msg" );
    $c->render(
        template => 'login',
        layout   => 'default',
        title    => 'Login',
        hide_nav => 1,
        is_login => 1,
        username => '',
        error    => $msg,
    );
}

=head2 logout - Expire the session and redirect to the login page

Arguments:  Controller
Returns:    Nothing (302 to login)

=cut

sub logout ($c) {
    $c->session( expires => 1 );
    $c->redirect_to( $c->url_for('login') );
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