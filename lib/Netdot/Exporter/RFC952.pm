package Netdot::Exporter::RFC952;

use base 'Netdot::Exporter';
use warnings;
use strict;
use Data::Dumper;

my $logger = Netdot->log->get_logger('Netdot::Exporter');

my $dbh = Netdot::Model->db_Main();


=head1 NAME

Netdot::Exporter::RFC952 - Read relevant info from Netdot and build a RFC952
    compliant hosts file.

=head1 SYNOPSIS

    my $rfc952 = Netdot::Exporter->new(type=>'RFC952');
    $rfc952->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################
=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::RFC952 object
  Examples:
    my $rfc952 = Netdot::Exporter->new(type=>'RFC952');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    foreach my $key ( qw /RFC952_DIR RFC952_FILE DEFAULT_DNSDOMAIN RFC952_SCP_TARGET RFC952_SITENAME Git_RFC952_DIR/ ){
	$self->{$key} = Netdot->config->get($key);
    }
     
    $self->{RFC952_FILE} || 
	$class->throw_user("Netdot::Exporter::RFC952: RFC952_FILE not defined");
    
    # Open output file for writing
    $self->{filename} = $self->{RFC952_DIR}."/".$self->{RFC952_FILE};

    bless $self, $class;

    $self->{out} = $self->open_and_lock($self->{filename});
    return $self;
}

############################################################################
=head2 generate_configs - Generate host file using RFC952

  Arguments:
    None
  Returns:
    True if successful
  Examples:
    $rfc952->generate_configs();
=cut
my %ubs;
my %reverse;

