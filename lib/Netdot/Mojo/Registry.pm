package Netdot::Mojo::Registry;

use strict;
use warnings;

# Browsable object types: key => { class, label, desc, cols => [display columns] }.
# "id" is always shown first (linked to the detail page); cols are the extra columns.
our %TYPES = (
    ipblock   => { class => 'Ipblock',   label => 'Ipblocks',   desc => 'IP address blocks',   cols => [qw(address prefix status used_by)] },
    device    => { class => 'Device',    label => 'Devices',    desc => 'network equipment',   cols => [qw(sysname os owner site)] },
    interface => { class => 'Interface', label => 'Interfaces', desc => 'device interfaces',   cols => [qw(name number device oper_status admin_status)] },
    vlan      => { class => 'Vlan',      label => 'VLANs',      desc => 'virtual LANs',        cols => [qw(name vid vlangroup description)] },
    zone      => { class => 'Zone',      label => 'Zones',      desc => 'DNS zones',           cols => [qw(name rname mname active)] },
    site      => { class => 'Site',      label => 'Sites',      desc => 'physical sites',      cols => [qw(name aliases city country)] },
    room      => { class => 'Room',      label => 'Rooms',      desc => 'site rooms',          cols => [qw(name floor)] },
    floor     => { class => 'Floor',     label => 'Floors',     desc => 'site floors',         cols => [qw(level site)] },
    closet    => { class => 'Closet',    label => 'Closets',    desc => 'machine rooms',       cols => [qw(name room info)] },
    person    => { class => 'Person',    label => 'People',     desc => 'contacts / users',    cols => [qw(username firstname lastname email entity)] },
);

# Ordered list of browsable types (drives routes, navbar and home menu).
our @ORDER = qw(ipblock device interface vlan zone site room floor closet person);
sub types { @ORDER }

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

# Return [text, href] for a value. A relationship to a browsable type becomes a
# link to its detail page; anything else is plain text.
sub link_for {
    my ($v) = @_;
    return [ format_value($v) ] unless ref $v;
    my $short = ref $v;   $short =~ s/.*:://;
    my $type  = lc $short;                       # Site -> site
    my $id    = eval { "$v" };
    $id = '?' if $@ || !defined $id;
    my $href  = ( exists $TYPES{$type} && $id =~ /^\d+$/ ) ? "/management/$type/$id" : undef;
    return [ $short . ' #' . $id, $href ];
}

1;
