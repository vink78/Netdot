package Netdot::Model::AccessRight;

use base 'Netdot::Model';
use warnings;
use strict;

my $logger = Netdot->log->get_logger('Netdot::Model');

# Classes used for access rights
my %CLASSES = (
    Device      => 1,
    Ipblock     => 1,
    ContactList => 1,
    Zone        => 1,
    );

# Make sure to return 1
1;

=head1 NAME

Netdot::Model::AccessRight

=head1 SYNOPSIS

=head1 CLASS METHODS
=cut

########################################################################

=head2 get_classes - Get a list of classes with access rights

    This is useful in places like Model::delete() where we can avoid
    searching for access rights if we know that the object being 
    deleted does not deal with rights

  Arguments: 
    None
  Returns:   
    Hash with key = class name
  Examples:
    my %aclasses = AccessRight->get_classes();

=cut

sub get_classes{
    my ($self) = @_;
    return %CLASSES;
}

=head2 insert - Grant a set of rights to a subject, or insert a plain row

  Extends the model insert to support granting a list of rights to a user or
  group on an object in one call (this is what the API uses). When `rights`
  (an arrayref of access values) is present, the record set is built instead of
  a single row: for each valid right an AccessRight row (object_class, object_id,
  access) is created or reused, then the matching join row is added — userright
  (subject is a Person) or groupright (subject is a ContactList). Without
  `rights`, it falls back to a plain column insert (SUPER::insert).

  Args:
    object_class : the target class (Ipblock | Zone | Device | ContactList)
    object_id    : the target object's id
    subject_type : 'user' (Person) or 'group' (ContactList)
    subject_id   : the subject's id
    rights       : arrayref of access values (view|edit|delete|choose_ip|none)

=cut

sub insert {
    my ( $class, $argv ) = @_;
    my ( $oclass, $oid, $stype, $sid, $rights ) =
        @{ $argv }{qw(object_class object_id subject_type subject_id rights)};
    if ( defined $rights ) {
        my @r = ( ref $rights eq 'ARRAY' ? @$rights : ($rights) );
        $class->throw_user( "Unknown object class" )
            unless $oclass && $CLASSES{ $oclass };
        $stype = lc( $stype // '' );
        my $subject = $stype eq 'user'
            ? Person->retrieve( int( $sid ) )
            : ContactList->retrieve( int( $sid ) );
        $class->throw_user( "Unknown subject" ) unless $subject;
        my $last;
        for my $acc (@r) {
            next unless defined $acc && $acc =~ /^(view|edit|delete|choose_ip|none)$/;
            my @ex = AccessRight->search( object_class => $oclass, object_id => $oid, access => $acc );
            my $ar = @ex ? $ex[0] : $class->SUPER::insert(
                { object_class => $oclass, object_id => $oid, access => $acc }
            );
            $stype eq 'user'
                ? UserRight->insert(  { person      => $subject->id, accessright => $ar->id } )
                : GroupRight->insert( { contactlist => $subject->id, accessright => $ar->id } );
            $last = $ar;
        }
        $class->throw_user( "No valid rights selected" ) unless $last;
        return $last;
    }
    return $class->SUPER::insert( $argv );
}


=head1 INSTANCE METHODS
=cut

########################################################################

=head2 get_label - Get object label

  Arguments: 
    None
  Returns:   
    String
  Examples:
    print $accessright->get_label();

=cut

sub get_label{
    my ($self) = @_;
    $self->isa_object_method('get_label');
    if ( $self->access ){
	if ( $self->object_class && $self->object_id ){
	    my $oclass = $self->object_class;
	    my $oid  = $self->object_id;
	    my $obj_lbl = $oclass->retrieve($oid)->get_label;
	    return $self->object_class." ".$obj_lbl." - ".$self->access;
	}elsif ( $self->object_class ){
	    return $self->object_class." - ".$self->access;
	}
    }else{
	return "?";
    }
}


=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

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

