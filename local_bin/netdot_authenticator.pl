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
my $txtdata = $ENV{'CERTBOT_VALIDATION'};
my $ttl = 120;

my $acme;
eval {
	$acme = $netdot->get('RR?name='.$challenge);
};
if ($@) {
	my $data = {
		name => $challenge
	};

	my $rr = $netdot->post('RR', $data);
	$acme->{'RR'}->{$rr->{'id'}} = $rr;
}

foreach my $rr (keys %{$acme->{'RR'}}) {
	my $data = {
		rr => $rr,
		ttl => $ttl,
		txtdata => $txtdata
	};

	$netdot->post('RRTXT', $data);

	# Activate record
	$netdot->post('RR/'.$rr, {active=>1} );

	# Export
	$netdot->update_bind();
}
