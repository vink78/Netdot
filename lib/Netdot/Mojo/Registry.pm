package Netdot::Mojo::Registry;

use strict;
use warnings;

# HTML-escape a string for safe embedding in markup. (Mojo::Util::escape_html is
# not reliably callable in this environment, so keep a local copy.)
sub _hesc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

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
    interface => { class => 'Interface', nav => 0 },
    vlan      => { class => 'Vlan' },
    vlangroup => { class => 'VlanGroup', nav => 0 },
    zone      => { class => 'Zone' },
    site      => { class => 'Site' },
    room      => { class => 'Room' },
    floor     => { class => 'Floor' },
    closet    => { class => 'Closet' },
    person    => { class => 'Person' },
    rr        => { class => 'RR' },
    entity    => { class => 'Entity' },
    service   => { class => 'Service', nav => 0 },
    contactlist => { class => 'ContactList' },
    physaddr  => { class => 'PhysAddr', nav => 0 },
    # Link-only objects (linksto targets): generic detail, no nav entry.
    product         => { class => 'Product',         nav => 0 },
    availability    => { class => 'Availability',    nav => 0 },
    ipblockstatus   => { class => 'IpblockStatus',   nav => 0 },
    circuit         => { class => 'Circuit',         nav => 0 },
    arpcache        => { class => 'ArpCache',        nav => 0 },
    # IP service rows: reached from the device IP view's service cells.
    ipservice       => { class => 'IpService',       nav => 0 },
    sitelink        => { class => 'SiteLink',        nav => 0 },
    fwtable         => { class => 'FWTable',         nav => 0 },
    stpinstance     => { class => 'STPInstance',     nav => 0 },
    horizontalcable => { class => 'HorizontalCable', nav => 0 },
    backbonecable   => { class => 'BackboneCable',   nav => 0 },
    dhcscope      => { class => 'DhcpScope',
                       cols => [ qw(name type container version ipblock physaddr active) ] },
    producttype     => { class => 'ProductType',     nav => 0 },
    usertype        => { class => 'UserType',        nav => 0 },
    contacttype     => { class => 'ContactType',     nav => 0 },
    dhcpscopetype   => { class => 'DhcpScopeType',   nav => 0 },
    entitytype      => { class => 'EntityType',      nav => 0 },
    # DHCP option names: link-only target of the DhcpAttr "name" FK (the scope
    # attributes "Add" form's search box queries it); no nav entry.
    dhcpattrname    => { class => 'DhcpAttrName',    nav => 0 },
    # RR subclasses (related records shown on the host/RR page): reached from the
    # host page, not the top-level nav. Registered so their detail route exists.
    rrns      => { class => 'RRNS',      label => 'Name Server Record',  nav => 0 },
    rrmx      => { class => 'RRMX',      label => 'Mail Exchange Record', nav => 0 },
    rrtxt     => { class => 'RRTXT',     label => 'Text Record',         nav => 0 },
    rrnaptr   => { class => 'RRNAPTR',   label => 'NAPTR Record',        nav => 0 },
    asn         => { class => 'ASN',         label => 'Autonomous System', nav => 0 },
);

# Ordered list of browsable types (drives routes and the generic listing logic).
our @ORDER = qw(
    ipblock device asset interface vlan vlangroup zone site room floor closet person
    rr rrns rrmx rrtxt rrnaptr entity service contactlist physaddr
    product availability ipblockstatus circuit arpcache sitelink fwtable stpinstance
    horizontalcable backbonecable ipservice dhcscope dhcpattrname producttype asn usertype
    contacttype dhcpscopetype entitytype
);

=encoding utf8

=head1 NAME

Netdot::Mojo::Registry - Registry of the browsable object types + shared display helpers

    Central registry of the object types browsable from the management UI
    (types(), with their class and routing info). The list columns, the
    object label and the descriptions are derived from the model meta
    (netdot.meta: "brief" / "all" views, table name/description) on the
    fly, which keeps the model the single source of truth. Also provides
    the shared display helpers used by every list / detail / search page
    (link_for, format_value, display_columns, csv_field, ...).

=head1 SYNOPSIS

    use Netdot::Mojo::Registry;

    my @types = Netdot::Mojo::Registry::types();
    my $spec  = Netdot::Mojo::Registry::spec( 'device' );
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for( $obj ) };

