#!/usr/bin/perl

use strict;
use DBI;
use NetAddr::IP;
use Date::Parse;
use POSIX 'strftime';
 
my $db_name = '<<DB_DATABASE>>';
my $db_host = '<<DB_HOST>>';
my $db_user_name = '<<DB_DBA>>';
my $db_password = '<<DB_DBA_PASSWORD>>';

my $dbh = DBI->connect( "DBI:mysql:$db_name:$db_host", $db_user_name, $db_password)
    or die "Connecting : $DBI::errstr\n ";

# Create table
my $sql = 'SELECT ipblock.address AS ip, physaddr.address AS mac, DATE_FORMAT(arpcache.tstamp,"%Y-%m-%d %H:00:00") AS date FROM `arpcache`, `arpcacheentry`, `ipblock`, `physaddr` WHERE arpcacheentry.ipaddr=ipblock.id AND arpcacheentry.physaddr=physaddr.id AND arpcacheentry.arpcache=arpcache.id ORDER BY tstamp';
my $sth = $dbh->prepare($sql);
my $res = $sth->execute();

my $row;
my %gbc;

while ($row = $sth->fetchrow_arrayref()) {
    my ($ip, $mac, $date) = @$row;
    my $unixtime = str2time($date);

    $gbc{$unixtime}{$ip} = $mac;
    $gbc{$unixtime+3600}{$ip} = $mac;
    $gbc{$unixtime+7200}{$ip} = $mac;
    $gbc{$unixtime+10800}{$ip} = $mac;
}

$sth->finish();

$dbh->disconnect();


my $count = 0;
print "id,src_ip,mac2,date\n";

foreach my $unixtime ( sort keys %gbc ) {
    foreach my $rip (sort keys %{$gbc{$unixtime}}) {
	my $rmac = $gbc{$unixtime}{$rip};
	$count++;
	my $time = strftime('%Y-%m-%d %H:%M:%S', localtime($unixtime));
        my $ip = lc NetAddr::IP->new($rip)->addr();
        my $mac = lc join ':', unpack("(A2)*", $rmac);

	print "\"$count\",\"$ip\",\"$mac\",\"$time\"\n";
    }
}


