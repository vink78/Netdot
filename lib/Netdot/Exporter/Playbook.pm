package Netdot::Exporter::Playbook;

use base 'Netdot::Exporter';
use warnings;
use strict;
use HTML::Entities;
use Data::Dumper;

my $logger = Netdot->log->get_logger('Netdot::Exporter');

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
    foreach my $row ( @$q ) {
	my ($id, $host, $domain, $row_info) = @$row;
	my @info = split /\n/, $row_info;

	# list lookup
	my $list = '';
	my $i = 0;
        foreach (@info) {
	    if (/^(Liste.*)$/) {
		$i++;
		$list = $1;
	    }
	}

	if ($list ne '') {
	    push @{ $list_info{$list} }, $host.'.'.$domain;
	}
    }

    my $out = $self->open_and_lock('/usr/local/netdot/export/pb/group_vars/all/liste_verte.yml');
    print $out "---\n";
    foreach my $list (keys %list_info) {
	$list =~ s/\s/_/g;
	print $out "$list:\n";
    }

    close($out);
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
