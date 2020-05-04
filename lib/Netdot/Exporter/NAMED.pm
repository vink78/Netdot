package Netdot::Exporter::NAMED;

use base 'Netdot::Exporter';
use warnings;
use strict;
use Data::Dumper;
use List::MoreUtils qw(uniq);

my $logger = Netdot->log->get_logger('Netdot::Exporter');

my $dbh = Netdot::Model->db_Main();

=head1 NAME

Netdot::Exporter::NAMED - Read relevant info from Netdot and build relevant named.conf

=head1 SYNOPSIS

    my $unil = Netdot::Exporter->new(type=>'NAMED');
    $unil->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################
=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::NAMED object
  Examples:
    my $unil = Netdot::Exporter->new(type=>'NAMED');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    my $dir = Netdot->config->get('NAMED_DIR')
        || $self->throw_user('Netdot::Exporter::NAMED: NAMED_DIR not defined');

    $self->{NAMED_IP_MASTER} = Netdot->config->get('NAMED_IP_MASTER')
	|| $class->throw_user("Netdot::Exporter::NAMED: NAMED_IP_MASTER not defined");

    $self->{NAMED_REMOTE_DIR} = Netdot->config->get('NAMED_REMOTE_DIR')
	|| $class->throw_user("Netdot::Exporter::NAMED: NAMED_REMOTE_DIR not defined");

    $self->{BIND_SSH_SERVER} = Netdot->config->get('BIND_SSH_SERVER')
	|| $class->throw_user("Netdot::Exporter::NAMED: BIND_SSH_SERVER not defined");

    $self->{DEFAULT_DNSDOMAIN} = Netdot->config->get('DEFAULT_DNSDOMAIN')
	|| $class->throw_user("Netdot::Exporter::NAMED: DEFAULT_DNSDOMAIN not defined");

    $self->{gitdir} = Netdot->config->get('Git_NAMED_DIR')
	|| $self->throw_user('Git_NAMED_DIR not defined in config file!');

    # Execute remote command only there REMOTE_EXEC == 1
    $self->{remoteexec} = Netdot->config->get('REMOTE_EXEC') || 0;

    # Open output file for writing
    $self->{master}  = "$dir/named.master.conf";
    $self->{slave}   = "$dir/named.";
    $self->{forward} = "$dir/named.forward.conf";

    bless $self, $class;
    return $self;
}

############################################################################
=head2 generate_configs - Generate configuration files for NAMED

  Arguments:
    None
  Returns:
    True if successful
  Examples:
    $unil->generate_configs();
