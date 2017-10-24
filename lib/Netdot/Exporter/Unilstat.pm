package Netdot::Exporter::Unilstat;

use base 'Netdot::Exporter';
use warnings;
use strict;
use Data::Dumper;
use HTML::Entities;

my $logger = Netdot->log->get_logger('Netdot::Exporter');

my $dbh = Netdot::Model->db_Main();

=head1 NAME

Netdot::Exporter::UNILstat - Read relevant info from Netdot and build UNIL host.arp

=head1 SYNOPSIS

    my $unil = Netdot::Exporter->new(type=>'UNILSTAT');
    $unil->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################
=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::UNILstat object
  Examples:
    my $stat = Netdot::Exporter->new(type=>'UNILSTAT');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    foreach my $key ( qw /UNILSTAT_DIR UNILSTAT_FILE DEFAULT_DNSDOMAIN/ ){
	$self->{$key} = Netdot->config->get($key);
    }
     
    $self->{UNILSTAT_FILE} || 
	$class->throw_user("Netdot::Exporter::Unilstat: UNILSTAT_FILE not defined");
    
    # Open output file for writing
    $self->{filename} = $self->{UNILSTAT_DIR}."/".$self->{UNILSTAT_FILE};

    bless $self, $class;

    $self->{out} = $self->open_and_lock($self->{filename});
    return $self;
}

############################################################################
=head2 generate_configs - Generate configuration files for UNILSTAT

  Arguments:
    None
  Returns:
    True if successful
  Examples:
    $unil->generate_configs();
=cut
my %reverse;

sub generate_configs {
    my ($self) = @_;

    $self->print_header();

    # Get UB info
    $self->print_array(name=>'ub_info');
    my $ubq = $dbh->selectall_arrayref("SELECT id,name from entity WHERE aliases != ''");
    foreach my $row ( @$ubq ){
	my ($id, $name) = @$row;
	$self->print_ub(id=>$id, name=>$name);
    }

    # Get VLAN info
    $self->print_array(name=>'vlan_info');
    my $vlanq = $dbh->selectall_arrayref("SELECT vlan.vid, ipblock.description, ipblock.version, ipblock.address, ipblock.prefix FROM `vlan`, `ipblock` WHERE ipblock.status=5 AND vlan.id=ipblock.vlan ORDER BY vlan.vid, ipblock.version");
    foreach my $row ( @$vlanq ){
	my ($vlan, $description, $version, $address, $prefix) = @$row;
	my $ip = lc(NetAddr::IP->new($address)->short);
	$self->print_vlan(id=>$vlan, subnet=>"$ip/$prefix", description=>$description, version=>$version);
    }

    # Get Subnet info
    $self->print_array(name=>'subnet_info');
    my $subnetq = $dbh->selectall_arrayref("SELECT id, address, prefix, used_by, description, version FROM ipblock WHERE (status=1 or status=5) ORDER BY address");
    foreach my $row ( @$subnetq ){
	my ($id, $address, $prefix, $ub, $description, $version) = @$row;
	my $ip = lc(NetAddr::IP->new($address)->short);
	$self->print_subnet(id=>$id, subnet=>"$ip/$prefix", ub=>$ub, description=>$description, version=>$version);
    }
    $self->print_array(name=>'subnet_lookup');
    foreach my $row ( @$subnetq ){
	my ($id, $address, $prefix, $ub, $description, $version) = @$row;
	my $ip = lc(NetAddr::IP->new($address)->short);
	$self->print_subnet_lookup(id=>$id, address=>$address, prefix=>$prefix, version=>$version);
    }

    # Get IP info
    $self->print_array(name=>'ip_info');
    my $ipq = $dbh->selectall_arrayref("SELECT ipblock.address,ipblock.used_by,ipblock.parent,rrptr.ptrdname FROM rrptr,ipblock WHERE rrptr.ipblock=ipblock.id AND (ipblock.status=3 OR ipblock.status=6) ORDER BY ipblock.address");
    foreach my $row ( @$ipq ){
	my ($address, $ub, $parent, $name) = @$row;
	my $ip = lc(NetAddr::IP->new($address)->short);
	$self->print_host(address=>$address, ip=>$ip, ub=>$ub, parent=>$parent, name=>$name);
    }

    $self->print_footer();
    close($self->{out});

    system ("/usr/bin/scp ".$self->{filename}." reseau\@prdres:/var/www/html/stat/");    

    $logger->info("Netdot::Exporter::Unilstat: Configuration written to file: ".$self->{filename});
}


