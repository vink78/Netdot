package Netdot::Exporter::Playbook;

use base 'Netdot::Exporter';
use warnings;
use strict;
use HTML::Entities;
use Data::Dumper;

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
}

sub vlan_list {
    my ($self, %argv) = @_;

    my @mgmt = (500, 501, 502, 503, 504, 505, 564, 565);

    my $file = $self->{Playbook_DIR}.'/group_vars/all/vlan_list.yml';
    my $out = $self->open_and_lock($file);
    print $out "---\n";
    print $out "vlan_list:\n";

    my $q = $dbh->selectall_arrayref("
              SELECT
                vid, name
              FROM
                vlan
              ORDER BY
                vid
	      ");

    foreach my $row ( @$q ) {
	my ($vid, $name) = @$row;

	print $out "   $vid:\n";
	print $out "     name: '$name'\n";
	print $out "     is_mgmt_vlan: True\n"
	  if ( grep( /^$vid$/, @mgmt ) );
    }
    print $out "\n\n";
    close($out);

    $logger->info("Netdot::Exporter::Playbook: Vlan List playbook written to file: ".$file);
}

sub liste_verte {
    my ($self, %argv) = @_;

    my $q = $dbh->selectall_arrayref("
	      SELECT
		rr.id, rr.name, zone.name, rr.info
              FROM
		rr, zone
	      WHERE
		rr.info like 'Liste %' AND rr.zone=zone.id
	      ");

    my %list_info;
    my %date;
    my %owner;
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
	}
    }

    my $file = $self->{Playbook_DIR}.'/group_vars/all/liste_verte.yml';
    my $out = $self->open_and_lock($file);
    print $out "---\n";
    foreach my $list (sort keys %list_info) {
	print $out "$list:\n";
	foreach my $host (sort @{$list_info{$list}}) {
	    my $key = $host;
	    $key =~ s/^(.+)\.$self->{DEFAULT_DNSDOMAIN}/$1/g;
	    $key = join '_', split /\./, $key; 
	    print $out "   $key:\n";
	    print $out "     dns: '$host'\n";
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
