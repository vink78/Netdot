package Netdot::Mojo::Registry;

use strict;
use warnings;

# Browsable object types: key => { class => Class::DBI alias, cols => [display columns] }.
# "id" is always shown first (linked to the detail page); cols are the extra columns.
our %TYPES = (
    ipblock   => { class => 'Ipblock',   cols => [qw(address prefix status used_by)] },
    device    => { class => 'Device',    cols => [qw(sysname os owner site)] },
    vlan      => { class => 'Vlan',      cols => [qw(name vid vlangroup description)] },
    zone      => { class => 'Zone',      cols => [qw(name rname mname active)] },
    interface => { class => 'Interface', cols => [qw(name number device oper_status admin_status)] },
    person    => { class => 'Person',    cols => [qw(username firstname lastname email entity)] },
);

# Columns that must never be displayed (secrets / raw credentials).
our %SENSITIVE = map { $_ => 1 } qw(password snmp_authkey snmp_privkey);

# Accessors (avoid the "PKG::HASH{$x}" parse-as-method pitfall).
sub spec         { $TYPES{ $_[0] } }
sub is_sensitive { exists $SENSITIVE{ $_[0] } }

# Render a (possibly inflated) column value as a display string.
# Inflated objects (relationships) are shown as "ShortClass #id".
sub format_value {
    my ($v) = @_;
    return '' unless defined $v;
    if (ref $v) {
        my $short = ref $v;       # Netdot::Model::Site
        $short   =~ s/.*:://;     # Site
        my $s     = eval { "$v" };
        $s        = ( $@ || !defined $s ) ? '?' : $s;
        return $short . ' #' . $s;
    }
    return $v;
}

1;
