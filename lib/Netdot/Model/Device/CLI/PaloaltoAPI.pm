package Netdot::Model::Device::CLI::PaloaltoAPI;

use base 'Netdot::Model::Device::CLI';
use warnings;
use strict;
use URI::Escape;
use LWP::UserAgent;  
use HTTP::Request;
use XML::LibXML; 

my $logger = Netdot->log->get_logger('Netdot::Model::Device');

# Some regular expressions
my $IPV4 = Netdot->get_ipv4_regex();
my $IPV6 = Netdot->get_ipv6_regex();
my $CISCO_MAC = '\w{4}\.\w{4}\.\w{4}';

=head1 NAME

Netdot::Model::Device::CLI::PaloaltoAPI - Paloalto API Class

=head1 SYNOPSIS

 Overrides certain methods from the Device class. More Specifically, methods in 
 this class try to obtain forwarding tables and ARP/ND caches via CLI
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
    my $arp_cache = $self->_get_arp_from_cli(host=>$host) ||
	$self->_get_arp_from_snmp(session=>$argv{session});
    foreach ( keys %$arp_cache ){
	$cache{'4'}{$_} = $arp_cache->{$_};
	$arp_count+= scalar(keys %{$arp_cache->{$_}})
    }
    my $end = time;
    $logger->info(sub{ sprintf("$host: ARP cache fetched. %s entries in %s", 
			       $arp_count, $self->sec2dhms($end-$start) ) });
    

#    if ( $self->config->get('GET_IPV6_ND') ){
#	### v6 ND
#	$start = time;
#	my $nd_count = 0;
#	my $nd_cache  = $self->_get_v6_nd_from_cli(host=>$host) ||
#	    $self->_get_v6_nd_from_snmp($argv{session});
#	# Here we have to go one level deeper in order to
#	# avoid losing the previous entries
#	foreach ( keys %$nd_cache ){
#	    foreach my $ip ( keys %{$nd_cache->{$_}} ){
#		$cache{'6'}{$_}{$ip} = $nd_cache->{$_}->{$ip};
#		$nd_count++;
#	    }
#	}
#	$end = time;
#	$logger->info(sub{ sprintf("$host: IPv6 ND cache fetched. %s entries in %s", 
#				   $nd_count, $self->sec2dhms($end-$start) ) });
#    }

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
	$logger->debug(sub{"Device::PaloaltoAPI::get_fwt: $host excluded from FWT collection. Skipping"});
	return;
    }
    if ( $self->is_in_downtime ){
	$logger->debug(sub{"Device::PaloaltoAPI::get_fwt: $host in downtime. Skipping"});
	return;
    }

    my $start     = time;
    my $fwt_count = 0;
    
#    # Try CLI, and then SNMP 
#    $fwt = $self->_get_fwt_from_cli(host=>$host) ||
#	$self->_get_fwt_from_snmp(session=>$argv{session});
#
#    map { $fwt_count+= scalar(keys %{$fwt->{$_}}) } keys %$fwt;
    my $end = time;
    $logger->debug(sub{ sprintf("$host: FWT fetched. %s entries in %s", 
				$fwt_count, $self->sec2dhms($end-$start) ) });
   return $fwt;

}

sub _api_cmd {
    my ($self, %argv) = @_;
    $self->isa_object_method('_api_cmd');

    my $URL = $argv{url};

    my $ua = LWP::UserAgent->new();
    $ua->ssl_opts(verify_hostname => 0);
    $ua->ssl_opts(SSL_verify_mode => 0x00);

    my $header = HTTP::Request->new(GET => $URL);  
    my $request = HTTP::Request->new('GET', $URL, $header);  
    my $response = $ua->request($request);  

    my $ret;
    if ($response->is_success){  
	$ret = $response->content;
    } elsif ($response->is_error) {
	print "Error:$URL\n";  
	print $response->error_as_HTML;  
    }

    return $ret;
}