=head1 CLASS METHODS

=cut

=head2 types - List the browsable object types

Arguments:  None
Returns:    The ordered list of Registry type keys (drives the routes and the
            generic listing logic)

=cut

sub types { @ORDER }

# Navigation, organised into the 5 top-level sections of the original
# menu_admin.mhtml, each with its sub-menus (Registry type keys -> /management/<type>).
# A section is only shown when at least one of its sub-menus is visible to the user
# (see the nav builder in Netdot::Mojo). Types listed here must exist in %TYPES.
our %MENU = (
    management   => { title => 'Management',  types => [ qw(device asset vlan ipblock rr zone dhcscope) ] },
    contacts     => { title => 'Contacts',    types => [ qw(person entity contactlist) ] },
    cable_plant  => { title => 'Cable Plant', types => [ qw(site closet room floor) ] },
    generic      => { title => 'Advanced',    types => [] },
    reports      => { title => 'Reports',     types => [] },
    # Export (write-rights; see Permissions::can_export). Single action page (/export).
    # The other exporter types (Nagios/Sysmon/Rancid/...) stay admin-only (out of scope).
    export       => { title => 'Export',      types => [] },
    help         => { title => 'Help',        types => [] },
);
our @MENU_ORDER = qw(management contacts cable_plant generic reports export help);
# Ordered (key, meta) pairs for the navigation.
=head2 menu - Ordered navigation sections

Arguments:  None
Returns:    (key, meta) pairs for the top-level navigation sections
            (Management, Contacts, Cable Plant, Advanced, Reports, Export,
            Help), each with its sub-menu types

=cut

sub menu { map { [ $_, $MENU{$_} ] } @MENU_ORDER }

# Friendly navigation labels (match the original menu_admin.mhtml sub-section
# names). Falls back to the model meta name when a type is not listed here.
our %NAV_LABELS = (
    device => 'Devices',        asset     => 'Assets',
    vlan   => 'VLANs',          ipblock   => 'Address Space',
    rr     => 'DNS Records',    zone      => 'DNS Zones',
    person => 'People',         entity    => 'Entities',
    contactlist => 'Contact Lists',
    site   => 'Sites',          closet    => 'Closets',
    room   => 'Rooms',          floor     => 'Floors',
    interface => 'Interfaces',  physaddr  => 'MAC Addresses',
    service => 'Services',      dhcscope  => 'DHCP',
);
=head2 nav_label - Friendly navigation label of a type

Arguments:  type key
Returns:    The navigation label (e.g. device -> "Devices"), or undef when
            the type is not listed (the caller falls back to the model meta
            name)

=cut

sub nav_label { $NAV_LABELS{ $_[0] } }

# Reports sub-menu (fixed list, mirrors the original reports/autohandler
# sub_sections). Reports is an access_section => Admin + Operator only.
# key   => reports/<key> route, label => nav + landing title, desc => landing blurb.
our @REPORTS = (
    { key => 'device',    label => 'Devices',           desc => 'Device inventory by type/model, site, OS, mismatches' },
    { key => 'asset',     label => 'Assets',            desc => 'Asset inventory by type/model' },
    { key => 'ip',        label => 'IP',                desc => 'Unused subnets, maxed-out subnets, unused statics' },
    { key => 'macs',      label => 'MAC Addresses',     desc => 'MAC addresses by vendor (OUI)' },
    { key => 'topology',  label => 'Topology Graph',    desc => 'Whole-network topology (with/without VLANs)' },
    { key => 'pollstats', label => 'Polling Stats',     desc => 'Network addresses / devices / poll time over time' },
    { key => 'database',  label => 'Database Reports',  desc => 'MySQL table information' },
    { key => 'custom',    label => 'UNIL Reports',      desc => 'HINFO hosts, IP addresses by owner (used-by)' },
    { key => 'ipbat',     label => 'IP par Batiment',   desc => 'IP addresses per building/site' },
    { key => 'security',  label => 'Liste Verte',       desc => 'Hosts listed on the green (security) list' },
);
# Ordered list of the report nav items.
=head2 reports_menu - Reports sub-menu

Arguments:  None
Returns:    The list of report nav items ({ key, label, desc }), mirroring
            the original reports autohandler sub_sections

