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
    # Link-only "object" types: reachable as the target of a foreign key (linksto in
    # netdot.meta) and rendered by the generic detail, but not shown in the nav.
    product         => { class => 'Product',         label => 'Products',          desc => 'catalog products',        cols => [qw(name manufacturer part_number type)],        nav => 0 },
    availability    => { class => 'Availability',    label => 'Availability',      desc => 'service availability',    cols => [qw(name info)],                                  nav => 0 },
    circuit         => { class => 'Circuit',         label => 'Circuits',          desc => 'network circuits',        cols => [qw(cid linkid status type speed)],              nav => 0 },
    arpcache        => { class => 'ArpCache',        label => 'ARP Cache',         desc => 'ARP cache entries',       cols => [qw(tstamp device)],                             nav => 0 },
    sitelink        => { class => 'SiteLink',        label => 'Site Links',        desc => 'inter-site links',        cols => [qw(name entity nearend farend)],              nav => 0 },
    fwtable         => { class => 'FWTable',         label => 'FW Tables',         desc => 'firewall tables',         cols => [qw(tstamp device)],                             nav => 0 },
    stpinstance     => { class => 'STPInstance',     label => 'STP Instances',     desc => 'spanning tree instances', cols => [qw(number device root_port root_bridge)],      nav => 0 },
    horizontalcable => { class => 'HorizontalCable', label => 'Horizontal Cables', desc => 'horizontal cabling',      cols => [qw(jackid faceplateid type closet room)],       nav => 0 },
    backbonecable   => { class => 'BackboneCable',   label => 'Backbone Cables',   desc => 'backbone cabling',        cols => [qw(name type owner start_closet end_closet length)], nav => 0 },
    dhcscope        => { class => 'DhcpScope',       label => 'DHCP Scopes',       desc => 'DHCP scopes',             cols => [qw(name type version container active)],        nav => 0 },
);

# Ordered list of browsable types (drives routes, navbar and home menu).
our @ORDER = qw(
    ipblock device asset interface vlan zone site room floor closet person
    rr entity service contactlist physaddr
    product availability circuit arpcache sitelink fwtable stpinstance
    horizontalcable backbonecable dhcscope
);
sub types { @ORDER }

# Columns that must never be displayed (secrets / raw credentials).
our %SENSITIVE = map { $_ => 1 } qw(password snmp_authkey snmp_privkey);

# Accessors (avoid the "PKG::HASH{$x}" parse-as-method pitfall).
sub spec         { $TYPES{ $_[0] } }
sub is_sensitive { exists $SENSITIVE{ $_[0] } }

# Ordered display columns for a class's "all" view (from netdot.meta "views"), as
# [ [col, tag], ... ]. The tag is the user-friendly label (e.g. serial_number ->
# "S/N", product_id -> "Product", info -> "Comments"). Falls back to the raw
# column list (minus id) when the class has no "all" view.
sub display_columns {
    my ($class) = @_;
    my $meta  = $class->meta_data;
    my %order;
    eval { %order = $meta->get_column_order( view => 'all' ); 1 };
    my @cols  = sort { $order{$a} <=> $order{$b} } keys %order;
    @cols = grep { $_ ne 'id' } $class->columns unless @cols;
    return [ map {
        my $tag = eval { $meta->get_column( $_ )->tag };
        [ $_, ( defined $tag && length $tag ? $tag : $_ ) ];
    } @cols ];
}

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
