package Netdot::Mojo::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Mojo::AuthShim;

sub login_form ($c) {
    $c->render(
        template => 'login',
        layout   => 'default',
        title    => 'Login',
        hide_nav => 1,
        is_login => 1,
        username => ''
    );
}

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