package Netdot::Mojo::Permissions;

# Permission layer for the Mojolicious app.
#
# Port of the Apache/mod_perl rule-based manager (Netdot::NetdotPermissionFactory
# + Apache2::SiteControl::PermissionManager), which combined three rules:
#   GrantAllRule        -> grants everything (default allow)
#   SectionAccessRule   -> denies UI sections for non-Admin / non-Operator
#   ObjectAccessRule    -> denies object access based on user type + allowed objects
#
# The original per-request "user" was an Apache2::SiteControl::User wrapper that
# carried two attributes (USER_TYPE, ALLOWED_OBJECTS) plus a username.  Here the
# equivalent is a Netdot::Model::Person object:
#   USER_TYPE        -> Person->user_type->name
#   ALLOWED_OBJECTS  -> Person->get_allowed_objects()
#
# can($person, $action, $resource) returns 1 if allowed, 0 otherwise.
#   $person   : Netdot::Model::Person (undef -> deny everything)
#   $action   : 'view' | 'edit' | 'delete' | 'choose_ip' | 'access_section' | 'access_admin_section'
#   $resource : a Netdot model object, or a section name string for section actions
#   $access   : optional precomputed allowed_objects() hashref (cached per request by the $c->can helper)

use strict;
use warnings;
use Netdot;
use Netdot::Model;

my $logger;
sub _log () {
    $logger //= Netdot->log->get_logger('Netdot::Mojo::Permissions');
    return $logger;
}

##################################################################
# Public helpers
##################################################################

# User type of a Person ('Admin' | 'Operator' | 'User' | '' if unset).
sub user_type {
    my ($class, $person) = @_;
    return '' unless $person && ref $person;
    my $ut = eval { $person->user_type };
    return '' unless $ut;
    my $name = eval { $ut->name };
    return defined $name && length $name ? $name : '';
}

# Hashref of allowed objects for a Person:
#   { ObjectClass => { object_id => { view=>1, edit=>1, ... } } }
sub allowed_objects {
    my ($class, $person) = @_;
    return {} unless $person && ref $person;
    my $ao = eval { $person->get_allowed_objects };
    return ( defined $ao && ref $ao eq 'HASH' ) ? $ao : {};
}

##################################################################
# SQL WHERE fragment restricting a list to the objects $person may 'view'.
#   (undef, undef) -> no restriction (Admin / Operator: view access to everything)
#   ( $where, [] ) -> predicate to append after the table name (ids inlined as a
#       literal, e.g. " WHERE (id IN (3,7) OR zone IN (2))"); no placeholders.
#   ( '0', [] )  -> nothing is viewable (a User with no matching rights).
#
# Built from the FK columns so we never materialise a huge id list (a single
# Zone can hold tens of thousands of RRs; we filter by `zone IN (...)` instead).
sub viewable_predicate {
    my ( $self, $class, $person ) = @_;
    my $type = user_type( __PACKAGE__, $person );
    return ( undef, undef ) unless defined $person && ref $person;
    return ( undef, undef ) if $type eq 'Admin' || $type eq 'Operator';

    my $otype  = eval { $class->short_class } // ref($class);
    my $access = allowed_objects( __PACKAGE__, $person );

    # [ column, allowed-object-class ] pairs (inheritance grants, view action).
    my @pairs = ( [ 'id', $otype ] );
    if (    $otype eq 'Interface' ) { @pairs = ( [ 'id', 'Interface' ], [ 'device', 'Device' ] ); }
    elsif ( $otype =~ /^RR/ )       { @pairs = ( [ 'id', 'RR' ],        [ 'zone',   'Zone'   ] ); }
    elsif ( $otype eq 'Contact' )   { @pairs = ( [ 'id', 'Contact' ],   [ 'contactlist', 'ContactList' ] ); }

    my @clauses;
    for my $p (@pairs) {
        my ( $col, $acl ) = @$p;
        next unless exists $access->{$acl};
        # Only object ids that grant the 'view' action (a User may hold edit/
        # delete without view on a given object; we must not list those).
        # Object ids are integers: build a single literal IN list (one string),
        # rather than one placeholder per value.
        my @ids;
        for my $id ( keys %{ $access->{$acl} } ) {
            next unless defined $id && $id =~ /^\d+$/;
            my $a = $access->{$acl}{$id};
            next unless ref $a && !exists $a->{none};
            push @ids, $id if exists $a->{view};
        }
        next unless @ids;
        push @clauses, "$col IN (" . join( ',', @ids ) . ")";
    }

    return ( '0', [] ) unless @clauses;          # no rights at all -> view nothing
    return ( '(' . join( ' OR ', @clauses ) . ')', [] );
}

