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
