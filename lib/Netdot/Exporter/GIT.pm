package Netdot::Exporter::GIT;

use base 'Netdot::Exporter';
use warnings;
use strict;
use HTML::Entities;
use Data::Dumper;

my $logger = Netdot->log->get_logger('Netdot::Exporter');

=head1 NAME

Netdot::Exporter::GIT - Read relevant info from Netdot and commit changes

=head1 SYNOPSIS

    my $git = Netdot::Exporter->new(type=>'GIT');
    $git->generate_configs()

=head1 CLASS METHODS
=cut

############################################################################

=head2 new - Class constructor

  Arguments:
    None
  Returns:
    Netdot::Exporter::GIT object
  Examples:
    my $git = Netdot::Exporter->new(type=>'GIT');
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
    $git->generate_configs();
=cut

sub generate_configs {
    my ($self, %argv) = @_;

    my $author = 'Vincent Magnin <Vincent.Magnin@unil.ch>';
    my $commit = 'Commit from CLI';
    if ( $argv{person} ){
	$author = $argv{person}->{name}.' <'.$argv{person}->{email}.'>';
	$commit = 'Commit done by '.$author;
    }

    my $branch = 'master';
    if ( $argv{branch} ){
	unless ( ref($argv{branch}) eq 'ARRAY' ){
	    $self->throw_fatal("branch argument must be arrayref!");
	}
	foreach my $name ( @{$argv{branch}} ){
	    $branch = $name;
	}
    }

    my $gitdir = Netdot->config->get('Git_DIR')
	|| $self->throw_user('Git_DIR not defined in config file!');

    my $gitkey = Netdot->config->get('Git_PRIVATE_KEY')
	|| $self->throw_user('Git_PRIVATE_KEY not defined in config file!');

    foreach my $dir (@{$gitdir}) {
	system ("cd $dir; git checkout $branch"); 
	open (FOO, "cd $dir; git commit -a --author='$author' -m '$commit' |");
	while (<FOO>) {
	    chomp;
	    $logger->info( encode_entities($_) );
	}
	close (FOO);
    }
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
