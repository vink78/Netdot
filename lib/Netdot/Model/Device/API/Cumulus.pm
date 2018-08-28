package Netdot::Model::Device::API::Cumulus;

use base 'Netdot::Model::Device::API';
use warnings;
use strict;
use JSON;
use MIME::Base64 qw(encode_base64);

my $logger = Netdot->log->get_logger('Netdot::Model::Device');
my $json_obj = new JSON;

=head1 NAME

Netdot::Model::Device::API::Cumulus - Cumulus API Class

=head1 SYNOPSIS

 Overrides certain methods from the Device class. More Specifically, methods in 
 this class try to obtain ARP/ND caches via JSON API.

=head1 INSTANCE METHODS
=cut

############################################################################

=head2 get_arp - Fetch ARP tables

  Arguments:
    session - SNMP session (optional)
  Returns:
    Hashref
  Examples:
    my $cache = $self->get_arp(%args)
=cut

sub get_arp {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_arp');
    my $host = $self->fqdn;

    unless ( $self->collect_arp ){
	$logger->debug(sub{"Device::API::Cumulus::_get_arp: $host excluded ".
			       "from ARP collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::API::Cumulus::_get_arp: $host in downtime. ".
			       "Skipping"});
	return;
    }

    # This will hold both ARP and v6 ND caches
    my %cache;

    ### v4 ARP
    my $start = time;
    my $arp_count = 0;
    my $arp_cache = $self->_get_arp_from_api(host=>$host);

    foreach ( keys %$arp_cache ){
	$cache{'4'}{$_} = $arp_cache->{$_};
	$arp_count+= scalar(keys %{$arp_cache->{$_}})
    }
    my $end = time;
    $logger->info(sub{ sprintf("$host: ARP cache fetched. %s entries in %s", 
			       $arp_count, $self->sec2dhms($end-$start) ) });


    if ( $self->config->get('GET_IPV6_ND') ){
	### v6 ND
	$start = time;
	my $nd_count = 0;
	my $nd_cache  = $self->_get_v6_nd_from_api(host=>$host);

	# Here we have to go one level deeper in order to
	# avoid losing the previous entries
	foreach ( keys %$nd_cache ){
	    foreach my $ip ( keys %{$nd_cache->{$_}} ){
		$cache{'6'}{$_}{$ip} = $nd_cache->{$_}->{$ip};
		$nd_count++;
	    }
	}
	$end = time;
	$logger->info(sub{ sprintf("$host: IPv6 ND cache fetched. %s entries in %s", 
				   $nd_count, $self->sec2dhms($end-$start) ) });
    }

    return \%cache;
}

############################################################################

=head2 get_fwt - Fetch forwarding tables

  Arguments:
    session - SNMP session (optional)    
  Returns:
    Hashref
  Examples:
    my $fwt = $self->get_fwt(%args)
=cut

sub get_fwt {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_fwt');
    my $host = $self->fqdn;
    my $fwt = {};

    unless ( $self->collect_fwt ){
	$logger->debug(sub{"Device::API::Cumulus::get_fwt: $host excluded from FWT collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::API::Cumulus::get_fwt: $host in downtime. Skipping"});
	return;
    }

    my $start = time;
    my $fwt_count = 0;

    $fwt = $self->_get_fwt_from_api(host=>$host);

    map { $fwt_count+= scalar(keys %{$fwt->{$_}}) } keys %$fwt;

    my $end = time;
    $logger->debug(sub{ sprintf("$host: FWT fetched. %s entries in %s",
	$fwt_count, $self->sec2dhms($end-$start) ) });

    return $fwt;
}

sub _api_cumulus {
    my ($self, %argv) = @_;
    $self->isa_object_method('_api_cumulus');

    my $host = $argv{host};
    my $login = $argv{login};
    my $password = $argv{password};
    my $cmd = '{"cmd": "'.$argv{cmd}.'"}';
    my %header;
    $header{'Content-Type'} = 'application/json';
    $header{'Authorization'} = 'Basic '.encode_base64($login.':'.$password, '');

    return $json_obj->decode($self->_api_url(method=>'POST', url=>"https://$host:8080/nclu/v1/rpc", content=>$cmd, header=>\%header));
}