#####################################################################################
sub print_header {
    my ($self, %argv) = @_;

    my $out = $self->{out};

    use POSIX qw(strftime);
    my $now = strftime "%d.%m.%Y %H:%M:%S", localtime;

    print $out "<?php\n\n";
    print $out "/*\n";
    print $out " * Version du $now\n";
    print $out " * Fichier cree par Netdot\n";
    print $out " */\n";
}

#####################################################################################
sub print_array {
    my ($self, %argv) = @_;

    my $out = $self->{out};
    my $name = $argv{name};

    print $out "\n// Array $name\n\$$name = array();\n";
}

#####################################################################################
sub print_footer {
    my ($self, %argv) = @_;

    my $out = $self->{out};

    print $out "\n?>\n";
}

#####################################################################################
sub print_ub {
    my ($self, %argv) = @_;

    my $out  = $self->{out};
    my $id   = $argv{id};
    my $name = encode_entities($argv{name});

#    $name =~ s/'/\\'/g;

    printf $out "\$ub_info['%s'] = '%s';\n", $id, $name;
}

#####################################################################################
sub print_subnet {
    my ($self, %argv) = @_;

    my $out         = $self->{out};
    my $id          = $argv{id};
    my $subnet      = $argv{subnet};
    my $ub          = $argv{ub} || "0";
    my $version     = $argv{version} || "4";
    my $description = encode_entities($argv{description});

    $description = '' if (!defined $description);
#    $description =~ s/\'/\\\'/g;

    printf $out "\$subnet_info['%s'] = array('subnet'=>'%s', 'ub'=>'%s', 'description'=>'%s', 'version'=>'%s');\n", $id, $subnet, $ub, $description, $version;
}

#####################################################################################
sub print_vlan {
    my ($self, %argv) = @_;

    my $out         = $self->{out};
    my $id          = $argv{id};
    my $subnet      = $argv{subnet};
    my $version     = $argv{version} || "4";
    my $description = encode_entities($argv{description});

    $description = '' if (!defined $description);
#    $description =~ s/\'/\\\'/g;

    if ($version == "4") {
	printf $out "\$vlan_info['%s']['description'] = '%s';\n", $id, $description;
    }
    printf $out "\$vlan_info['%s']['IPv%s'][] = '%s';\n", $id, $version, $subnet;
}

#####################################################################################
sub print_subnet_lookup {
    my ($self, %argv) = @_;

    my $out     = $self->{out};
    my $id      = $argv{id};
    my $address  = $argv{address};
    my $prefix  = $argv{prefix};
    my $version = $argv{version};

    if ($version eq '4') {
	if ($prefix< 16) { return; }
	if ($prefix> 24) { return; }
        my $ip = NetAddr::IP->new($address, $prefix);
	foreach my $str ($ip->split(24)) {
	    my $addr =  NetAddr::IP->new($str)->numeric;
	    printf $out "// $str\n";
	    printf $out "\$subnet_lookup['%s'] = %s;\n", $addr, $id;
	}
    } else {
	if ($prefix< 64) { return; }
	my $ip = NetAddr::IP->new($address)->short;
	printf $out "// $ip/64\n";
	printf $out "\$subnet_lookup['%s'] = %s;\n", $address, $id;
    }
}

#####################################################################################
sub print_host {
	my ($self, %argv) = @_;

	my $out     = $self->{out};
	my $address = $argv{address};
	my $ip      = $argv{ip};
	my $ub      = $argv{ub} || "0";
	my $parent  = $argv{parent};
	my $name    = $argv{name};

	printf $out "\$ip_info['%s'] = array('ip'=>'%s', 'ub'=>'%s', 'subnet'=>'%s', 'name'=>'%s');\n", $address, $ip, $ub, $parent, $name;
}

=head1 AUTHOR

Vincent Magnin, << <vincent.magnin at unil.chu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 University of Lausanne, all rights reserved.

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