=cut

sub reports_menu { @REPORTS }

# Columns that must never be displayed (secrets / raw credentials).
#   password       - Person login password (SHA-256 digest)
#   snmp_authkey / snmp_privkey - SNMPv3 auth/priv credentials
#   authkey        - BGP session authentication key (BGPPeering)
# NOTE: Device `community` (SNMP v1/v2c community) is intentionally NOT listed —
# it is operational config shown in the HTML Device detail (the API mirrors that).
our %SENSITIVE = map { $_ => 1 } qw(password snmp_authkey snmp_privkey authkey);

# Accessors (avoid the "PKG::HASH{$x}" parse-as-method pitfall).
=head2 is_sensitive - Whether a column must never be displayed

Arguments:  column name
Returns:    1 for sensitive columns (password, snmp_authkey, snmp_privkey,
            authkey), 0 otherwise

=cut

sub is_sensitive { exists $SENSITIVE{ $_[0] } }

# Memoized spec for a type: { class, label, desc, cols, nav, ... }. label/desc/cols
# are derived from the model meta (single source of truth); an optional override in
# %TYPES wins. The model is loaded by the time this runs (requests), so meta_data
# is available; guard anyway.
our %SPEC;
=head2 spec - Memoized spec of a browsable type

Arguments:  type key
Returns:    { class, label, desc, cols, nav, ... }: class from %TYPES, and
            label/desc/cols derived from the model meta (netdot.meta: brief
            view columns, table name/description) — the model is the single
            source of truth; an override in %TYPES (label, cols) wins
Description: Memoized per key. Used to build the routes, the list/CSV
            columns and the generic pages.

=cut

