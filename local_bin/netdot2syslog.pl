#!/usr/bin/perl

use strict;
use DBI;
use NetAddr::IP;
use Time::HiRes qw( usleep );

my $db_name = '<<DB_DATABASE>>';
my $db_host = '<<DB_HOST>>';
my $db_user_name = '<<DB_DBA>>';
my $db_password = '<<DB_DBA_PASSWORD>>';

use Net::Syslog;
my $s = new Net::Syslog(
    Facility    =>  'local4',
    Priority    =>  'info',
    SyslogHost  =>  'arp.logs.unil.ch'
);

my $dbh = DBI->connect( "DBI:mysql:$db_name:$db_host", $db_user_name, $db_password)
    or die "Connecting : $DBI::errstr\n ";

# Create table
my $sql = "SELECT physaddr.address AS mac, ipblock.address AS ip, rrptr.ptrdname AS dname, arp.tstamp AS date
FROM physaddr
LEFT JOIN
  (SELECT ace.physaddr,ace.ipaddr,max(tstamp) as tstamp FROM arpcacheentry ace
   JOIN arpcache ac ON ac.id=ace.arpcache
   WHERE ac.tstamp >= timestampadd(hour,-1,now())
   GROUP BY ace.physaddr,ace.ipaddr
  ) AS arp ON arp.physaddr=physaddr.id
LEFT JOIN ipblock ON ipblock.id=arp.ipaddr
LEFT JOIN rrptr ON rrptr.ipblock=ipblock.id
WHERE ipblock.address is not NULL";

my $sth = $dbh->prepare($sql);
my $res = $sth->execute();

my $row;

my @logs;

while ($row = $sth->fetchrow_arrayref()) {
    my ($rmac, $rip, $dname, $date) = @$row;
    my $ip = lc NetAddr::IP->new($rip)->addr();
    my $mac = lc join ':', unpack("(A2)*", $rmac);

    push(@logs, ", ip='$ip',mac='$mac',hostname='$dname',date='$date'");
}

$sth->finish();
$dbh->disconnect();

foreach my $log (@logs) {
	$s->send( $log , Priority => 'info');
	usleep(2); 
}
