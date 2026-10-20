package Netdot::OAuth;

use Mojo::Base -base, -signatures;

use Netdot;
use Netdot::Model;
use Crypt::URandom;

=head1 NAME

Netdot::OAuth - OAuth2 / OpenID Connect login (e.g. Microsoft Entra ID)

    Engine of the OAuth login, in the same spirit as Netdot::LDAP /
    Netdot::AuthLocal: the web controller (auth#oauth_login) stays thin and
    delegates to this module. Built on Mojolicious::Plugin::OAuth2, which
    Netdot::Mojo registers at startup when NetdotOAuthEnabled=yes and the
    NetdotOAuth* items are complete; the provider's authorize/token endpoints
    and signing keys are then discovered from the OpenID configuration
    (NetdotOAuthWellKnown).

    One route (/auth/oauth) covers the two legs of the authorization-code
    flow:

      initiate        302 to the provider's authorize URL. A random `state`
                      is stored in the session first (the plugin does NOT
                      verify state itself);
      handle_callback state verification against the session (CSRF guard),
                      code -> tokens exchange at the provider's token
                      endpoint, id_token verification against the provider's
                      JWKS, claim -> username mapping (NetdotOAuthUserClaim,
                      default preferred_username; when NetdotOAuthEmailToLDAP
                      is 'yes' the token's email is resolved to the LDAP uid
                      via Netdot::LDAP::uid_from_email), then Person
                      auto-create/auto-fill, like
                      Netdot::LDAP::_upsert_person_from_ldap.

    The web session (username, login_time) is started by the controller from
    the username resolved here.

=head1 SYNOPSIS

    use Netdot::OAuth;

    # Thin controller (auth#oauth_login):
    return _oauth_fail( $c, 'OAuth login is not available (see the server log).' )
        unless Netdot::OAuth::is_configured( $c );
    if ( my $code = $c->param('code'), defined $code && length $code ) {
        Netdot::OAuth::handle_callback( $c )
            ->then( sub { _oauth_success( $c, $_[0] ) } )
            ->catch( sub { _oauth_fail( $c, $_[0] ) } );
    }
    else {
        Netdot::OAuth::initiate( $c );
    }

=cut

=head2 is_configured - Whether the OAuth login can be offered

Arguments:  Controller
Returns:    1 when the plugin is registered (i.e. NetdotOAuthEnabled=yes and
            NetdotOAuthClientID/Secret/WellKnown complete at startup) AND the
            provider's endpoints were resolved at startup; 0 otherwise (the
            login page then answers with a clean error, the startup fetch
            failure is logged by Netdot::Mojo)

=cut

sub is_configured ($c) {
    my $p = eval { $c->oauth2->providers->{netdot} };
    return ( ref $p eq 'HASH' && length( $p->{key} )
             && $p->{authorize_url} && $p->{token_url} ) ? 1 : 0;
}

=head2 redirect_uri - Stable absolute URL of the /auth/oauth callback

