package Netdot::Mojo::Controller::Auth;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Mojo::AuthShim;

sub login_form ($c) {
    $c->render(
        template => 'login',
        layout   => 'default',
        title    => 'Login',
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

    if ($ok) {
        $c->session( username => $user, login_time => time );
        $c->redirect_to( $c->url_for('home') );
    }
    else {
        $c->render(
            template => 'login',
            layout   => 'default',
            title    => 'Login',
            username => $user,
            error    => 'Authentication failed',
        );
    }
}

sub logout ($c) {
    $c->session( expires => 1 );
    $c->redirect_to( $c->url_for('login') );
}

1;