sub spec {
    my ($key) = @_;
    my $base = $TYPES{$key} or return;
    return $SPEC{$key} if exists $SPEC{$key};
    my $class = $base->{class};
    my $meta  = eval { $class->meta_data };
    my $label = $base->{label} // ( $meta && eval { $meta->name } ) // $key;
    my $desc  = $meta ? eval { $meta->description } : undef;
    $desc  = '' unless defined $desc;
    # List/CSV columns: an explicit override in %TYPES wins, else the meta brief
    # view (falling back to the all view). See %TYPES (e.g. dhcscope).
    my @cols = $base->{cols} ? @{ $base->{cols} } : _brief_cols($class);
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

# User-friendly tag (label) of a column from the meta, falling back to the
# column name. Single source for the tag look-up that several controllers need.
=head2 column_tag - User-friendly tag of a column

Arguments:  class (name or object), column name
Returns:    The column's meta tag (e.g. serial_number -> "S/N"), falling back
            to the column name

=cut

sub column_tag {
    my ( $class, $col ) = @_;
    my $meta = eval { $class->meta_data };
    my $tag  = $meta ? eval { $meta->get_column( $col )->tag } : undef;
    return ( defined $tag && length $tag ) ? $tag : $col;
}

# Meta SQL type of a column ('bool', 'integer', 'varchar', ...). Accepts a class
# name or an object; returns undef when the column/type is unknown.
=head2 column_type - Meta SQL type of a column

Arguments:  class (name or object), column name
Returns:    The meta SQL type ('bool', 'integer', 'varchar', ...), or undef
            when the column/type is unknown

=cut

sub column_type {
    my ( $class, $col ) = @_;
    $class = ref( $class ) if ref( $class );
    my $meta = eval { $class->meta_data };
    return undef unless $meta;
    my $t = eval { $meta->get_column( $col )->sql_type };
    return $@ ? undef : $t;
}

# Registry key of the object a column links to (from the meta links_to), or
# undef when the column is not a foreign key. Lets a list render FK cells as
# links to the related object's detail page.
=head2 column_link_key - Registry key of a column's link target

Arguments:  class (name or object), column name
Returns:    The Registry key of the object the column links to (meta
            links_to), or undef when the column is not a foreign key. Lets a
            list render FK cells as links to the related object's detail
            page.

=cut

sub column_link_key {
    my ( $class, $col ) = @_;
    my $meta = eval { $class->meta_data };
    return undef unless $meta;
    my $tbl  = eval { $meta->get_column( $col )->links_to };
    return undef unless defined $tbl && length $tbl;
    return class_key( $tbl );
}

# HTML-escape a value for interpolation into raw (b()) cell HTML.
=head2 esc - HTML-escape a value

Arguments:  value
Returns:    The value escaped for interpolation into raw cell HTML
            (&, <, >, " -> entities; undef becomes the empty string)

=cut

sub esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# Ordered display columns for a class's "all" view (from netdot.meta "views"), as
# [ [col, tag], ... ]. The tag is the user-friendly label (e.g. serial_number ->
# "S/N", product_id -> "Product", info -> "Comments"). Falls back to the raw
# column list (minus id) when the class has no "all" view.
=head2 display_columns - Ordered display columns of the "all" view

Arguments:  class (name or object)
Returns:    [ [col, tag], ... ] in the netdot.meta "all" view order (the tag
            being the user-friendly label); falls back to the raw column
            list (minus id) when the class has no "all" view

=cut

sub display_columns {
    my ($class) = @_;
    my $meta  = $class->meta_data;
    my %order;
    eval { %order = $meta->get_column_order( view => 'all' ); 1 };
    my @cols  = sort { $order{$a} <=> $order{$b} } keys %order;
    @cols = grep { $_ ne 'id' } $class->columns unless @cols;
    return [ map { [ $_, column_tag( $class, $_ ) ] } @cols ];
}

# Ordered columns of a class's "brief" view (the same columns the list shows),
# as [ [col, tag], ... ], minus id. Used to drive the lightweight generic create
# form: only the key fields are offered, the model's insert() fills the rest.
=head2 display_brief_columns - Ordered columns of the "brief" view

Arguments:  class (name or object)
Returns:    [ [col, tag], ... ] of the brief view (the same columns the list
            shows), minus id. Drives the lightweight generic create form:
            only the key fields are offered, the model's insert() fills the
            rest.

=cut

sub display_brief_columns {
    my ($class) = @_;
    my @cols = _brief_cols( $class );
    @cols    = grep { $_ ne 'id' } $class->columns unless @cols;
    return [ map { [ $_, column_tag( $class, $_ ) ] } grep { $_ ne 'id' } @cols ];
}

# Map an object's class to its Registry key (the type used in routes/URLs).
# lc(short class name) works for every type EXCEPT DhcpScope (class "DhcpScope"
# -> "dhcpscope" but the registry key/route is "dhcscope"), so resolve by class
# through the %TYPES values when the naive lc() lookup misses.
our %CLASS_TO_KEY;
{
    my %seen;
    for my $key ( keys %TYPES ) {
        my $cls = $TYPES{$key}{class};
        $seen{$cls}                     = $key;
        $seen{ ( $cls =~ s/.*:://r ) }  = $key;
    }
    %CLASS_TO_KEY = %seen;
}
=head2 class_key - Map a class to its Registry key

Arguments:  class (name or object)
Returns:    The Registry type key used in routes/URLs (Site -> site,
            DhcpScope -> dhcscope). lc(short class name) is resolved through
            the %TYPES values first, so the DhcpScope/dhcscope mismatch is
            handled; falls back to lc(short name).

=cut

sub class_key {
    my ($class) = @_;
    return $CLASS_TO_KEY{$class} if exists $CLASS_TO_KEY{$class};
    my $short = $class =~ s/.*:://r;
    return $CLASS_TO_KEY{$short} if exists $CLASS_TO_KEY{$short};
    return lc $short;
}

# Render a (possibly inflated) column value as a display string.
# Relationships use the object's own ->get_label; fallback is "ShortClass #id".
=head2 format_value - Render a column value as a display string

Arguments:  value (scalar or inflated relationship object)
Returns:    The object's own ->get_label when it is a relationship (fallback
            "ShortClass #id"); the value itself otherwise (undef -> '')

=cut

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
=head2 link_for - [text, href] for a value

Arguments:  value (scalar or inflated relationship object)
Returns:    [ text, href ]: a relationship to a browsable type becomes a
            link to its detail page (/management/<type>/<id>); picture
            objects link to the binary route that serves the image inline;
            anything else is plain text (text falls back to
            "type #id" when the object has no label)

=cut

sub link_for {
    my ($v) = @_;
    return [ format_value($v) ] unless ref $v;
    my $class = ref $v;
    my $type  = class_key( $class );              # Site -> site, DhcpScope -> dhcscope
    my $id    = eval { "$v" };
    $id = '?' if $@ || !defined $id;
    my $text  = eval { $v->get_label };
    $text = class_key( $class ) . " #$id" unless defined $text && length $text;
    # Picture objects (SitePicture / ClosetPicture / FloorPicture) have no detail
    # page; their label links to the binary route that serves the image inline.
    my $href;
    if ( eval { $v->isa( 'Netdot::Model::Picture' ) } && $id =~ /^\d+$/ ) {
        $href = set_uri( "/management/$type/$id" );
    }
    elsif ( exists $TYPES{$type} && $id =~ /^\d+$/ ) {
        $href = set_uri( "/management/$type/$id" );
    }
    return [ $text, $href ];
}

# [text, href] for a scalar attribute value of column $col of $class. Boolean
# columns render as Yes/No (readable, consistent across the HTML detail
# pages); anything else delegates to link_for (plain text for a scalar,
# label+href for an FK).
=head2 attr_display - [text, href] for a scalar attribute value

Arguments:  class (name or object), column name, value
Returns:    [ text, href ]: boolean columns render as Yes/No (readable,
            consistent across the HTML detail pages); anything else
            delegates to link_for (plain text for a scalar, label+href for
            an FK)

=cut

sub attr_display {
    my ( $class, $col, $v ) = @_;
    if ( column_type( $class, $col ) eq 'bool' ) {
        return [ defined $v ? ( $v ? 'Yes' : 'No' ) : '', undef ];
    }
    my ( $text, $href ) = @{ link_for( $v ) };
    $text = '' unless defined $text;
    return [ $text, $href ];
}

# link_for() as a ready-to-emit HTML anchor: escaped label, prefixed href; empty
# string when there is no route. Safe for raw (<%== %>) output in templates.
=head2 link_html - link_for() as a ready-to-emit HTML anchor

Arguments:  value (scalar or inflated relationship object)
Returns:    An escaped <a href="...">label</a> string, or the empty string
            when there is no route. Safe for raw (<%== %>) output in
            templates.

=cut

sub link_html {
    my ($v) = @_;
    my ($t, $h) = @{ link_for( $v ) };
    return '' unless $h;
    return '<a href="' . $h . '">' . _hesc( $t ) . '</a>';
}

# Prefix an internal root-absolute path with the app's base URL (WEB_BASE_URL):
# "/management/rr/5" -> "/netdot/management/rr/5" (or unchanged at the domain
# root). Single source of truth for the base prefix -- used by link_for and the
# set_uri controller helper -- because controllers build some links by hand
# rather than via url_for(). Reads the base fresh so it needs no controller.
=head2 set_uri - Prefix an internal path with the app's base URL

Arguments:  root-absolute path (e.g. "/management/rr/5")
Returns:    The path prefixed with WEB_BASE_URL ("/netdot/management/rr/5"),
            unchanged at the domain root. Single source of truth for the
            base prefix — controllers build some links by hand rather than
            via url_for(). Reads the base fresh so it needs no controller.

=cut

sub set_uri {
    my ($uri) = @_;
    my $base = eval { Netdot->config->get('WEB_BASE_URL') } // '';
    $base    = '' unless defined $base && !ref $base;
    $base    =~ s{^https?://[^/]+}{};   # full URL -> keep only the path part
    $base    =~ s{/+$}{};               # strip trailing slash(es)
    $base    = '' if $base eq '/';
    my $path = $uri;
    $path    =~ s{^/+}{};               # drop leading slash(es); one re-added below
    return $base . '/' . $path;
}

# Escape a value for CSV (matches Netdot viewtext.html: comma -> space, quote -> apostrophe).
=head2 csv_field - Escape a value for CSV

Arguments:  value
Returns:    The value with commas replaced by spaces and double quotes by
            apostrophes (matches Netdot viewtext.html); undef -> ''

=cut

sub csv_field {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/,/ /g;
    $s =~ s/"/'/g;
    return $s;
}

=head1 AUTHOR

Vincent Magnin, C<< <Vincent.Magnin at unil.ch> >>

This code was written with the assistance of the Qwen 3.8-27b large
language model.

=head1 COPYRIGHT & LICENSE

Copyright 2026 University of Lausanne, all rights reserved.

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

# Make sure to return 1
1;