############################################################################
#_get_arp_from_cli - Fetch ARP tables via CLI
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_arp_from_cli(host=>'foo');
#
sub _get_arp_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_arp_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_api_token(host=>$host);
    return unless ref($args) eq 'HASH';

    my $key = $args->{'token'};

    my $output = $self->_api_cmd(%$args, url=>"https://$host/api/?type=op&key=$key&cmd=".uri_escape("<show><arp><entry name='all'/></arp></show>"));

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
#_get_v6_nd_from_cli - Fetch ARP tables via CLI
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#   Examples:
#     $self->_get_v6_nd_from_cli(host=>'foo');
#
sub _get_v6_nd_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_v6_nd_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_credentials(host=>$host);
    return unless ref($args) eq 'HASH';

    my @output = $self->_cli_cmd(%$args, host=>$host, cmd=>'show ipv6 neighbor | nomore', personality=>'brocade');
    # If you have defined VRF, you can uncomment the following lines:
    # # Get additional ARP Tables for VRF 'vrf1' and 'vrf2':
    @output = (@output, $self->_cli_cmd(%$args, host=>$host, cmd=>'show ipv6 neighbor vrf backend | nomore', personality=>'brocade'));

    my %cache;
    foreach my $line ( @output ) {
	my ($ip, $mac, $iname);
	chomp($line);
	# Lines look like this:
	# 2001:620:610:12::53                           f8bc.1246.9cd0  Ve  4         yes           01:54:57    Dynamic 
	if ( $line =~ /^($IPV6)\s+($CISCO_MAC)\s+Ve\s+(\d+)\s+(\S+)/ ) {
	    $ip    = $1;
	    $mac   = $2;
	    $iname = 'Vlan '.$3;
	}else{
	    $logger->debug(sub{"Device::CLI::PaloaltoAPI::_get_v6_nd_from_cli: line did not match criteria: $line" });
	    next;
	}
	unless ( $iname && $ip && $mac ){
	    $logger->debug(sub{"Device::PaloaltoAPI::_get_v6_nd_from_cli: Missing information: $line"});
	    next;
	}
	$cache{$iname}{$ip} = $mac;
    }
    return $self->_validate_arp(\%cache, 6);
}

############################################################################
#_get_fwt_from_cli - Fetch forwarding tables via CLI
#
#    
#   Arguments:
#     host
#   Returns:
#     Hash ref.
#    
#   Examples:
#     $self->_get_fwt_from_cli();
#
#
sub _get_fwt_from_cli {
    my ($self, %argv) = @_;
    $self->isa_object_method('_get_fwt_from_cli');

    my $host = $argv{host};
    my $args = $self->_get_api_token(host=>$host);
    return unless ref($args) eq 'HASH';

    my @output = $self->_api_cmd(%$args, host=>$host, uri=>"/api/?type=op&command=<show><arp><entry name='all'/></arp></show>");

    # MAP interface names to IDs
    my %int_names;
    foreach my $int ( $self->interfaces ){
	my $name = $self->_reduce_iname($int->name);
	$int_names{$name} = $int->id;
    }
    

    my ($iname, $mac, $intid, $vlan);
    my %fwt;
    
    foreach my $line ( @output ) {
	chomp($line);
	if ( $line =~ /^(\d+)\s+($CISCO_MAC)\s+(Dynamic|Static)\s+\S+\s+Po\s+(\d+)/ ) { # VDX Syntax
	    # Output look like this:
	    # VlanId   Mac-address       Type     State        Ports
	    # 4        02e0.5200.251e    System   Active       XX 1/X/X
	    # 4        748e.f8d6.1a71    Dynamic  Active       Po 2
	    $vlan  = $1; 
	    $mac   = $2;
#	    $iname = '0/'.$3;
	    $iname = 'Port-channel '.$4;
	}elsif ( $line =~ /^(\d+)\s+($CISCO_MAC)\s+System\s+\S+\s+/ ) { # Exclude System
	    next;
	}else{
	    $logger->debug(sub{"Device::CLI::PaloaltoAPI::_get_fwt_from_cli: ".
				   "line did not match criteria: '$line'" });
	    next;
	}
	$iname = $self->_reduce_iname($iname);
	my $intid = $int_names{$iname};

	unless ( $intid ) {
	    $logger->warn("Device::CLI::PaloaltoAPI::_get_fwt_from_cli: ".
			  "$host: Could not match $iname to any interface names");
	    next;
	}
	
	eval {
	    $mac = PhysAddr->validate($mac);
	};
	if ( my $e = $@ ){
	    $logger->debug(sub{"Device::CLI::PaloaltoAPI::_get_fwt_from_cli: ".
				   "$host: Invalid MAC: $e" });
	    next;
	}	

	# Store in hash
	$fwt{$intid}{$mac} = 1;
	$logger->debug(sub{"Device::CLI::PaloaltoAPI::_get_fwt_from_cli: ".
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

