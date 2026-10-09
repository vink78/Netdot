package Netdot::LDAP;
use strict;
use warnings;
use Net::LDAP;
use Net::LDAP::Constant qw(LDAP_EXTENSION_START_TLS);
use Netdot::AuthLocal;
use Netdot;
use Netdot::Model;

=head1 NAME

Netdot::LDAP - LDAP authentication module for Netdot via Apache2::SiteControl

=head1 SYNOPSIS

In Apache configuration:
    
=over 4

   PerlSetVar SiteControlMethod Netdot::LDAP

   <Location /netdot/NetdotLogin>
      PerlSetVar NetdotLDAPServer  "ldaps://server.local.domain:636"
      PerlSetVar NetdotLDAPServer2 "ldaps://server2.local.domain:636"
      PerlSetVar NetdotLDAPUserDN "uid=<username>"
      PerlSetVar NetdotLDAPSearchBase "ou=people,dc=domain,dc=local"
      PerlSetVar NetdotLDAPVersion "3"
      PerlSetVar NetdotLDAPCACert "/usr/local/ssl/certs/cacert.pem"
      PerlSetVar NetdotLDAPFailToLocal "yes"
      PerlSetVar NetdotLDAPProxy "no"
      PerlSetVar NetdotLDAPProxySearchBaseDN "o=local"
      #Change this to the full path dn and password of the ldap user netdot can use for its search
      PerlSetVar NetdotLDAPProxyUser "cn=ProxyNetdot,ou=infr,ou=domain,o=local"
      PerlSetVar NetdotLDAPProxyPass "ProxyNetdot_password"
   </Location>
    
=back

=head1 DESCRIPTION


Netdot::LDAP uses Net::LDAPS to do the actual authentication of login attempts 
for the SiteControl system.  It performs user authentication against an LDAP 
server over TLS by attempting to bind directly with the username and password 
as entered by the Netdot user.
    
The following variables can be set in httpd.conf:

NetdotLDAPServer
    e.g. ldaps://server.local.domain:[port]
    
NetdotLDAPServer2  
    A backup server in case the first one is not available
    e.g. ldaps://server2.local.domain:[port]
    
NetdotLDAPRequireTLS <yes|no>
    Require TLS session

NetdotLDAPUserDN         
    e.g. uid=<username>.  
    The string "<username>" is replaced with the username supplied at the login prompt
    
NetdotLDAPSearchBase 
    Optional. Will be appended to UserDN.
    e.g. "ou=people,dc=domain,dc=local"

NetdotLDAPCACert
    Optional.  If set, the module will require verification of the server's certificate.
    e.g. "/usr/local/ssl/certs/cacert.pem"

NetdotLDAPVersion
    Optional.  Defaults to "3".

NetdotLDAPFailToLocal <yes|no>
    If LDAP authentication fails, authenticate against local (Netdot DB) credentials.
    
NetdotLDAPProxy <yes|no>
    If the LDAP server, does not allow anonymous binding, and users, reside in more than one branch, Netdot needs to use a initial login/password to connecto to LDAP server and search for the user's branch to be able to contruct the final distinguished name (DN) for the user. Just leave it at "no", if this is not needed.

NetdotLDAPProxySearchBaseDN
    The user will ne searched on the ldap Tree, down this top boundary. It can be the top of the tree, or a more specific brach, as needed.
    e.g.1. "o=MY" 
    e.g.2. "ou=TI,ou=EMP,o=MY"

NetdotLDAPProxyUser 
    Username, used by Netdot to login in the LDAP server. This should be the complete DN of the user.
   e.g. "cn=ProxyNetdot,ou=USR,ou=IFR,o=MY"

NetdotLDAPProxyPass
    Password to login on the LDAP server.
   e.g. "oij98uiu34eiuhs9"
=cut

##########################################################################################