##################################################################
# Does $person hold $action on ANY object of $class (used to show/hide the
# delete control on list pages and to filter the navigation). Conservative:
# checks the type itself plus the FK types whose rights grant access
# (Device->Interface, Zone->RR, ...).
sub has_action {
    my ( $self, $class, $person, $action ) = @_;
    my $type = user_type( __PACKAGE__, $person );
    return 0 unless defined $person && ref $person;
    return 1 if $type eq 'Admin';
    return has_action_on( $class, allowed_objects( __PACKAGE__, $person ), $action );
}

# Same as has_action but takes a PRE-FETCHED allowed_objects() hashref (so a
# caller can inspect many types in one shot without re-querying the DB per type).
sub has_action_on {
    my ( $class, $access, $action ) = @_;
    return 0 unless ref $access eq 'HASH';

    my $otype = eval { $class->short_class } // ref($class);
    my @types = ( $otype );
    push @types, 'Device'      if $otype eq 'Interface';
    push @types, 'Zone'       if $otype =~ /^RR/;
    push @types, 'ContactList' if $otype eq 'Contact';

    for my $t (@types) {
        next unless exists $access->{$t};
        for my $id ( keys %{ $access->{$t} } ) {
            my $a = $access->{$t}{$id};
            next unless ref $a && !exists $a->{none};
            return 1 if exists $a->{$action};
        }
    }
    return 0;
}

# May $person trigger the Export section (generate 3rd-party configs)?
# Reserved to people holding WRITE rights on DNS records: 'edit' (create/modify)
# or 'delete' on a Zone or RR (Zone rights apply to their records; has_action
# already resolves the Zone->RR grant and short-circuits to "yes" for Admins).
# (Original: access_admin_section / Admin only; relaxed to "DNS write" on request.)
sub can_export {
    my ( $class, $person ) = @_;
    return 0 unless defined $person && ref $person;
    return 1 if __PACKAGE__->has_action( 'RR', $person, 'edit' );
    return 1 if __PACKAGE__->has_action( 'RR', $person, 'delete' );
    return 0;
}

##################################################################
# Main entry point
##################################################################

sub can {
    my ( $class, $person, $action, $resource, $access ) = @_;
    return 0 unless $person && ref $person;

    my $type = user_type( $class, $person );
    return 0 unless $type;

    my $username = _username($person);

    # SectionAccessRule
    return 0 if _denies_section( $type, $username, $action, $resource );

    # ALLOWED_OBJECTS is only consulted by the per-object rule (User/Operator);
    # resolve it lazily so Admins and section checks avoid the DB query.
    $access = allowed_objects( $class, $person ) if $type ne 'Admin' && !defined $access;

    # ObjectAccessRule (on error, deny: conservative default)
    my $denied = eval { _denies_object( $type, $username, $action, $resource, $access ) };
    $denied = 1 if $@;
    return 0 if $denied;

    # GrantAllRule default
    return 1;
}

##################################################################
# SectionAccessRule (lib/Netdot/SectionAccessRule.pm)
##################################################################
sub _denies_section {
    my ( $type, $username, $action, $resource ) = @_;
    if ( $action eq 'access_section' && $type ne 'Admin' && $type ne 'Operator' ) {
        _log->debug("SectionAccessRule: denying access_section for $username ($type)");
        return 1;
    }
    if ( $action eq 'access_admin_section' && $type ne 'Admin' ) {
        _log->debug("SectionAccessRule: denying access_admin_section for $username ($type)");
        return 1;
    }
    return 0;
}