sub generate_configs {
    my ($self) = @_;

    # Get Entity info
    my $enq = $dbh->selectall_arrayref("
              SELECT id, aliases
              FROM   entity
              WHERE  aliases IS NOT NULL
             ");
    foreach my $row ( @$enq ) {
	my ($eid, $alias) = @$row;
	$ubs{$eid} = lc $alias;
    }

    # Get Site info
    my %site_info;
    my $siteq = $dbh->selectall_arrayref("
                SELECT sitesubnet.subnet, site.name
                FROM   site, sitesubnet
                WHERE  site.id = sitesubnet.site
               ");
    foreach my $row ( @$siteq ) {
	my ($subnet, $name) = @$row;
	push(@{$site_info{$subnet}{name}}, $name);
    }

    # Get Subnet info
    my %subnet_info;
    my $subnetq = $dbh->selectall_arrayref("
                  SELECT   id, inet_ntoa(address) AS `subnet`, prefix, used_by as `ub`, description
                  FROM     ipblock
                  WHERE    version=4
                      AND  status=5
                  ORDER BY address
                 ");
    foreach my $row ( @$subnetq ){
	my ($id, $subnet, $prefix, $ub, $description) = @$row;
	$subnet_info{$id}{subnet}      = $subnet."/".$prefix;
	$subnet_info{$id}{ub}          = $ub;
	$subnet_info{$id}{description} = $description;
    }

    # Get IP info
    my %ip_info;
    my $ipq = $dbh->selectall_arrayref("
              SELECT   id, address, inet_ntoa(address) AS `ip4`, status, parent as subnet, used_by as `ub`, description
              FROM     ipblock
              WHERE    parent>0
                  AND  version=4
                  AND  (status=3 OR status=6)
              ORDER BY address
             ");

    $self->print_header();

    my @zones = Zone->retrieve_all();
    my $defzone;

    for (my $i=0; $i<$#zones; $i++) {
	if ($zones[$i]->name eq $self->{DEFAULT_DNSDOMAIN}) {
	    $defzone = $zones[$i];
	    splice(@zones, $i, 1);
	}
    }
    unshift(@zones, $defzone) if (defined $defzone);

    foreach my $zone ( @zones ) {
	if ($zone->active) {
	    my $domain = $zone->name;
	    next if ( $domain =~ /\.arpa$/);
	    next if ( $domain =~ /^rpz\./);

	    my $rec = $zone->get_all_records();

	    my $default = '';
	    if ( defined $rec->{'@'}->{'A'} ) {
		foreach my $data ( keys %{$rec->{'@'}->{'A'}} ) {
		    $default = $data;
		}
	    }

	    my @dns;
	    my @extra;
	    if ( defined $rec->{'@'}->{'NS'} ) {
		foreach my $data ( keys %{$rec->{'@'}->{'NS'}} ) {
		    if (my @rr = RR->search(name=>$data)) {
			foreach my $r (@rr) {
			    if (my @a_records = $r->a_records) {
				foreach my $rraddr ( @a_records ){
				    my $ipb = $rraddr->ipblock;
				    if ($ipb->version eq '4') {
					push (@dns, $ipb->address);
				    }
				    $data = '';
				}
			    }
			}
		    }

		    # Use standard nslookup if data is not found
		    if ($data ne '') {
			eval {
			    use Socket;

			    my $address = inet_ntoa(inet_aton($data));
			    push (@dns, $address);
			    push (@extra, $data);
			};
		    }
		}
	    }
	    $self->print_domain(domain=>$domain, ns=>\@dns, default=>$default, extra=>\@extra) if ($domain ne 'lan');

	    if ($zone eq $defzone) {
		my $netq = $dbh->selectall_arrayref("
                SELECT   id, address, prefix, description as `desc`
                FROM     ipblock
                WHERE    parent IS NULL
                     AND asn IS NOT NULL
                     AND version=4
                ORDER BY address
               ");
		my $activeq = $dbh->selectall_arrayref("
                SELECT DISTINCT parent
                FROM            ipblock
                WHERE           parent IS NOT NULL
                            AND status=5
                            AND version=4
               ");
		my %active;
		foreach my $row ( @$activeq ){
		    my ($id) = @$row;
		    $active{$id} = 'true';
		}

		foreach my $row ( @$netq ){
		    my ($id, $address, $prefix, $desc) = @$row;
		    my $base = NetAddr::IP->new( $address )->addr();
		    my $subnet = NetAddr::IP->new( "$base/$prefix" );

		    my $split = $prefix;
		    if ($prefix < 9) { # Class A
			$split = 8;
		    } elsif ($prefix < 17) { # Class B
			$split = 16;
		    } elsif ($prefix < 25) { # Class C
			$split = 24;
		    }

		    foreach my $ip ( $subnet->split( $split ) ) {
			my $netbase = $ip->addr();
			$self->print_net(subnet=>$netbase, active=>$active{$id}, description=>$desc);
		    }
		}
	    }

	    my (%data);

	    foreach my $name ( sort { $rec->{$a}->{order} <=> $rec->{$b}->{order} } keys %$rec ){
		$name = lc($name);
		next if ($name eq '@');
		foreach my $type ( qw/A MX CNAME HINFO/ ){
		    if ( defined $rec->{$name}->{$type} ){
			foreach my $data ( keys %{$rec->{$name}->{$type}} ){
			    if ($type eq 'A' || $type eq 'CNAME') {
				if ($name ne 'mx') {
				    push(@{$data{$type}{$data}}, $name);
				}
			    } else {
				push(@{$data{$type}{$name}}, $data);
			    }
			}
		    }
		}
	    }

	    my $prev_address = 0;
	    my $prev_subnet = 0;

	    foreach my $row ( @$ipq ){
		my ($id, $address, $ip, $status, $subnet, $ub, $description) = @$row;
		my $cpu = '';
		my $os = '';

		if (defined $subnet_info{$subnet}) {
		    $ub   = $subnet_info{$subnet}{ub} if (!defined $ub || $ub == 0);
		}

		if (defined $data{'A'}{$ip}) {
		    if ($prev_subnet != $subnet && $zone eq $defzone) {
			if (defined $subnet_info{$subnet}) {
			    $self->print_subnet(subnet=>$subnet_info{$subnet}{subnet}, description=>$subnet_info{$subnet}{description}, site=>$site_info{$subnet}{name});
			    $prev_address = 0;
			}
		    }
		    $prev_subnet = $subnet;

		    if ($prev_address + 1 < $address && $prev_address > 0) {
			$self->print_emptyline();
		    }
		    $prev_address = $address;

		    my @name = @{$data{'A'}{$ip}};
		    my $protocol = '';
		    if (defined $data{'CNAME'}{$name[0].'.'.$domain} ) {
			push(@name, @{$data{'CNAME'}{$name[0].'.'.$domain}});
		    }
		    if (defined $data{'MX'}{$name[0]} ) {
			$protocol = "TCP/SMTP";
		    }
		    if (defined $data{'HINFO'}{$name[0]} ) {
			my @H = @{$data{'HINFO'}{$name[0]}};
			my @hinfo = split /[\ \"]+/, $H[0];
			$cpu = lc $hinfo[1];
			$cpu = '' if ($cpu eq 'none');
			$os = lc $hinfo[2];
			$os = '' if ($os eq 'none');
		    }

		    $cpu = 'dhcp' if ($status == 3);
		    $os  = ''     if ($status == 3);

		    $self->print_host(ip=>$ip, name=>\@name, protocol=>$protocol, ub=>$ub, cpu=>$cpu, os=>$os);
		}
	    }
	}
    }

    close($self->{out});

    $logger->info("Netdot::Exporter::RFC952: Configuration written to file: ".$self->{filename});
    system ("/usr/bin/scp ".$self->{filename}.' '.$self->{RFC952_SCP_TARGET});
    system ('/usr/bin/scp '.$self->{filename}.' reseau\@prdres:scripts/');
    system ('/bin/cp '.$self->{filename}.' '.$self->{Git_RFC952_DIR}.'/');

    open (FOO, "/usr/bin/ssh reseau\@hns 'sudo /var/named/netdot/bin/update_named -i -u' |");
    while (<FOO>) {
	chomp;
	$logger->info( $_ );
    }
    close (FOO);
}


#####################################################################################
sub print_header {
    my ($self, %argv) = @_;

    my $out = $self->{out};

    use POSIX qw(strftime);
    my $now = strftime "%d.%m.%Y %H:%M:%S", localtime;

    print $out ";;;;\n";
    print $out ";;;; TABLE DES ADRESSES TCP/IP DE ".(uc $self->{RFC952_SITENAME})."\n";
    print $out ";;;; Version du $now\n";
    print $out ";;;;\n";
    print $out ";;;;\n";
    print $out ";;;; Cette table contient les noms et les adresses de tous les reseaux,\n";
    print $out ";;;; routeurs, ordinateurs du reseau TCP/IP de ".$self->{RFC952_SITENAME}."\n";
    print $out ";;;; Le format de cette table est conforme a celui definit par la RFC-952\n";
    print $out ";;;; du DoD.\n";
    print $out ";;;;\n";
}

#####################################################################################
sub print_domain {
    my ($self, %argv) = @_;

    my $domain    = $argv{domain};
    my @ns        = @{$argv{ns}};
    my @extra     = @{$argv{extra}};
    my $default   = $argv{default};

    my $out       = $self->{out};

    print $out ";;;;\n";
    print $out ";;;;\n";
    print $out ";;;;\$\$\$\$ D O M A I N ".uc($domain)." \$\$\$\$\n";
    print $out ";;;;\n";
    print $out "DOMAIN:".join(',', @ns).":$domain:$default:".join(',', @extra)."\n";
    print $out ";;;;\n";
    print $out ";;;;Following IP-addrs also used in ".$self->{DEFAULT_DNSDOMAIN}." domain\n" if ($domain ne $self->{DEFAULT_DNSDOMAIN});
}

sub print_emptyline {
    my ($self, %argv) = @_;

    my $out = $self->{out};

    print $out ";;;;\n";
}

sub print_net {
    my ($self, %argv) = @_;

    my $subnet      = $argv{subnet};
    my $description = $argv{description};
    my $active      = $argv{active};

    my $out         = $self->{out};

    if ( ! defined $description ) {
	$description = '';
	$logger->info("Netdot::Exporter::RFC952: Warning: Description of subnet '".$subnet."' not defined.");
    } elsif ($description eq 'NO EXPORT') {
	return;
    }

    if ( defined $active ) {
	print $out "NET:$subnet:$description:internet active\n";
    } else {
	print $out "NET:$subnet:ripe:$description\n";
    }
}

sub print_subnet {
    my ($self, %argv) = @_;

    my $subnet      = $argv{subnet};
    my $description = $argv{description};
    my @site        = ();
    @site = @{$argv{site}} if defined $argv{site};

    if ( ! defined $description ) {
	$description = '';
	$logger->info("Netdot::Exporter::RFC952: Warning: Description of subnet '".$subnet."' not defined.");
    }

    my $out         = $self->{out};

    print $out ";;;;\n";
    printf $out ";;;;\$\$\$\$ PREFIX %-30s \$\$\$\$\n", $subnet;
    printf $out ";;;;\$\$\$\$        %-30s \$\$\$\$\n", $description;
    printf $out ";;;;\$\$\$\$ SITE   %-30s \$\$\$\$\n", join(',', @site);
    print $out ";;;;\n";
}

#####################################################################################
sub print_host {
    my ($self, %argv) = @_;

    my $ip        = $argv{ip};
    my @name      = @{$argv{name}};
    my $cpu       = $argv{cpu};
    my $os        = $argv{os};
    my $protocol  = $argv{protocol};
    my $ub        = $argv{ub};
    my $active    = $argv{avtive};

    my $out       = $self->{out};

    $ip       = "0.0.0.0" if (!defined $ip);
    $cpu      = ""        if (!defined $cpu);
    $os       = ""        if (!defined $os);
    $protocol = ""        if (!defined $protocol);
    $ub       = ""        if (!defined $ub);
    $ub       = $ubs{$ub} if (defined $ubs{"$ub"});
    $active   = "true"    if (!defined $active);

    my $comment = "";
    $comment  = ";;;;"    if ($active ne 'true');
    $protocol = '' if ($name[0] eq 'hec' || $name[0] eq 'bud' || $name[0] eq 'fef' || $name[0] eq 'idheap');

    print $out $comment."HOST:$ip:".join(',', @name).":$cpu:$os:$protocol:$ub:\n";
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
