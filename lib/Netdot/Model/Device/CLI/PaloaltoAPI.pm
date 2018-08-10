package Netdot::Model::Device::CLI::PaloaltoAPI;

use base 'Netdot::Model::Device::CLI';
use warnings;
use strict;
use URI::Escape;
use XML::LibXML; 

my $logger = Netdot->log->get_logger('Netdot::Model::Device');

=head1 NAME

Netdot::Model::Device::CLI::PaloaltoAPI - Paloalto API Class

=head1 SYNOPSIS

 Overrides certain methods from the Device class. More Specifically, methods in 
 this class try to obtain ARP/ND caches via XML API
 instead of via SNMP.

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
	$logger->debug(sub{"Device::PaloaltoAPI::_get_arp: $host excluded ".
			       "from ARP collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::PaloaltoAPI::_get_arp: $host in downtime. ".
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

    $logger->debug(sub{ sprintf("$host: FWT is not supported via Paloalto API") } );

    return $fwt;
}

sub _api_palo {
    my ($self, %argv) = @_;
    $self->isa_object_method('_api_palo');

    my $host = $argv{host};
    my $key = $argv{token};
    my $cmd = uri_escape($argv{cmd});

    return $self->_api_url(url=>"https://$host/api/?type=op&key=$key&cmd=$cmd");
}



############################################################################
#_get_arp_from_api - Fetch ARP tables via CLI
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
    my $args = $self->_get_api_token(host=>$host);
    return unless ref($args) eq 'HASH';

    my $output = $self->_api_palo(%$args, host=>$host, cmd=>"<show><arp><entry name='all'/></arp></show>");

    my %cache;
    my $parser = XML::LibXML->new();
    my $dom = XML::LibXML->load_xml(string => $output);

    # Read XML
    foreach my $entry ( $dom->findnodes('//entry') ) {
	my ($iname, $ip, $mac, $intid);
	
	$ip    = $entry->findvalue('./ip');
        $mac   = $entry->findvalue('./mac');
	$iname = $entry->findvalue('./interface');

	next if ($ip eq '0.0.0.0'); # Do not use this address
	$cache{$iname}{$ip} = $mac;
    }

    return $self->_validate_arp(\%cache, 4);
}

############################################################################
#_get_v6_nd_from_api - Fetch ARP tables via CLI
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
    my $args = $self->_get_api_token(host=>$host);
    return unless ref($args) eq 'HASH';

    my $output = $self->_api_palo(%$args, host=>$host, cmd=>"<show><neighbor><interface><entry name='all'/></interface></neighbor></show>");

    my %cache;
    my $parser = XML::LibXML->new();
    my $dom = XML::LibXML->load_xml(string => $output);

    # Read XML
    foreach my $entry ( $dom->findnodes('//entry') ) {
	my ($iname, $ip, $mac, $intid);
	
	$ip    = $entry->findvalue('./ip');
        $mac   = $entry->findvalue('./mac');
	$iname = $entry->findvalue('./interface');

	next if ($ip eq '::'); # Do not use this address
	$cache{$iname}{$ip} = $mac;
    }

    return $self->_validate_arp(\%cache, 6);
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

