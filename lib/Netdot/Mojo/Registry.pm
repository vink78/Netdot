package Netdot::Mojo::Registry;

use strict;
use warnings;

# Browsable object types: key => { class, [nav => 0], [label => display override] }.
# The list columns, the object label and the description are DERIVED from the model
# meta (netdot.meta: "views" { brief / all }, table name/description) — not stored
# here, to keep the model the single source of truth. "id" is always shown first
# (linked to the detail page). nav => 0 marks link-only objects (linksto targets):
# routable + generic detail, but hidden from the nav/home menu.
our %TYPES = (
    ipblock   => { class => 'Ipblock' },
    device    => { class => 'Device' },
    asset     => { class => 'Asset' },
    interface => { class => 'Interface' },
    vlan      => { class => 'Vlan' },
    zone      => { class => 'Zone' },
    site      => { class => 'Site' },
    room      => { class => 'Room' },
    floor     => { class => 'Floor' },
    closet    => { class => 'Closet' },
    person    => { class => 'Person' },
    rr        => { class => 'RR' },
    entity    => { class => 'Entity' },
    service   => { class => 'Service' },
    contactlist => { class => 'ContactList' },
    physaddr  => { class => 'PhysAddr' },
    # Link-only objects (linksto targets): generic detail, no nav entry.
    product         => { class => 'Product',         nav => 0 },
    availability    => { class => 'Availability',    nav => 0 },
    circuit         => { class => 'Circuit',         nav => 0 },
    arpcache        => { class => 'ArpCache',        nav => 0 },
    sitelink        => { class => 'SiteLink',        nav => 0 },
    fwtable         => { class => 'FWTable',         nav => 0 },
    stpinstance     => { class => 'STPInstance',     nav => 0 },
    horizontalcable => { class => 'HorizontalCable', nav => 0 },
    backbonecable   => { class => 'BackboneCable',   nav => 0 },
    dhcscope        => { class => 'DhcpScope',       nav => 0 },
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
sub is_sensitive { exists $SENSITIVE{ $_[0] } }

# Memoized spec for a type: { class, label, desc, cols, nav, ... }. label/desc/cols
# are derived from the model meta (single source of truth); an optional override in
# %TYPES wins. The model is loaded by the time this runs (requests), so meta_data
# is available; guard anyway.
our %SPEC;
sub spec {
    my ($key) = @_;
    my $base = $TYPES{$key} or return;
    return $SPEC{$key} if exists $SPEC{$key};
    my $class = $base->{class};
    my $meta  = eval { $class->meta_data };
    my $label = $base->{label} // ( $meta && eval { $meta->name } ) // $key;
    my $desc  = $meta ? eval { $meta->description } : undef;
    $desc  = '' unless defined $desc;
    my @cols = _brief_cols($class);
    my $spec = { %$base, class => $class, label => $label, desc => $desc, cols => \@cols };
    return $SPEC{$key} = $spec;
}

# List columns from the meta "brief" view; fall back to the "all" view, then the
# raw column list (minus id).
sub _brief_cols {
    my ($class) = @_;
    my $meta = eval { $class->meta_data };
    return () unless $meta;
    my %o;
    eval { %o = $meta->get_column_order_brief(); 1 };
    my @c = sort { $o{$a} <=> $o{$b} } keys %o;
    return @c if @c;
    %o = ();
    eval { %o = $meta->get_column_order( view => 'all' ); 1 };
    @c = sort { $o{$a} <=> $o{$b} } keys %o;
    return grep { $_ ne 'id' } @c if @c;
    return grep { $_ ne 'id' } $class->columns;
}

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