Arguments:  Controller
Returns:    Absolute URL announced in the identity provider ("Redirect URI")
Description: Prefers the configured full public URL (WEB_BASE_URL =
             https://host/netdot) so the value is identical whatever the
             proxy does to the scheme; otherwise builds it from the current
             request (dev). The identity provider requires an EXACT match.

=cut

sub redirect_uri ($c) {
    my $wbu = Netdot->config->get('WEB_BASE_URL') // '';
    my $base;
    if ( $wbu =~ m{^https?://} ) {
        $base = $wbu;
    }
    else {
        # url_for() already carries the mount prefix; to_abs adds the scheme
        # + Host header of the current request.
        $base = $c->url_for->to_abs->to_string;
        $base =~ s{/auth/oauth$}{};
    }
    $base =~ s{/+$}{};
    return $base . '/auth/oauth';
}

=head2 initiate - Redirect the browser to the provider's authorize URL

Arguments:  Controller
Returns:    Nothing (302)
Description: Generates a random `state` (Crypt::URandom) stored in the
             session (oauth_state) and redirects to the authorize URL built
             from the provider's authorization_endpoint (client id, scope,
             redirect URI, response_type=code — see the code comment).

=cut

sub initiate ($c) {
    my $state = unpack 'H*', Crypt::URandom::urandom(24);
    $c->session( oauth_state => $state );
    # Build the authorize URL explicitly: the plugin only appends
    # response_type=code for its bundled providers (baked into their
    # hard-coded authorize_url). For well-known-discovered providers
    # (Entra ID) authorize_url is the bare authorization_endpoint, so the
    # redirect would be missing response_type and the provider rejects it
    # (Microsoft: AADSTS900144). The plugin's authorize_query hook cannot
    # be used: Mojo::URL->query(STRING) REPLACES the whole query, dropping
    # the client_id / redirect_uri / state the plugin appended.
    my $p   = $c->oauth2->providers->{netdot};
    my $url = Mojo::URL->new( $p->{authorize_url} );
    $url->query(
        client_id     => $p->{key},
        redirect_uri  => redirect_uri( $c ),
        response_type => 'code',
        scope         => $p->{scope} || 'openid',
        state         => $state,
    );
    $c->redirect_to( $url->to_string );
}

=head2 handle_callback - Process the provider's redirect (code + state)

Arguments:  Controller
Returns:    A Mojo::Promise resolving with the Netdot username (Person
            looked up / created and filled) or rejecting with an error
            message (invalid or missing state, token-exchange failure,
            invalid id_token, no usable claim, LDAP mapping failure)
Description: The `state` returned by the provider is checked against the
             session value (single use: it is deleted first) and the code is
             exchanged for tokens at the provider's token endpoint. The
             id_token is verified against the JWKS fetched at startup, the
             configured claim becomes the Netdot username (email -> LDAP uid
             when NetdotOAuthEmailToLDAP=yes) and the Person is auto-filled.

=cut

sub handle_callback ($c) {
    my $state = $c->param('state') // '';
    my $seen  = $c->session('oauth_state');
    return Mojo::Promise->reject( 'Invalid OAuth state (possible CSRF).' )
        unless defined $seen && length $seen && $state eq $seen;
    delete $c->session->{oauth_state};
    return $c->oauth2->get_token_p( 'netdot' => { redirect_uri => redirect_uri( $c ) } )
        ->then( sub { _finish( $c, $_[0] ) } );
}

# Callback success: verify the signed id_token, map the configured claim to a
# Person username (email -> LDAP uid when enabled), auto-fill the Person.
sub _finish ($c, $res) {
    my $id_token = ref $res eq 'HASH' ? $res->{id_token} : undef;
    return Mojo::Promise->reject( 'No id_token in the provider response.' )
        unless defined $id_token && length $id_token;
    my $p      = $c->oauth2->providers->{netdot};
    my $claims = eval { $p->{jwt}->decode( $id_token ) };
    return Mojo::Promise->reject( "Invalid id_token: $@" ) if $@;
    return Mojo::Promise->reject( 'Malformed id_token.' )
        unless ref $claims eq 'HASH';
    my $claim    = Netdot->config->get('NetdotOAuthUserClaim') || 'preferred_username';
    my $username = $claims->{$claim};
    $username = $claims->{email} unless defined $username && length $username;
    return Mojo::Promise->reject( "No usable username (claim '$claim') in the id_token." )
        unless defined $username && length $username;
    # NetdotOAuthEmailToLDAP: the token claim is the user's email (UPN), but
    # the Netdot username is the LDAP uid -- resolve it (Netdot::LDAP uses the
    # NetdotLDAP* config + the attribute-reader account). Login is refused
    # when the lookup fails (no Person with an email username).
    my $ldap;
    if ( ( Netdot->config->get('NetdotOAuthEmailToLDAP') // '' ) eq 'yes' ) {
        my $email = $username =~ /\@/ ? $username : ( $claims->{email} // '' );
        require Netdot::Mojo::AuthShim;
        my $shim = Netdot::Mojo::AuthShim->new( app => $c->app );
        my $uid  = eval {
            require Netdot::LDAP;
            Netdot::LDAP::uid_from_email( $shim, $email );
        } // 0;
        return Mojo::Promise->reject( "No LDAP user with mail=$email (see the server log)." )
            unless $uid;
        $username = $uid;
        # The id_token carries no reliable name/phone claims (Entra omits
        # given/family_name): fetch the mapped Person attributes
        # (givenName/sn/mail/telephoneNumber by default) from the directory
        # for the Person auto-fill. Best-effort: a lookup failure only
        # skips the LDAP fill (the claims still apply).
        my $a = eval { Netdot::LDAP::attrs_from_email( $shim, $email ) };
        $ldap  = ref $a eq 'HASH' ? $a : {};
    }
    _upsert_person( $c, $claims, $username, $ldap );
    return Mojo::Promise->resolve( $username );
}

# Fill Person fields from the mapped LDAP attributes (EmailToLDAP flow) or
# the id_token claims, mirroring Netdot::LDAP::_upsert_person_from_ldap: look
# up the Person by username, create it if absent (username + lastname seeded;
# Person->insert defaults the user type to 'User'), then fill firstname/
# lastname/email (+ the other mapped columns, e.g. office) from the LDAP
# entry first, the claims second -- ONLY into empty columns (existing values
# are never overwritten). Best-effort: failures are logged but never block a
# successful login.
sub _upsert_person ($c, $claims, $username, $ldap) {
    my $log = $c->app->log;
    # Per-column value sources: the mapped LDAP attributes (when fetched)
    # first, then the JWT claims (Entra omits given/family_name, so the LDAP
    # entry usually wins).
    my %val = (
        firstname => $claims->{given_name},
        lastname  => $claims->{family_name},
        email     => $claims->{email},
    );
    if ( ref $ldap eq 'HASH' ) {
        $val{$_} = $ldap->{$_} for keys %$ldap;
    }
    my $person = eval { Person->search( username => $username )->first };
    if ($@) {
        $log->info( "oauth login: Person lookup FAILED for $username: $@" );
        return;
    }
    my %need;
    if (!$person) {
        $person = eval { Person->insert( { username => $username, lastname => $username } ) };
        if ( $@ ) {
            $log->info( "oauth login: Person auto-create FAILED for $username: $@" );
            return;
        }
        %need = ( map { $_ => 1 } keys %val );
    }
    else {
        $need{$_} = 1 for grep { !defined $person->$_ || $person->$_ eq '' } keys %val;
    }
    return unless %need;
    my %upd;
    $upd{$_} = $val{$_} for grep { defined $val{$_} && length $val{$_} } keys %need;
    return unless %upd;
    eval { $person->update( \%upd ) };
    $log->info( "oauth login: Person field update FAILED for $username: $@" ) if $@;
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
