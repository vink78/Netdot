package Netdot::Exporter::BIND;

use base 'Netdot::Exporter';
use warnings;
use strict;
use Data::Dumper;

my $logger = Netdot->log->get_logger('Netdot::Exporter');

=head1 NAME

Netdot::Exporter::BIND - Read relevant info from Netdot and build BIND zone files

=head1 SYNOPSIS

    my $bind = Netdot::Exporter->new(type=>'BIND');
    $bind->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################

=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::BIND object
  Examples:
    my $bind = Netdot::Exporter->new(type=>'BIND');
=cut

sub new{
    my ($class, %argv) = @_;
    my $self = {};

    bless $self, $class;
    return $self;
}

############################################################################

=head2 generate_configs - Generate zone files for BIND

  Arguments:
    Hashref with the following keys:
      zones  - Array ref.  List of zone names to export.
      nopriv - Exclude private data from zone file (TXT and HINFO)
  Returns:
    True if successful
  Examples:
    $bind->generate_configs();
=cut

sub generate_configs {
    my ($self, %argv) = @_;

    my @zones;

    if ( $argv{zones} ){
	unless ( ref($argv{zones}) eq 'ARRAY' ){
	    $self->throw_fatal("zones argument must be arrayref!");
	}
	foreach my $name ( @{$argv{zones}} ){
	    if ( Zone->search(name=>$name) ){
		push @zones, Zone->search(name=>$name)->first;
	    }else{
		$self->throw_user("Zone $name not found");
	    }
	}
    }elsif ( $argv{zone_ids} ){
	unless ( ref($argv{zone_ids}) eq 'ARRAY' ){
	    $self->throw_fatal("zone_ids argument must be arrayref!");
	}
	foreach my $id ( @{$argv{zone_ids}} ){
	    if ( my $zone = Zone->retrieve($id) ){
		push @zones, $zone;
	    }else{
		$self->throw_user("Zone $id not found");
	    }
	}

    }else{
	@zones = Zone->retrieve_all();
    }

    my $remotedir = Netdot->config->get('BIND_REMOTE_DIR')
	|| $self->throw_user('BIND_REMOTE_DIR not defined in config file!');

    my $sshserver = Netdot->config->get('BIND_SSH_SERVER')
	|| $self->throw_user('BIND_SSH_SERVER not defined in config file!');

    my $reloadcmd = Netdot->config->get('BIND_RELOAD_CMD')
	|| $self->throw_user('BIND_RELOAD_CMD not defined in config file!');

    my $gitdir = Netdot->config->get('Git_BIND_DIR')
	|| $self->throw_user('Git_BIND_DIR not defined in config file!');

    # Execute remote command only there REMOTE_EXEC == 1
    my $remoteexec = Netdot->config->get('REMOTE_EXEC') || 0;

    my @changes = ();

    foreach my $zone ( @zones ){
	next unless $zone->active;
	eval {
	    my @pending = HostAudit->search(zone=>$zone->name, pending=>1);
	    Netdot::Model->do_transaction(sub{
		if ( @pending || $argv{force} ){
		    my $path = $self->print_zone_to_file(zone=>$zone, nopriv=>$argv{nopriv});
		    # Need to query again because the above method updates the serial
		    # which creates another hostaudit record
		    @pending = HostAudit->search(zone=>$zone->name, pending=>1);
		    foreach my $record ( @pending ){
			# Un-mark audit records as pending
			$record->update({pending=>0});
		    }
		    $logger->info("Zone ".$zone->name." written to file: $path");

		    system ("/usr/bin/scp $path $sshserver:$remotedir")
		        if ($remoteexec == 1);
		    system ('/bin/cp '.$path.' '.$gitdir.'/');
		    push @changes, $zone->name;
		}else{
		    $logger->debug("Exporter::BIND::generate_configs: ".$zone->name.
				   ": No pending changes.  Use -f to force.");
		}
					  });
	};
	$logger->error($@) if $@;
    }

    if (@changes && $remoteexec == 1) {
	open (FOO, "/usr/bin/ssh $sshserver '$reloadcmd' |");
	while (<FOO>) {
	    chomp;
	    $logger->info( $_ );
	}
	close (FOO);
    }
}

