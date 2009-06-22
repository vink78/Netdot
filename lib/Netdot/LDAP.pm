package Netdot::LDAP;
use strict;
use warnings;
use Net::LDAP;
use Netdot::AuthLocal;

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

NetdotLDAPFailToLocal
    If LDAP authentication fails, authenticate against local (Netdot DB) credentials.
    
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
    
    unless ( $r && $username && $password ){
	$r->log_error("Netdot::LDAP::check_credentials: Missing required arguments");
	return 0;
    }
    
    my $fail_to_local = ($r->dir_config("NetdotLDAPFailToLocal") eq "yes")? 1 : 0;

    my $user_dn = $r->dir_config("NetdotLDAPUserDN");
    unless ( $user_dn ){
	$r->log_error("Netdot::LDAP::check_credentials: ERROR: DN is not set. Use NetdotLDAPUserDN in httpd.conf");
	return 0;
    }

    $user_dn =~ s/<username>/$username/;
    
    my $base_dn = $r->dir_config("NetdotLDAPSearchBase");
    if ( $base_dn ){
	$user_dn .= ",$base_dn";
    }

    my $ldap;
    unless ( $ldap = Netdot::LDAP::_connect($r) ){
	return 0;
    }

    my $auth = $ldap->bind($user_dn, password=>$password);
    if ( $auth->code ) {
	$r->log_error("Netdot::LDAP::check_credentials: User $username failed LDAP authentication: " . $auth->error);
	if  ( $fail_to_local ){
	    $r->log_error("Netdot::LDAP::check_credentials: Trying local auth");
	    return Netdot::AuthLocal::check_credentials($r, $username, $password);
	}
    }else{
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
	$r->log_error("Netdot::LDAP::check_credentials: WARNING: LDAP server is not set. Set NetdotLDAPServer in httpd.conf");
	$server1 = "ldaps://localhost";
    }
    push @servers, $server1;

    # This is optional
    if ( my $server2 = $r->dir_config("NetdotLDAPServer") ){
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
	    $r->log_error("Netdot::LDAP::check_credentials: ERROR: Could not contact LDAP server $server: $@");
	}
    }

    return 0;
}


#Be sure to return 1
1;


=head1 SEE ALSO

Apache2::SiteControl

=head1 AUTHORS

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009 University of Oregon, all rights reserved.

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

