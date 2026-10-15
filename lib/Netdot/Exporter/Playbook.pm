package Netdot::Exporter::Playbook;

use base 'Netdot::Exporter';
use warnings;
use strict;
use HTML::Entities;
use Data::Dumper;
use Date::Parse;
use NetAddr::IP;
use Encode qw(decode encode);

my $logger = Netdot->log->get_logger('Netdot::Exporter');

my $dbh = Netdot::Model->db_Main();


=head1 NAME

Netdot::Exporter::Playbook - Read relevant info from Netdot and commit changes

=head1 SYNOPSIS

    my $pb = Netdot::Exporter->new(type=>'Playbook');
    $pb->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################

=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::Playbook object
  Examples:
    my $pb = Netdot::Exporter->new(type=>'Playbook');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    foreach my $key ( qw /DEFAULT_DNSDOMAIN Playbook_DIR/ ){
	$self->{$key} = Netdot->config->get($key);
    }

    bless $self, $class;
    return $self;
}

############################################################################

=head2 generate_configs - Commit changes to related repository

  Arguments:
    Hashref with the following keys:
      branch - Name of commit branch
  Returns:
    True if successful
  Examples:
    $pb->generate_configs();
=cut

sub generate_configs {
    my ($self, %argv) = @_;

    # Generate liste verte playbook
    $self->liste_verte();

    # Generate vlan_list.yml
    $self->vlan_list();

    # Generate Host.yml AND CNAME.yml
    $self->ansible_form();
}