############################################################################

=head2 print_zone_to_file -  Print the zone file using BIND syntax

 Args: 
    Hashref with following key/value pairs:
        zone    - Zone object
        nopriv  - Flag.  Exclude private data (TXT and HINFO)
  Returns: 
    Path of file written to
  Examples:
    my $path = $bind->print_to_file(zone=>$zone, nopriv=>1);

=cut

sub print_zone_to_file {
    my ($self, %argv) = @_;

    my $zone = $argv{zone};

    $self->throw_fatal("Missing required argument: zone")
	unless $zone;

    # Make sure that there are NS records
    my $apex = RR->search(name=>'@', zone=>$zone)->first 
    	|| $self->throw_user(sprintf('Zone %s: Apex record (@) not defined', $zone->name));

    my @ns_records = $apex->ns_records();
    $self->throw_user(sprintf("Zone %s has no NS records", $zone->name))
	unless @ns_records;
    
    my $rec = $zone->get_all_records();

    my $dir = Netdot->config->get('BIND_EXPORT_DIR') 
	|| $self->throw_user('BIND_EXPORT_DIR not defined in config file!');
    
    my $filename = $zone->export_file;
    unless ( $filename ){
	$logger->warn('Export filename not defined for this zone: '. $zone->name.' Using zone name.');
	$filename = $zone->name;
    }
    my $path = "$dir/$filename";
    my $fh = $self->open_and_lock($path);
    $zone->update_serial();

    print $fh "; Generated by Netdot -- http://netdot.uoregon.edu\n\n";

    # Print the default TTL
    print $fh '$TTL '.$zone->default_ttl."\n" if (defined $zone->default_ttl);

    # Print the SOA record
    print $fh $zone->soa_string . "\n";

    foreach my $name ( sort { $rec->{$a}->{order} <=> $rec->{$b}->{order} } keys %$rec ){
	foreach my $type ( qw/A AAAA TXT HINFO NS DS MX CNAME PTR NAPTR SRV LOC/ ){
	    if ( defined $rec->{$name}->{$type} ){
		# Special cases.  These are relatively rare and harder to print.
		if ( $type =~ /^(LOC|SRV|NAPTR)$/ ){
		    my $rrclass = 'RR'.$type;
		    foreach my $id ( sort keys %{$rec->{$name}->{$type}->{id}} ){
			my $rr = $rrclass->retrieve($id);
			print $fh $rr->as_text, "\n";
		    }
		}else{
		    foreach my $data ( sort keys %{$rec->{$name}->{$type}} ){
			if ( $argv{nopriv} && $type eq 'HINFO' ){
			    next;
			}
			my $ttl = $rec->{$name}->{$type}->{$data};
			if ( !defined $ttl || $ttl !~ /\d+/ ){
			    $logger->debug("$name $type: TTL not defined or invalid. Using Zone default");
			    $ttl = $zone->default_ttl;
			}
			if ( $type =~ /^(MX|NS|CNAME|PTR)$/ ){
			    # Add the final dot if necessary
			    $data .= '.' unless $data =~ /\.$/;
			}

			if ($type eq 'TXT' && length($data) > 254) {
			    my @subdata = unpack("(A254)*", $data);
			    $data = join "\" \"", @subdata;
			}

			my $line = "$name\t$ttl\tIN\t$type\t$data\n";

			if ( $argv{nopriv} && $type eq 'TXT' ){
			    # We're told to exclude TXT records
			    # Allow exceptions from config
			    if ( my @patterns = @{$self->config->get('TXT_RECORD_EXCEPTIONS')} ){
				foreach my $pattern ( @patterns ){
				    if ( $line =~ /$pattern/ ){
					print $fh $line;
					last;
				    }
				}
			    }
			}else{
			    print $fh $line;
			}
		    }
		}
	    }
	}
    }

    # Add any includes
    print $fh $zone->include . "\n" if defined $zone->include;

    print $fh "\n;#### EOF ####\n";

    close($fh);
    return $path;
}

=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>
Dongting Yu, C<< <dongting at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 University of Oregon, all rights reserved.

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
