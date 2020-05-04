#!/usr/bin/perl

use strict;
use DBI;
use NetAddr::IP;

my $db_name = '<<DB_DATABASE>>';
my $db_host = '<<DB_HOST>>';
my $db_user_name = '<<DB_DBA>>';
my $db_password = '<<DB_DBA_PASSWORD>>';

my $dbh = DBI->connect( "DBI:mysql:$db_name:$db_host", $db_user_name, $db_password)
    or die "Connecting : $DBI::errstr\n ";

# Create table
my $sql = 'CREATE TABLE stat SELECT ipblock.address AS ip, physaddr.address AS mac, arpcache.tstamp AS date FROM `arpcache`, `arpcacheentry`, `ipblock`, `physaddr` WHERE arpcacheentry.ipaddr=ipblock.id AND arpcacheentry.physaddr=physaddr.id AND arpcacheentry.arpcache=arpcache.id';
my $sth = $dbh->prepare($sql);
my $res = $sth->execute();
$sth->finish();

# Sort table
$sql = 'SELECT ip, mac, MIN(date) AS first, MAX(date) AS last FROM stat GROUP BY ip, mac ORDER BY ip, first';
$sth = $dbh->prepare($sql);
$res = $sth->execute();

my $row;
my $count = 0;

print "id,src_ip,vlan,mac,first,last\n";
while ($row = $sth->fetchrow_arrayref()) {
    my ($rip, $rmac, $first, $last) = @$row;
    my $ip = lc NetAddr::IP->new($rip)->addr();
    my $mac = lc join ':', unpack("(A2)*", $rmac);

    $count++;
    print "\"$count\",\"$ip\",\"0\",\"$mac\",\"$first\",\"$last\"\n";
}

$sth->finish();

# Clear table
$sql = 'DROP TABLE stat';
$sth = $dbh->prepare($sql);
$res = $sth->execute();

$sth->finish();
$dbh->disconnect();

