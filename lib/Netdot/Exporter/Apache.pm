package Netdot::Exporter::Apache;

use base 'Netdot::Exporter';
use warnings;
use strict;
use Data::Dumper;

my $logger = Netdot->log->get_logger('Netdot::Exporter');
my $dbh = Netdot::Model->db_Main();

=head1 NAME

Netdot::Exporter::Apache - Read relevant info from Netdot and build an Apache
    config file for URL Redirection.

=head1 SYNOPSIS

    my $apache = Netdot::Exporter->new(type=>'Apache');
    $apache->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################
=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::Apache object
  Examples:
    my $apache = Netdot::Exporter->new(type=>'Apache');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    foreach my $key ( qw /Apache_DIR Apache_FILE Apache_IP Apache_SCP_TARGET/ ){
	$self->{$key} = Netdot->config->get($key);
    }
     
    $self->{Apache_FILE} || 
	$class->throw_user("Netdot::Exporter::Apache: Apache_FILE not defined");
    
    # Open output file for writing
    $self->{filename} = $self->{Apache_DIR}."/".$self->{Apache_FILE};

    bless $self, $class;

    $self->{out} = $self->open_and_lock($self->{filename});
    return $self;
}

############################################################################
=head2 generate_configs - Generate apache.conf for URL redirection

  Arguments:
    None
  Returns:
    True if successful
  Examples:
    $apache->generate_configs();
=cut
my %txt;

sub generate_configs {
    my ($self) = @_;

    # Get TXT info
    my $txtq = $dbh->selectall_arrayref("
              SELECT SUBSTRING(rrtxt.txtdata, 3) AS url, rr.name AS record, zone.name AS domain
              FROM rrtxt, rr, zone
              WHERE rrtxt.txtdata LIKE 'R=%' AND rr.id=rrtxt.rr AND rr.zone=zone.id
             ");

    foreach my $row ( @$txtq ) {
	my ($url, $rec, $domain) = @$row;
	my $site = $rec.'.'.$domain;
	$site = $domain if ($rec eq '@' || $rec eq '');

	push(@{$txt{$url}}, lc $site);

	# Check for aliases
	my $ctxtq = $dbh->selectall_arrayref("
                   SELECT rr.name, zone.name
                   FROM rrcname, rr, zone
                   WHERE cname = '$site' AND rrcname.rr=rr.id AND zone.id=rr.zone
                  ");

	foreach my $rowc ( @$ctxtq ) {
	    my ($recc, $domainc) = @$rowc;
	    my $sitec = $recc.'.'.$domainc;
	    $sitec = $domainc if ($recc eq '@' || $rec eq '');

	    push(@{$txt{$url}}, lc $sitec);
	}
    }

    my $out = $self->{out};
    foreach my $url ( keys %txt ){
	my @data = @{ $txt{$url} };
	my $name = $data[0];
	print $out "<VirtualHost *:80>\n";
        print $out "  ServerName $data[0]\n";
        print $out "  Redirect / $url\n";
	for my $i ( 1 .. $#data ) {
	    print $out "  ServerAlias $data[$i]\n";
	}
        print $out "</VirtualHost>\n";
    }

    close($self->{out});

    $logger->info("Netdot::Exporter::Apache: Configuration written to file: ".$self->{filename});
    #system ("/usr/bin/scp ".$self->{filename}.' '.$self->{Apache_SCP_TARGET});
}

=head1 AUTHOR

Vincent Magnin, << <vincent.magnin at unil.ch> >>

=head1 COPYRIGHT & LICENSE

Copyright 2015 University of Lausanne, all rights reserved.

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