=cut
sub generate_configs {
	my ($self) = @_;

	# NS Look UP
	my %nslookup;

	# Default Domain
	my $default_domain = $self->{DEFAULT_DNSDOMAIN};

	# GET Zones
	my %zone_info;
	my %master_info;
	my $zoneq = $dbh->selectall_arrayref("SELECT id, name, mname, info FROM zone WHERE active=1 ORDER BY name");
	foreach my $row ( @$zoneq ) {
		my ($id, $name, $master, $info) = @$row;

		$zone_info{$name}{id}     = $id;
		$zone_info{$name}{master} = $master;
		$zone_info{$name}{ns}     = [];
		$zone_info{$name}{dnssec} = '';

		if (defined $info && $info ne '') {
		    foreach (split /\n/, $info) {
			if (/^DNSSEC: (.*)$/) {
			    $zone_info{$name}{dnssec} = lc($1);
			}
		    }
		}
		
		push (@{ $master_info{$master} }, $name);
	}

	# GET NS Records
	foreach my $zone ( keys %zone_info ) {
		my $id = $zone_info{$zone}{id};

		my $nsq = $dbh->selectall_arrayref("SELECT aip.version, aip.address, rrns.nsdname
			FROM zone, rr
			LEFT OUTER JOIN (ipblock aip, rraddr) ON (rr.id=rraddr.rr AND aip.id=rraddr.ipblock)
			LEFT OUTER JOIN rrns ON rr.id=rrns.rr
			WHERE rr.zone=zone.id AND zone.id=$id AND rr.name='\@' AND rr.active=1");

		foreach my $row ( @$nsq ) {
			my ($version, $address, $ns) = @$row;
			push (@{ $zone_info{$zone}{ns} }, $ns);
			$nslookup{$ns} = [];
		}
	}

	# GET IP for NS LOOK UP
	use Net::DNS;
	my $res = Net::DNS::Resolver->new;
	foreach my $data ( keys %nslookup ) {
		my $q4 = $res->query($data, "A");
		my $q6 = $res->query($data, "AAAA");
		if (defined $q6) {
			foreach my $rr ($q6->answer) {
				next unless ($rr->type eq "AAAA");
				push (@{ $nslookup{$data} }, $rr->address);
			}
		}
		if (defined $q4) {
			foreach my $rr ($q4->answer) {
				next unless ($rr->type eq "A");
				push (@{ $nslookup{$data} }, $rr->address);
			}
		}
	}

	# Hidden Master or Forward File
	foreach my $type ( qw /master forward/ ) {
		my $file = $self->{$type};
		$self->{out} = $self->open_and_lock($file);

		$self->print_header(type=>$type);

		foreach my $zone ( sort keys %zone_info ) {
			my @dns = ();

			foreach my $ns (@{ $zone_info{$zone}{ns} }) {
				push (@dns, @{ $nslookup{$ns} });
			}
			push (@dns, 'none') if (@dns == 0);
			push (@dns, '');

			my $dnssec = $zone_info{$zone}{dnssec};

			$self->print_domain(type=>$type, domain=>$zone, ns=>\@dns, dnssec=>$dnssec)
			    if ($type eq 'master');
			$self->print_domain(type=>$type, domain=>$zone, ns=>\@dns)
			    if ($type ne 'master');
		}

		$logger->info("Netdot::Exporter::NAMED: Configuration written to file: ".$file);
		close($self->{out});
		system ("/usr/bin/scp $file ".$self->{BIND_SSH_SERVER}.":".$self->{NAMED_REMOTE_DIR})
		    if ($self->{remoteexec} == 1);
		system ('/bin/cp '.$file.' '.$self->{gitdir}.'/');
	}

	# Slave Master File
	foreach my $type ( keys %master_info ) {
		my $file = $self->{slave} . "$type.conf";
		$self->{out} = $self->open_and_lock($file);

		$self->print_header(type=>$type);

		foreach my $zone ( sort keys %zone_info ) {
			my @dns = ();
			my @dnss = ();

			foreach my $ns (@{ $zone_info{$zone}{ns} }) {
				next if ($ns eq $type);
				push (@dns, @{ $nslookup{$ns} });
				push (@dnss, @{ $nslookup{$ns} }) unless ($ns =~ /$default_domain$/i);
			}
			push (@dns, 'none') if (@dns == 0);
			push (@dnss, 'none') if (@dnss == 0);
			push (@dns, '');
			push (@dnss, '');

			$self->print_domain(type=>'forward', domain=>$zone, ns=>\@dns) if ($zone_info{$zone}{master} ne $type);
			$self->print_domain(type=>'slave', domain=>$zone, ns=>\@dnss) if ($zone_info{$zone}{master} eq $type);
		}

		$logger->info("Netdot::Exporter::NAMED: Configuration written to file: ".$file);
		close($self->{out});

		system ("/usr/bin/scp $file ".$self->{BIND_SSH_SERVER}.":".$self->{NAMED_REMOTE_DIR})
		    if ($self->{remoteexec} == 1);
		system ("/bin/cp $file ".$self->{gitdir}.'/');
	}
}

#####################################################################################
sub print_header {
	my ($self, %argv) = @_;

	my $out = $self->{out};
	my $type = $argv{type};

	use POSIX qw(strftime);
	my $now = strftime "%d.%m.%Y %H:%M:%S", localtime;

	print $out "//\n";
	print $out "// Name:        named.$type.conf\n";
	print $out "// Purpose:     Database file for $type DNS.\n";
	print $out "//              Do not edit this file. Changes will be overwriten with Netdot\n";
	print $out "//\n";
	print $out "// Last Update: $now\n";
	print $out "//\n";
	print $out "//\n";
}

#####################################################################################
sub print_domain {
    my ($self, %argv) = @_;

    my $type        = $argv{type};
    my $domain	= $argv{domain};
    my $dnssec	= $argv{dnssec};
    my $export	= $argv{export};
    my @ns		= @{$argv{ns}};

    my $out		= $self->{out};

    if ($type eq 'master') {
# Master
	print $out "zone \"$domain\" in {\n";
	print $out "\ttype master;\n";
	print $out "\tfile \"netdot/zone/$domain\";\n";
	print $out "\tallow-transfer { ".join('; ', uniq @ns)."};\n";
	print $out "\talso-notify { ".join('; ', uniq @ns)."};\n";
	if ($dnssec eq 'inline') {
	    print $out "\n\t# look for dnssec keys here:\n";
	    print $out "\tkey-directory \"/var/named/netdot/keys\";\n\n";
	    print $out "\t# publish and activate dnssec keys:\n";
	    print $out "\tauto-dnssec maintain;\n\n";
	    print $out "\t# use inline signing:\n";
	    print $out "\tinline-signing yes;\n";
	}
	print $out "};\n";
    }
    if ($type eq 'slave') {
# Slave
	print $out "zone \"$domain\" in {\n";
	print $out "\ttype slave;\n";
	print $out "\tfile \"slaves/$domain\";\n";
	print $out "\tallow-transfer { ".join('; ', uniq @ns)."};\n";
	print $out "\tmasters { " . $self->{NAMED_IP_MASTER} . "; };\n";
	print $out "};\n";
    }
    if ($type eq 'forward') {
# Forward
	print $out "zone \"$domain\" in {\n";
	print $out "\ttype forward;\n";
	print $out "\tforwarders { ".join('; ', uniq @ns)."};\n";
	print $out "};\n";
    }
}

=head1 AUTHOR

Vincent Magnin, << <vincent.magnin at unil.ch> >>

=head1 COPYRIGHT & LICENSE

Copyright 2011 University of Lausanne, all rights reserved.

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