##################################################################
# ObjectAccessRule (lib/Netdot/ObjectAccessRule.pm)
# Returns 1 = deny, 0 = do not deny.
##################################################################
sub _denies_object {
    my ( $type, $username, $action, $object, $access ) = @_;

    # Admins have full access to every object
    return 0 if $type eq 'Admin';

    # Only object resources are handled here; section names (strings) pass through
    return 0 unless $object && ref $object;

    my $otype = $object->short_class();
    if ( !$otype ) {
        _log->debug("ObjectAccessRule: object not valid");
        return 1;
    }

    my $oid = $object->id;
    _log->debug("ObjectAccessRule: '$action' $otype id $oid for $username ($type)");

    # Only User / Operator reach this point (Admin already returned above).
    return 1 unless $type eq 'User' || $type eq 'Operator';

    # Operators have 'view' access to everything
    return 0 if ( $type eq 'Operator' && $action eq 'view' );

    if ( !defined $access || ref $access ne 'HASH' ) {
        _log->debug("ObjectAccessRule: $username: no ALLOWED_OBJECTS. Denying.");
        return 1;
    }

    if ( exists $access->{$otype} && exists $access->{$otype}->{$oid} ) {
        if ( $otype eq 'Zone' || $otype eq 'Ipblock' ) {
            # Users cannot delete these; permissions apply to records in the zone
            if ( $type eq 'User' && $action eq 'delete' ) {
                return 1;
            }
            if ( $otype eq 'Ipblock' ) {
                return _deny_ip_access( $action, $access, $object );
            }
        }
        return _deny_action_access( $action, $access->{$otype}->{$oid} );

    }
    elsif ( $otype eq 'Interface' ) {
        # Grant access to any interface of an allowed device
        my $dev = $object->device;
        if ( exists $access->{'Device'} && exists $access->{'Device'}->{$dev->id} ) {
            return _deny_action_access( $action, $access->{'Device'}->{$dev->id} );
        }

    }
    elsif ( $otype eq 'Contact' ) {
        # Grant access to roles (contacts) of an allowed ContactList
        my $cl = $object->contactlist;
        if ( exists $access->{'ContactList'} && exists $access->{'ContactList'}->{$cl->id} ) {
            return _deny_action_access( $action, $access->{'ContactList'}->{$cl->id} );
        }

    }
    elsif ( $otype eq 'Person' ) {
        # Grant access to Person objects with roles in an allowed ContactList
        foreach my $role ( $object->roles ) {
            my $cl = $role->contactlist;
            if ( exists $access->{'ContactList'} && exists $access->{'ContactList'}->{$cl->id} ) {
                return 0 if ( ! _deny_action_access( $action, $access->{'ContactList'}->{$cl->id} ) );
            }
        }
        return 1;

    }
    elsif ( $otype eq 'Ipblock' ) {
        # Only Ipblocks not already in %access reach here (e.g. individual IPs)
        return _deny_ip_access( $action, $access, $object );

    }
    elsif ( $otype eq 'IpblockAttr' ) {
        # IP attributes match subnet permissions
        my $ipblock = $object->ipblock;
        my $parent;
        if ( $parent = $ipblock->parent ) {
            if ( exists $access->{'Ipblock'} && exists $access->{'Ipblock'}->{$parent->id} ) {
                return _deny_action_access( $action, $access->{'Ipblock'}->{$parent->id} );
            }
        }

    }
    elsif ( $otype eq 'PhysAddr' ) {
        # View access if a dhcp scope exists in an allowed subnet
        if ( my @scopes = $object->dhcp_hosts ) {
            foreach my $scope (@scopes) {
                if ( $scope->ipblock ) {
                    my $ipb = $scope->ipblock;
                    return 0 if ( ! _deny_ip_access( $action, $access, $ipb ) );
                }
            }
        }
        # Or if it has ARP entries in an allowed subnet
        if ( my @arp_entries = $object->arp_entries ) {
            foreach my $ae (@arp_entries) {
                if ( $ae->ipaddr ) {
                    my $ipb = $ae->ipaddr;
                    return 0 if ( ! _deny_ip_access( $action, $access, $ipb ) );
                }
            }
        }
        return 1;

    }
    elsif ( $otype eq 'PhysAddrAttr' ) {
        if ( my @scopes = $object->dhcp_hosts ) {
            foreach my $scope (@scopes) {
                if ( $scope->ipblock ) {
                    my $ipblock = $scope->ipblock;
                    my $parent;
                    if ( $parent = $ipblock->parent ) {
                        if ( exists $access->{'Ipblock'} && exists $access->{'Ipblock'}->{$parent->id} ) {
                            return 0 if ( ! _deny_action_access( $action, $access->{'Ipblock'}->{$parent->id} ) );
                        }
                    }
                }
            }
        }
        return 1;

    }
    elsif ( $otype =~ /^RR/ ) {
        my ( $rr, $zone );
        if ( $otype eq 'RR' ) {
            $rr = $object;
        }
        else {
            $rr = $object->rr;
        }
        $zone = $rr->zone;

        # Users cannot delete the zone apex
        if ( $otype eq 'RR' && $rr->name eq '@' && $action eq 'delete' ) {
            return 1;
        }

        # Users cannot edit or delete NS records
        if ( $otype eq 'RRNS' && $action ne 'view' ) {
            return 1;
        }

        # Users cannot edit or delete RRs for Devices or Device IPs
        if ( $action ne 'view' ) {
            if ( $rr->devices ) {
                _log->debug("ObjectAccessRule: ".$rr->get_label." linked to a Device. Denying.");
                return 1;
            }
            foreach my $arecord ( $rr->a_records ) {
                my $ip = $arecord->ipblock;
                return 1 if ( $ip->interface || $ip->snmp_devices );
            }
        }

        # Rights on the zone apply to its records
        if ( exists $access->{'Zone'}->{$zone->id} ) {
            return _deny_action_access( $action, $access->{'Zone'}->{$zone->id} );
        }

        # No whole-zone access: grant only if the record maps to an IP in an allowed block
        if ( $otype eq 'RRCNAME' ) {
            # Search for the record the CNAME points to
            if ( my $crr = RR->search(name => $object->cname)->first ) {
                if ( my @ipbs = _get_rr_ips($crr) ) {
                    foreach my $ipb (@ipbs) {
                        next if $ipb == 0;
                        return 1 if ( _deny_ip_access( $action, $access, $ipb, 1 ) );
                    }
                    return 0;
                }
            }
        }
        else {
            if ( my @ipbs = _get_rr_ips($rr) ) {
                foreach my $ipb (@ipbs) {
                    next if !$ipb;
                    return 1 if ( _deny_ip_access( $action, $access, $ipb, 1 ) );
                }
                return 0;
            }
            elsif ( my $cname = $object->cnames->first ) {
                # This RR is an alias of something else
                if ( my $crr = RR->search(name => $cname->cname)->first ) {
                    if ( my @ipbs = _get_rr_ips($crr) ) {
                        foreach my $ipb (@ipbs) {
                            next if $ipb == 0;
                            return 1 if ( _deny_ip_access( $action, $access, $ipb, 1 ) );
                        }
                        return 0;
                    }
                }
            }
        }
    }

    _log->debug("ObjectAccessRule: no matching criteria. Denying.");
    return 1;
}

