#!/usr/bin/perl

use Netdot::Client::REST;
use Data::Dumper;
my $ua = new LWP::UserAgent();

use strict;

die unless(exists $ENV{'NETDOT_USER'});
die unless(exists $ENV{'NETDOT_PASSWORD'});

# Login to Netdot
my $netdot = Netdot::Client::REST->new(
    server=>'https://<<NETDOTNAME>>/netdot',
    username=>$ENV{'NETDOT_USER'},
    password=>$ENV{'NETDOT_PASSWORD'},
);

# GET variable from certbot ENV variables
my $domain = $ENV{'CERTBOT_DOMAIN'};
my $challenge = '_acme-challenge.'.$domain;

my $acme = $netdot->get('RR?name='.$challenge);

foreach my $rr (keys %{$acme->{'RR'}}) {
	my $txt = $netdot->get('RRTXT?rr='.$rr);

	foreach my $rrtxt (keys %{$txt->{'RRTXT'}}) {
		$netdot->delete('RRTXT/'.$rrtxt);
	}

	# Deactivate record
	$netdot->post('RR/'.$rr, {active=>0} );

	# Export
	$netdot->update_bind();
}
