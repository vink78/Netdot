package Netdot::Model::RRAttr;

use base 'Netdot::Model';
use warnings;
use strict;

my $logger = Netdot->log->get_logger('Netdot::Model::DNS');

=head1 Netdot::Model::RRAttr - DNS resource record attribute (modern record types) Class

    Stores a modern DNS record type (CAA, HTTPS, SSHFP, ...) as a single raw
    value, so it can be exported to zone files without re-formatting the data.

=head1 CLASS METHODS
=cut

############################################################################

=head2 insert - Insert new RRAttr object

    We override the base method to:
    - Validate TTL
    - Validate required fields

  Arguments:
    See schema
  Returns:
    RRAttr object
  Example:
    my $record = RRAttr->insert(\%args)

=cut

sub insert {
    my($class, $argv) = @_;
    $class->isa_class_method('insert');

    $class->throw_fatal('Missing required arguments: rr')
        unless ( $argv->{rr} );

    $class->throw_user("Missing required argument: name")
        unless ( $argv->{name} );

    $class->throw_user("Missing required argument: value")
        unless ( defined $argv->{value} );

    _validate_value($argv->{value});

    my $rr = (ref $argv->{rr})? $argv->{rr} : RR->retrieve($argv->{rr});
    $class->throw_fatal("Invalid rr argument") unless $rr;

    my $name = (ref $argv->{name})? $argv->{name} : RRAttrName->retrieve($argv->{name});
    $class->throw_fatal("Invalid name argument") unless $name;

    # TTL needs to be set and converted into integer
    $argv->{ttl} = (defined($argv->{ttl}) && length($argv->{ttl}))? $argv->{ttl} : $rr->zone->default_ttl;
    $argv->{ttl} = $class->ttl_from_text($argv->{ttl});

    return $class->SUPER::insert($argv);

}

=head1 INSTANCE METHODS
=cut

############################################################################

=head2 update

    We override the base method to:
     - Validate TTL

  Arguments:
    Hash with field/value pairs
  Returns:
    Number of rows updated or -1
  Example:
    $record->update(\%args)

=cut

sub update {
    my($self, $argv) = @_;
    $self->isa_object_method('update');

    _validate_value($argv->{value}) if defined $argv->{value};

    if ( defined $argv->{ttl} && length($argv->{ttl}) ){
        $argv->{ttl} = $self->ttl_from_text($argv->{ttl});
    }else{
        delete $argv->{ttl};
    }

    return $self->SUPER::update($argv);
}

# The value is a raw DNS rdata written verbatim to the zone file. Validate it so
# a bad value cannot produce an unparseable zone:
#   1) no line breaks (a zone is line-oriented: 1 record per line);
#   2) only printable ASCII (space .. ~) and tab — control/non-ASCII chars break it;
#   3) double quotes must be balanced (even count: each " opens, one closes).
sub _validate_value {
    my ($value) = @_;
    return unless defined $value;
    Netdot::Model::RRAttr->throw_user('value: no line breaks allowed (one zone record per line)')
        if $value =~ /[\r\n]/;
    Netdot::Model::RRAttr->throw_user('value: only printable characters (space, tab) allowed')
        if $value !~ /^[\x09\x20-\x7E]+\z/;
    my $nq = () = $value =~ /"/g;
    Netdot::Model::RRAttr->throw_user('value: unbalanced double quotes (need an even number)')
        if $nq % 2;
}

##################################################################

=head2 as_text

    Returns the text representation of this record in the zone file format:

        <name> <TTL> IN <type> <raw value>

    The value is emitted verbatim (RAW): it may contain spaces and/or quotes,
    so it must not be re-formatted.

  Arguments:
    None
  Returns:
    string
  Examples:
    print $record->as_text();

=cut

sub as_text {
    my $self = shift;
    $self->isa_object_method('as_text');

    # Raw (zone-relative) name, like the other record types: the exporter builds
    # every line from rr.name (the apex is '@'). The value is written verbatim —
    # it is the full rdata as stored (may contain spaces and/or quotes).
    my $name  = $self->rr->name;
    my $type  = $self->name->name;
    my $value = $self->value;

    my $ttl = $self->ttl;
    if ( !defined $ttl || $ttl !~ /\d+/ ){
        $ttl = $self->rr->zone->default_ttl;
    }

    return sprintf("%s\t%s\tIN\t%s\t%s", $name, $ttl, $type, $value);
}

=head1 AUTHOR

Vincent Magnin

The initial version of this program was developed with the assistance of the
Qwen 3.8-27b LLM.

=head1 COPYRIGHT & LICENSE

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more
details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 51
Francis Street, Fifth Floor, Boston, MA 02110-1301, USA.

=cut

# Make sure to return 1
1;