##################################################################
# Given an action and a per-object access hash, return 1 (deny) or 0 (allow).
##################################################################
sub _deny_action_access {
    my ( $action, $access ) = @_;
    if ( exists $access->{none} ) {
        _log->debug("ObjectAccessRule: access explicitly denied for this object");
        return 1;
    }
    if ( exists $access->{$action} ) {
        return 0;   # do not deny
    }
    _log->debug("ObjectAccessRule: no access for $action. Denying.");
    return 1;
}

##################################################################
# IP addresses inherit ancestor permissions.
# Returns 1 (deny) or 0 (allow).
##################################################################
sub _deny_ip_access {
    my ( $action, $access, $ipblock, $is_rr ) = @_;
    if ( $action ne 'view' && ( $ipblock->interface || $ipblock->snmp_devices ) ) {
        _log->debug("ObjectAccessRule: ".$ipblock->get_label." linked to Device. Denying.");
        return 1;
    }

    if ( $ipblock->status ) {
        my $status = $ipblock->status->name;
        if ( $status eq 'Dynamic' || $status eq 'Reserved' ) {
            _log->debug("ObjectAccessRule: ".$ipblock->get_label." is Dynamic/Reserved. Denying.");
            return 1;
        }
    }

    # Deny unless the object or an ancestor is permitted
    my $deny = _deny_action_access( $action, $access->{'Ipblock'}->{$ipblock->id} );
    return $deny if $deny == 0;

    foreach my $ancestor ( $ipblock->get_ancestors ) {
        if ( exists $access->{'Ipblock'}->{$ancestor->id} ) {
            $deny = _deny_action_access( $action, $access->{'Ipblock'}->{$ancestor->id} );
            return $deny if $deny == 0;
        }
    }

    _log->debug("ObjectAccessRule: ".$ipblock->get_label." not within allowed block. Denying.");
    return $deny;
}

##################################################################
sub _get_rr_ips {
    my ($rr) = @_;
    Netdot->throw_fatal("Missing arguments") unless $rr;
    return map { $_->ipblock } $rr->a_records;
}

##################################################################
sub _username {
    my ($person) = @_;
    my $u = eval { $person->username };
    return $u if defined $u && length $u;
    my $l = eval { $person->get_label };
    return $l // 'unknown';
}

1;
