package Netdot::Mojo::Registry;

use strict;
use warnings;

# Browsable object types: key => { class, label, desc, cols => [display columns] }.
# "id" is always shown first (linked to the detail page); cols are the extra columns.
our %TYPES = (
    ipblock   => { class => 'Ipblock',   label => 'Ipblocks',   desc => 'IP address blocks',   cols => [qw(address prefix status used_by)] },
    device    => { class => 'Device',    label => 'Devices',    desc => 'network equipment',   cols => [qw(sysname os owner site)] },
    asset     => { class => 'Asset',     label => 'Assets',     desc => 'hardware assets',     cols => [qw(serial_number product_id physaddr inventory_number)] },
    interface => { class => 'Interface', label => 'Interfaces', desc => 'device interfaces',   cols => [qw(name number device oper_status admin_status)] },
    vlan      => { class => 'Vlan',      label => 'VLANs',      desc => 'virtual LANs',        cols => [qw(name vid vlangroup description)] },
    zone      => { class => 'Zone',      label => 'Zones',      desc => 'DNS zones',           cols => [qw(name rname mname active)] },
    site      => { class => 'Site',      label => 'Sites',      desc => 'physical sites',      cols => [qw(name aliases city country)] },
    room      => { class => 'Room',      label => 'Rooms',      desc => 'site rooms',          cols => [qw(name floor)] },
    floor     => { class => 'Floor',     label => 'Floors',     desc => 'site floors',         cols => [qw(level site)] },
    closet    => { class => 'Closet',    label => 'Closets',    desc => 'machine rooms',       cols => [qw(name room info)] },
    person    => { class => 'Person',    label => 'People',     desc => 'contacts / users',    cols => [qw(username firstname lastname email entity)] },
    # Foreign-key target objects (linked from other detail pages).
    rr          => { class => 'RR',          label => 'DNS Records',   desc => 'DNS resource records',   cols => [qw(name zone)] },
    entity      => { class => 'Entity',      label => 'Entities',      desc => 'entities / customers',   cols => [qw(name aliases short_name)] },
    service     => { class => 'Service',     label => 'Services',      desc => 'Internet services',      cols => [qw(name)] },
    contactlist => { class => 'ContactList', label => 'Contact Lists', desc => 'contact groups',         cols => [qw(name)] },
    physaddr    => { class => 'PhysAddr',    label => 'MAC Addresses', desc => 'physical (MAC) addresses', cols => [qw(address)] },
);

# Ordered list of browsable types (drives routes, navbar and home menu).
our @ORDER = qw(ipblock device asset interface vlan zone site room floor closet person rr entity service contactlist physaddr);
sub types { @ORDER }

# Columns that must never be displayed (secrets / raw credentials).
our %SENSITIVE = map { $_ => 1 } qw(password snmp_authkey snmp_privkey);

# Accessors (avoid the "PKG::HASH{$x}" parse-as-method pitfall).
sub spec         { $TYPES{ $_[0] } }
sub is_sensitive { exists $SENSITIVE{ $_[0] } }

# Render a (possibly inflated) column value as a display string.
# Relationships use the object's own ->get_label; fallback is "ShortClass #id".
sub format_value {
    my ($v) = @_;
    return '' unless defined $v;
    if (ref $v) {
        my $lbl = eval { $v->get_label };
        return $lbl if defined $lbl && length $lbl;
        my $short = ref $v;   $short =~ s/.*:://;   # Netdot::Model::Site -> Site
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
    my $text  = eval { $v->get_label };
    $text = "$short #$id" unless defined $text && length $text;
    my $href  = ( exists $TYPES{$type} && $id =~ /^\d+$/ ) ? "/management/$type/$id" : undef;
    return [ $text, $href ];
}

# Escape a value for CSV (matches Netdot viewtext.html: comma -> space, quote -> apostrophe).
sub csv_field {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/,/ /g;
    $s =~ s/"/'/g;
    return $s;
}

1;