############################################################################
# _get_arp_from_api - Fetch ARP tables via JSON API
#
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_arp_from_api(host=>'foo');
#
sub _get_arp_from_api {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_arp_from_api');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my $output = $self->_api_cumulus(%$args, host=>$host, cmd=>"show evpn arp-cache vni all json");
    my %cache;

    # MAP interface names to IDs
    my %int_names;
    foreach my $int ( $self->interfaces ){
	my $name = $self->_reduce_iname($int->name);
	$int_names{$name} = $int->id;
    }

    # Read JSON
    foreach my $vlan (keys %$output) {
	foreach my $entry (keys %{$output->{$vlan}}) {
	    next if ($entry eq 'numArpNd');
	    next unless ($entry =~ /^\d+.\d+.\d+.\d+$/);
	    next unless ($output->{$vlan}->{$entry});
	    next unless ($output->{$vlan}->{$entry}->{'type'});
	    next unless ($output->{$vlan}->{$entry}->{'type'} eq 'local');

	    $cache{"vlan$vlan"}{$entry} = $output->{$vlan}->{$entry}->{'mac'};
	}
    }

    return $self->_validate_arp(\%cache, 4);
}

############################################################################
# _get_v6_nd_from_api - Fetch IPv6 ND tables via JSON API
#
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_v6_nd_from_api(host=>'foo');
#
sub _get_v6_nd_from_api {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_v6_nd_from_api');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my $output = $self->_api_cumulus(%$args, host=>$host, cmd=>"show evpn arp-cache vni all json");
    my %cache;

    # MAP interface names to IDs
    my %int_names;
    foreach my $int ( $self->interfaces ){
	my $name = $self->_reduce_iname($int->name);
	$int_names{$name} = $int->id;
    }

    # Read JSON
    foreach my $vlan (keys %$output) {
	foreach my $entry (keys %{$output->{$vlan}}) {
	    next if ($entry eq 'numArpNd');
	    next unless ($entry =~ /^.*:.*:.*$/);
	    next unless ($output->{$vlan}->{$entry});
	    next unless ($output->{$vlan}->{$entry}->{'type'});
	    next unless ($output->{$vlan}->{$entry}->{'type'} eq 'local');

	    $cache{"vlan$vlan"}{$entry} = $output->{$vlan}->{$entry}->{'mac'};
	}
    }

    return $self->_validate_arp(\%cache, 6);
}

############################################################################
# _get_fwt_from_api - Fetch FWT tables via JSON API
#
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_fwt_from_api(host=>'foo');
#
sub _get_fwt_from_api {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_fwt_from_api');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my $output = $self->_api_cumulus(%$args, host=>$host, cmd=>"show bridge macs json");

    # MAP interface names to IDs
    my %int_names;
    foreach my $int ( $self->interfaces ){
	my $name = $self->_reduce_iname($int->name);
	$int_names{$name} = $int->id;
    }

    my %fwt;

    # Read JSON
    foreach my $entry ( @{$output} ) {
	my ($iname, $intid, $mac);

	$mac   = $entry->{'mac'};
	$iname = $entry->{'dev'};

	next unless (defined $int_names{$iname});
	$intid = $int_names{$iname};

	eval {
	    $mac = PhysAddr->validate($mac);
	};
	if ( my $e = $@ ){
	    $logger->debug(sub{"Device::API::Cumulus::_get_fwt_from_api: ".
		"$host: Invalid MAC: $e" });
	    next;
	}

	# Store in hash
	$fwt{$intid}{$mac} = 1;

	$logger->debug(sub{"Device::API::Cumulus::_get_fwt_from_api: ".
	    "$host: $iname -> $mac" });
    }

    return \%fwt;
}

############################################################################
# _reduce_iname
#  Convert "*Ethernet0/1/2 into "0/1/2" to match the different formats
#
# Arguments: 
#   string
# Returns:
#   string
#
sub _reduce_iname{
    my ($self, $name) = @_;
    return unless $name;
    $name =~ s/ //;
    $name =~ s/Intel Corporation 82579LM Gigabit Network Connection/eth0/;

    return $name;
}

=head1 AUTHOR

Vincent Magnin <vincent.magnin at unil.ch>

=head1 COPYRIGHT & LICENSE

Copyright 2018 Vincent Magnin

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