=head2 check_credentials
    
  Arguments:
    Apache Request Object
    Username
    Password
  Returns:
    True or false
  Examples:
    if ( Netdot::LDAP::check_credentials($r, $user, $pass) {...}

=cut

sub check_credentials {
    my ($r, $username, $password) = @_;
    $r->log_error("check_credentials starting");

    unless ( $r && $username && $password ){
	$r->log_error("Netdot::LDAP::check_credentials: Missing required arguments");
	return 0;
    }
    
    my $fail_to_local = ($r->dir_config("NetdotLDAPFailToLocal") eq "yes")? 1 : 0;

    my $user_dn = $r->dir_config("NetdotLDAPUserDN");
    unless ( $user_dn ){
	$r->log_error("Netdot::LDAP::check_credentials: ERROR: DN is not set. ".
		      "Use NetdotLDAPUserDN in httpd.conf");
	return 0;
    }

    $user_dn =~ s/<username>/$username/;
    
    my $base_dn = $r->dir_config("NetdotLDAPSearchBase");
    if ( $base_dn ){
	$user_dn .= ",$base_dn";
    }

    my $ldap;
    unless ( $ldap = Netdot::LDAP::_connect($r) ){
	if  ( $fail_to_local ){
	    $r->log_error("Netdot::LDAP::check_credentials: Trying local auth");
	    return Netdot::AuthLocal::check_credentials($r, $username, $password);
	}else{
	    return 0;
	}
    }
    my $use_proxy = $r->dir_config("NetdotLDAPProxy");

    if ( lc $use_proxy eq "yes" )
        {
           my $proxy_user = $r->dir_config("NetdotLDAPProxyUser");
           my $proxy_pass = $r->dir_config("NetdotLDAPProxyPass");
           my $proxy_base = $r->dir_config("NetdotLDAPProxySearchBaseDN");
           my $proxyauth = $ldap->bind($proxy_user, password=>$proxy_pass);
           my $result = $ldap->search(
                                        base => $proxy_base,
                                        scope => 'subtree',
                                        filter => '(cn='.$username.')',
                                        attrs => ['dn']
                                );
           if ($result->count() == 1) {
                $user_dn = $result->entry(0)->dn();
                $r->log_error("User Found base_dn=".$proxy_base." filter=(cn=".$username.") user_dn=".$user_dn);
           } else {
                $r->log_error("ERROR LDAP proxy search: ".$result->count()." results filter (cn=".$username.") base='".$proxy_base."'");
                        if  ( $fail_to_local ){
                                $r->log_error("Netdot::LDAP::check_credentials: Trying local auth");
                                return Netdot::AuthLocal::check_credentials($r, $username, $password);
                                }
                 }
        }




    # start TLS
    my $scheme = $ldap->scheme();
    my $dse = $ldap->root_dse();
    my $does_support_tls = $dse->supported_extension(LDAP_EXTENSION_START_TLS);
    my $require_tls = ($r->dir_config("NetdotLDAPRequireTLS") eq "yes")? 1 : 0;
    if ( $scheme eq "ldap" && ( $require_tls ) ) { #|| $does_support_tls ) ) {
        my $tls = $ldap->start_tls();
        if ( $tls->code ) {
            if ( $require_tls ) {
                $r->log_error("Netdot::LDAP::check_credentials: Failed to start TLS".
			      ", config requires TLS, cannot continue: " . $tls->error);
                return 0;
            } elsif ( $does_support_tls ) {
                $r->warn("Netdot::LDAP::check_credentials: Failed to start TLS ".
				"although server advertises TLS support: " . $tls->error);
            }
        }
    }

    my $auth = $ldap->bind($user_dn, password=>$password);
    if ( $auth->code ) {
	$r->log_error("Netdot::LDAP::check_credentials: User $username failed LDAP authentication: ".
		      $auth->error);
	if  ( $fail_to_local ){
	    $r->log_error("Netdot::LDAP::check_credentials: Trying local auth");
	    return Netdot::AuthLocal::check_credentials($r, $username, $password);
	}else{
	    return 0;
	}
    }else{
	# Authentication OK. Auto-populate the Person from the LDAP entry
	# (givenName/sn/mail/telephoneNumber -> firstname/lastname/email/office),
	# per the NetdotLDAPAttrMap config. Best-effort: any failure here is
	# swallowed so it never blocks a successful login.
	eval { _upsert_person_from_ldap( $r, $ldap, $username, $user_dn ) };
	return 1;
    }
}

##########################################################################################
# _connect - Connect to an available LDAP server
#    
#   Arguments:
#     Apache Request Object
#   Returns:
#     Net::LDAP object or 0
#   Examples:
#     my $ldap = Netdot::LDAP::_connect($r);
#
sub _connect {
    my ($r) = @_;

    my (@servers, $server1);

    $server1 = $r->dir_config("NetdotLDAPServer");
    unless ( $server1 ){
	$r->log_error("Netdot::LDAP::check_credentials: WARNING: LDAP server is not set. ".
		      "Set NetdotLDAPServer in httpd.conf");
	$server1 = "ldaps://localhost";
    }
    push @servers, $server1;

    # This is optional
    if ( my $server2 = $r->dir_config("NetdotLDAPServer2") ){
	push @servers, $server2;
    }

    my $version = $r->dir_config("NetdotLDAPVersion") || 3;
    my %args = (version=>$version, verify=>'none');
    my $cafile = $r->dir_config("NetdotLDAPCACert");
    if ( $cafile ){
	$args{cafile} = $cafile;
	$args{verify} = 'require';
    }
    
    foreach my $server ( @servers ){
	my $ldap = Net::LDAP->new($server, %args);
	if ( $ldap ) {
	    return $ldap;
	}else{
	    $r->log_error("Netdot::LDAP::check_credentials: ERROR: Could not contact ".
			  "LDAP server $server: $@");
	}
    }

    return 0;
}


############################################################################

=head2 _ldap_attr_map - Configured LDAP-attribute -> Person-column map

Reads the "NetdotLDAPAttrMap" config item -- a hash of LDAP attribute => Person
column, e.g.:

    NetdotLDAPAttrMap => { 'givenName' => 'firstname', 'sn' => 'lastname',
                           'mail' => 'email', 'telephoneNumber' => 'office' }

Returns a list of [ldap_attr, person_field] pairs. A Person-column value is only
trusted if it is a real column of the Person table. Falls back to the default map
when the key is absent.

=cut

sub _ldap_attr_map {
    my ($r) = @_;
    my $map = eval { $r->dir_config('NetdotLDAPAttrMap') };
    $map = { 'givenName' => 'firstname', 'sn' => 'lastname', 'mail' => 'email',
             'telephoneNumber' => 'office' }
        unless ref $map eq 'HASH';
    my %valid;
    eval { %valid = map { $_ => 1 } Person->columns };
    my @pairs;
    for my $ldap_attr ( sort keys %$map ) {
        my $pcol = $map->{$ldap_attr};
        next unless defined $pcol && length $pcol;
        push @pairs, [ $ldap_attr, $pcol ] if $valid{$pcol};
    }
    return @pairs;
}

############################################################################

=head2 _upsert_person_from_ldap - Fill Person fields from the LDAP entry

After a successful LDAP bind, read the mapped attributes from the user's LDAP
entry and apply them to the Person matching $username. The Person is created
(if absent) with only its username, then the mapped values are filled in --
ONLY into empty columns (existing values are never overwritten). Any failure
returns 0 and is ignored by the caller, so it cannot break login.

=cut

sub _upsert_person_from_ldap {
    my ( $r, $ldap, $username, $user_dn ) = @_;
    my @pairs = _ldap_attr_map( $r );
    $r->log_error( "netdot-auth LDAP: no attr map configured, skip auto-fill" ) unless @pairs;
    return 0 unless @pairs;
    my %col2attr = map { $_->[1] => $_->[0] } @pairs;

    # Conservative mode: look up the Person FIRST and skip the LDAP fetch
    # entirely when every mapped field is already set (no point hitting LDAP).
    my $person = eval { Person->search( username => $username )->first };
    my $is_new = 0;
    unless ( $person ) {
        # Person->insert requires lastname (Person.pm); seed it with the username
        # (legacy get_user_person behaviour) -- sn overwrites it below if present.
        $person = eval { Person->insert( { username => $username, lastname => $username } ) };
        $is_new = 1 if $person;
        return 0 unless $person;
    }

    # Mapped Person columns still needing a value: all of them for a brand-new
    # Person, otherwise only the ones left empty (never overwrite existing data).
    my %need = $is_new ? ( map { $_->[1] => 1 } @pairs ) : ();
    unless ( $is_new ) {
        for my $p (@pairs) {
            my $cur = eval { $person-> $p->[1] };
            $need{ $p->[1] } = 1 if !defined $cur || $cur eq '';
        }
    }
    unless ( %need ) {
        $r->log_error( "netdot-auth LDAP: all mapped Person fields already set for $username; skipping LDAP fetch" );
        return 1;
    }

    # The user's own bound connection cannot read its own attributes (self-bind
    # ACLs), so fetch via a dedicated reader account when configured.
    my $reader_dn = $r->dir_config( 'NetdotLDAPAttrReaderDN' );
    my $reader_pw = $r->dir_config( 'NetdotLDAPAttrReaderPass' );
    my $reader;
    if ( defined $reader_dn && length $reader_dn && defined $reader_pw && length $reader_pw ) {
        $reader = _connect( $r );
        my $rb  = $reader && eval { $reader->bind( $reader_dn, password => $reader_pw ) };
        unless ( $reader && $rb && ! $rb->code ) {
            $r->log_error( "netdot-auth LDAP: attr-reader bind failed for $reader_dn: ",
                           ( $rb ? $rb->code . " (" . $rb->error . ")" : "no connection" ) );
            return 0;
        }
    }
    my $conn = $reader // $ldap;

    my $res = eval {
        $conn->search(
            base    => $user_dn,
            scope   => 'subtree',
            filter  => '(objectClass=*)',
            attrs   => [ map { $_->[0] } @pairs ],
        );
    };
    if ( my $e = $@ ) {
        $r->log_error( "netdot-auth LDAP: attr fetch error for $username: $e" );
        return 0;
    }
    unless ( $res && $res->code() == 0 && $res->count() == 1 ) {
        $r->log_error( "netdot-auth LDAP: attr search returned ",
                       ( $res ? $res->code() . " (" . $res->error() . ")" : "no result" ),
                       " for $username; skip auto-fill" );
        return 0;
    }

    # Net::LDAP::Entry: ->attributes returns attribute NAMES (list context);
    # ->get_value($name) returns that attribute's values.
    my %attrs;
    my $entry = $res->entry(0);
    for my $key ( $entry->attributes ) {
        my @vals = $entry->get_value( $key );
        $attrs{ lc $key } = join( ', ', @vals );
    }

    # Fill only the columns still empty (conservative) with the LDAP value.
    my %upd;
    for my $col ( keys %need ) {
        my $val = $attrs{ lc $col2attr{$col} };
        $upd{$col} = $val if defined $val && length $val;
    }
    if ( !%upd ) {
        $r->log_error( "netdot-auth LDAP: no LDAP value for the empty Person field(s) ",
                       join( ',', keys %need ), " of $username" );
        return 0;
    }

    eval { $person->update( \%upd ) };
    if ( my $e = $@ ) {
        $r->log_error( "netdot-auth LDAP: update FAILED for $username: $e" );
        return 0;
    }
    $r->log_error( "netdot-auth LDAP: filled Person field(s) ",
                   join( ',', keys %upd ), " for $username" );
    return 1;
}

# Make sure to return 1
1;


=head1 SEE ALSO

Apache2::SiteControl

=head1 AUTHORS

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 University of Oregon, all rights reserved.

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