sub vlan_list {
    my ($self, %argv) = @_;

    my @mgmt = (500, 501, 502, 503, 504, 505, 564, 565);
    my %subnet;
    my %subnet6;
    my %site;
    my %entity;

    my $file = $self->{Playbook_DIR}.'/group_vars/all/vlan_list.yml';
    my $out = $self->open_and_lock($file);
    #binmode($out, ":utf8");
    print $out "---\n";
    print $out "vlan_list:\n";

    my $q = $dbh->selectall_arrayref("SELECT site.name, site.number, sitesubnet.subnet FROM site, sitesubnet WHERE site.id = sitesubnet.site AND site.name != 'VRO' ORDER BY site.name");

    foreach my $row ( @$q ) {
	my ($sitename, $sitenumber, $subnetid) = @$row;

	push (@{$site{$subnetid}}, {'name'=>$sitename, 'id'=>$sitenumber})
	    if (defined $sitename);
    }

    $q = $dbh->selectall_arrayref("
              SELECT id, name
              FROM entity
              ORDER BY name
	      ");

    foreach my $row ( @$q ) {
	my ($eid, $ename) = @$row;

	$entity{$eid} = $ename
	    if (defined $ename);
    }

    $q = $dbh->selectall_arrayref("
              SELECT id, vlan, address, prefix, version, description, used_by
              FROM ipblock
              WHERE status=5
              ORDER BY address
	      ");

    foreach my $row ( @$q ) {
	my ($ipblock, $nid, $addr, $prefix, $version, $description, $user) = @$row;
	my $ip = NetAddr::IP->new($addr);
	$user = '' if (!defined $user);
	$nid = 0 if (!defined $nid);

	my $data = {'subnet'=>$ip->short.'/'.$prefix, 'site'=>$site{$ipblock}, 'entity'=>$entity{$user}, 'description'=>$description};

	if (defined $site{$ipblock}) {
	    $data->{'site'} = $site{$ipblock};
	}

	if ($version == 4) {
	    push (@{$subnet{$nid}}, $data);
	} else {
	    push (@{$subnet6{$nid}}, $data);
	}
    }

    $q = $dbh->selectall_arrayref("
              SELECT
                vid, name, id
              FROM
                vlan
              ORDER BY
                vid
	      ");

    foreach my $row ( @$q ) {
	my ($vid, $name, $nid) = @$row;

	print $out "   - tag: $vid\n";
	print $out "     name: \"$name\"\n"
	    if (defined $name);

	if (defined $subnet{$nid}) {
	    print $out "     ipv4:\n";
	    foreach my $prefix (@{$subnet{$nid}}) {
		print $out "      - subnet: \"".$prefix->{'subnet'}."\"\n";
		if (defined $prefix->{'description'}) {
		    print $out "        description: \"". encode('UTF-8', $prefix->{'description'})."\"\n";
	        }
		if (defined $prefix->{'entity'}) {
		    print $out "        entity: \"". encode('UTF-8', $prefix->{'entity'})."\"\n";
	        }
		if (defined $prefix->{'site'}) {
		    print $out "        site:\n";
		    foreach my $site (@{$prefix->{'site'}}) {
		        print $out "          - id: \"". encode('UTF-8', $site->{'id'}) ."\"\n";
		        print $out "            name: \"". encode('UTF-8', $site->{'name'}) ."\"\n";
	            }
	        }
	    }
	}
	if (defined $subnet6{$nid}) {
	    print $out "     ipv6:\n";
	    foreach my $prefix (@{$subnet6{$nid}}) {
		print $out "      - subnet: \"".$prefix->{'subnet'}."\"\n";
		if (defined $prefix->{'description'}) {
		    print $out "        description: \"". encode('UTF-8', $prefix->{'description'})."\"\n";
	        }
		if (defined $prefix->{'entity'}) {
		    print $out "        entity: \"". encode('UTF-8', $prefix->{'entity'})."\"\n";
	        }
		if (defined $prefix->{'site'}) {
		    print $out "        site:\n";
		    foreach my $site (@{$prefix->{'site'}}) {
		        print $out "          - id: \"". encode('UTF-8', $site->{'id'}) ."\"\n";
		        print $out "            name: \"". encode('UTF-8', $site->{'name'}) ."\"\n";
	            }
	        }
	    }
	}
    }
    print $out "\n\n";
    close($out);

    $logger->info("Netdot::Exporter::Playbook: Vlan List playbook written to file: ".$file);
}

sub liste_verte {
    my ($self, %argv) = @_;

    my $q0 = $dbh->selectall_arrayref("
               SELECT
                 rraddr.rr, ipblock.address, ipblock.version
               FROM
                 rraddr, ipblock
               WHERE
                 ipblock.id=rraddr.ipblock 
              ");

    my $q = $dbh->selectall_arrayref("
	      SELECT
		rr.id, rr.name, zone.name, rr.info
              FROM
		rr, zone
	      WHERE
		rr.info like 'Liste %' AND rr.zone=zone.id
	      ");

    my %rrip;
    foreach my $row ( @$q0 ) {
	my ($rr, $addr, $version) = @$row;
	my $ip = NetAddr::IP->new($addr);

	push (@{$rrip{$rr}}, $ip->short);
    }

    my %list_info;
    my %date;
    my %owner;
    my %ipv;
    foreach my $row ( @$q ) {
	my ($id, $host, $domain, $row_info) = @$row;
	my @info = split /\n/, $row_info;

	# Build Hotsname
	my $hostname = $host.'.'.$domain;
	if ($host eq '@') {
	    $hostname = $domain;
	}

	# list lookup
        foreach (@info) {
	    if (/^(Liste.*)$/) {
		my $list = $1;
		$list =~ s/\s/_/g;
		$list = 'Liste_WebVert'
		   if ($list eq 'Liste_Verte_80/443');

		push @{ $list_info{$list} }, $hostname
		   if ($list !~ /\*/);
	    }
	    if (/^Date: (.+)$/) {
		$date{$hostname} = $1;
	    }
	    if (/^Responsable: (.+)$/) {
		$owner{$hostname} = $1;
	    }
	    $ipv{$hostname} = $rrip{$id}
		if (defined $rrip{$id});
	}
    }

    my $file = $self->{Playbook_DIR}.'/group_vars/all/liste_verte.yml';
    my $out = $self->open_and_lock($file);
    binmode($out, ":utf8");
    print $out "---\n";
    foreach my $list (sort keys %list_info) {
	print $out "$list:\n";
	foreach my $host (sort @{$list_info{$list}}) {
	    my $key = $host;
	    $key =~ s/^(.+)\.$self->{DEFAULT_DNSDOMAIN}/$1/g;
	    $key = join '_', split /\./, $key; 
	    print $out "   $key:\n";
	    print $out "     dns: '$host'\n";
	    if (defined $ipv{$host}) {
		print $out "     ip:\n";
		foreach my $ip (@{$ipv{$host}}) {
		    print $out "      - $ip\n";
		}
	    }
	    print $out "     date: '$date{$host}'\n"
		if (defined $date{$host});
	    print $out "     owner: '$owner{$host}'\n"
		if (defined $owner{$host});
	}
    }
    print $out "\n\n";
    close($out);

    $logger->info("Netdot::Exporter::Playbook: Liste Verte playbook written to file: ".$file);
}

sub ansible_form {
    my ($self, %argv) = @_;

    my $q0 = $dbh->selectall_arrayref("
               SELECT
                 rraddr.rr, ipblock.address, ipblock.version
               FROM
                 rraddr, ipblock
               WHERE
                 ipblock.id=rraddr.ipblock 
              ");

    my $q1 = $dbh->selectall_arrayref("
               SELECT
                 rr.id, rrcname.cname, rr.name, zone.name
               FROM
                 rrcname, rr, zone
               WHERE
                 rr.id=rrcname.rr AND zone.id=rr.zone
              ");

    my $q2 = $dbh->selectall_arrayref("
               SELECT
	         ipblock.address, physaddr.address
	       FROM
                 dhcpscope, ipblock, physaddr
	       WHERE
	         dhcpscope.type=5 AND ipblock.id=dhcpscope.ipblock AND physaddr.id = dhcpscope.physaddr
              ");

    my $q = $dbh->selectall_arrayref("
	      SELECT
		rr.id, rr.name, zone.name, rr.info, rr.modified
              FROM
		rr, zone
	      WHERE
		rr.info like 'Ansible: on%' AND rr.zone=zone.id
	      ");

    my %rrip;
    foreach my $row ( @$q0 ) {
	my ($rr, $addr, $version) = @$row;
	my $ip = NetAddr::IP->new($addr);

	push (@{$rrip{$rr}}, $ip->short);
    }

    my %rrmac;
    foreach my $row ( @$q2 ) {
	my ($addr, $mac) = @$row;
	my $ip = NetAddr::IP->new($addr);

	$rrmac{$ip->short} = $mac;
    }

    my %rrcname;
    my %rrcnameid;
    foreach my $row ( @$q1 ) {
	my ($rrid, $cname, $host, $domain) = @$row;

	push (@{$rrcname{$cname}}, $host.'.'.$domain);
	$rrcnameid{$rrid} = $cname;
    }

    my %list;
    foreach my $row ( @$q ) {
	my ($id, $host, $domain, $data, $date) = @$row;

	next if ($rrcnameid{$id});

	my %field;
	my @info = split /\n/, $data;

	# Build Hotsname
	my $hostname = $host.'.'.$domain;
	if ($host eq '@') {
	    $hostname = $domain;
	}

	$field{'Date'} = $date; # This is the default

	# list lookup
        foreach (@info) {
	    if (/^(.+): (.+)$/) {
		$field{$1} = $2;
	    }
	}
	$field{'IP'} = $rrip{$id};
	$field{'CNAME'} = $rrcname{$hostname};

	$list{$hostname} = \%field;
    }

    my $file = $self->{Playbook_DIR}.'/group_vars/all/Host.yml';
    my $out = $self->open_and_lock($file);
    binmode($out, ":utf8");
    print $out "---\n\n";
    print $out "Host:\n";
    my @order = ('CustomerUserID', 'CustomerID', 'Unit', 'FunctionExt', 'Faculty', 'Date', 'TicketNumber', 'Room');
    my @sorted = sort {
	my $adate = str2time($list{$a}->{'Date'});
	my $bdate = str2time($list{$b}->{'Date'});
	($adate == $bdate) ? $a cmp $b : $adate<=>$bdate;
    } keys %list;

    foreach my $hostname (@sorted) {
	print $out "# BEGIN ANSIBLE MANAGED BLOCK $hostname\n";
	print $out "- Name: '$hostname'\n";
	foreach my $row (@order) {
	    print $out "  $row: '".$list{$hostname}->{$row}."'\n"
		if ($list{$hostname}->{$row});
	}
	print $out "  Address:\n";
	foreach my $row (sort @{$list{$hostname}->{'IP'}}) {
	    if ($row =~ /:/) {
	        print $out "   - IPv6: '$row'\n";
	    } else {
	        print $out "   - IPv4: '$row'\n";
	    }
	    print $out "     MAC: '". PhysAddr->format_address(address=>$rrmac{$row}, format_caseness=>'upper', format_delimiter_string=>':', format_delimiter_interval => 2) ."'\n" if ($rrmac{$row});
	}
	if ($list{$hostname}->{'CNAME'}) {
	    print $out "  CNAME:\n";
	    foreach my $row (sort @{$list{$hostname}->{'CNAME'}}) {
		print $out "   - '$row'\n";
	    }
	}
	print $out "# END ANSIBLE MANAGED BLOCK $hostname\n";
    }
    print $out "\n\n";
    close($out);

    $logger->info("Netdot::Exporter::Playbook: Hostfile written to file: ".$file);

    my %list2;
    foreach my $row ( @$q ) {
	my ($id, $host, $domain, $data, $date) = @$row;

	next unless ($rrcnameid{$id});

	my %field;
	my @info = split /\n/, $data;

	# Build Hotsname
	my $hostname = $host.'.'.$domain;
	if ($host eq '@') {
	    $hostname = $domain;
	}

	$field{'Date'} = $date; # This is the default

	# list lookup
        foreach (@info) {
	    if (/^(.+): (.+)$/) {
		$field{$1} = $2;
	    }
	}
	$field{'CNAME'} = $rrcnameid{$id};

	$list2{$hostname} = \%field;
    }

    my $file2 = $self->{Playbook_DIR}.'/group_vars/all/CNAME.yml';
    my $out2 = $self->open_and_lock($file2);
    binmode($out2, ":utf8");
    print $out2 "---\n\n";
    print $out2 "CNAME:\n";
    my @order2 = ('CustomerUserID', 'CustomerID', 'Unit', 'FunctionExt', 'Faculty', 'Date', 'TicketNumber', 'Room');
    my @sorted2 = sort {
	my $adate = str2time($list2{$a}->{'Date'});
	my $bdate = str2time($list2{$b}->{'Date'});
	($adate == $bdate) ? $a cmp $b : $adate<=>$bdate;
    } keys %list2;

    foreach my $hostname (@sorted2) {
	print $out2 "# BEGIN ANSIBLE MANAGED BLOCK $hostname\n";
	print $out2 "- Name: '$hostname'\n";
	foreach my $row (@order2) {
	    print $out2 "  $row: '".$list2{$hostname}->{$row}."'\n"
		if ($list2{$hostname}->{$row});
	}
	if ($list2{$hostname}->{'CNAME'}) {
	    print $out2 "  Target: '".$list2{$hostname}->{'CNAME'}."'\n";
	}
	print $out2 "# END ANSIBLE MANAGED BLOCK $hostname\n";
    }
    print $out2 "\n\n";
    close($out2);

    $logger->info("Netdot::Exporter::Playbook: CNAMEs written to file: ".$file2);
}

=head1 AUTHOR

Vincent Magnin, C<< <vincent.magnin at unil.ch> >>

=head1 COPYRIGHT & LICENSE

Copyright 2017 University of Lausanne, all rights reserved.

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

#Be sure to return 1
1;
