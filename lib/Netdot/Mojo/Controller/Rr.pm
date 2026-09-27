package Netdot::Mojo::Controller::Rr;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;

# Detail page for a DNS resource record (port of host.html, read-only). Shows the
# record itself plus each related record type (A/AAAA, HINFO, TXT, MX, CNAME,
# PTR, NS, DS, NAPTR, LOC, SRV), honouring the same display conditionals as the
# original. Write actions ([add]/[edit]/[delete]) are omitted (edit interface not
# yet migrated).
sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { RR->retrieve($id) };
    return $c->reply->not_found unless $o;

    $c->render(
        template   => 'management/rr',
        layout     => 'default',
        title      => 'DNS Record ' . _rr_label($o),
        rr         => $o,
        rr_attrs   => _rr_attributes( $o ),
        sections   => _rr_sections( $o ),
    );
}

# Minimal HTML escaping for text emitted from Perl (templates auto-escape <%= %>,
# but values built in controllers are inserted raw and must be escaped first).
sub _esc {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# An object's label as a link to its detail page (when a route exists).
sub _obj_link {
    my ($o) = @_;
    return '' unless $o;
    my ( $text, $href ) = @{ Netdot::Mojo::Registry::link_for( $o ) };
    return $href ? '<a href="' . $href . '">' . _esc($text) . '</a>' : _esc($text);
}

# Run a CDBI ->search and return a plain list. search() returns a
# Class::DBI::Iterator; wrapping it in eval() degrades the wantarray, so iterate
# explicitly (the same pitfall as ->children / ->has_many).
sub _search_all {
    my ( $class, %args ) = @_;
    my $it = eval { $class->search( %args ) };
    return () if $@ || !ref( $it );
    if ( $it->isa( 'Class::DBI::Iterator' ) ) {
        my @out;
        while ( my $k = $it->next ) { push @out, $k; }
        return @out;
    }
    return @$it;
}

# A bare domain name: link to the matching RR when one exists, else plain text.
sub _name_link {
    my ($name) = @_;
    return _esc($name) unless defined $name && length $name;
    my @rrs = _search_all( 'RR', name => $name );
    return _obj_link( $rrs[0] ) if @rrs && $rrs[0];
    return _esc($name);
}

sub _rr_label {
    my ($o) = @_;
    return eval { $o->get_label } // '';
}

# A datetime worth showing: defined, non-empty, and not a zero SQL date.
sub _dt_ok {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    return $s =~ /^0000-00-00/ ? 0 : 1;
}

# The record's own attribute table: [label, value_html] rows.
sub _rr_attributes {
    my ($o) = @_;
    my @rows;
    push @rows, [ 'Name', _esc( $o->name // '' ) ];
    push @rows, [ 'Zone', _obj_link( $o->zone ) ] if $o->zone;
    push @rows, [ 'Active', $o->active ? 'Yes' : 'No' ];
    push @rows, [ 'Comment', _esc( $o->info ) ]
        if defined $o->info && length $o->info;
    push @rows, [ 'Created', _esc( $o->created ) ]
        if _dt_ok( $o->created );
    push @rows, [ 'Modified', _esc( $o->modified ) ]
        if _dt_ok( $o->modified );
    push @rows, [ 'Expiration', _esc( $o->expiration ) ]
        if _dt_ok( $o->expiration );
    my @devs = eval { $o->devices } || ();
    push @rows, [ 'Device', _obj_link( $devs[0] ) ] if @devs && $devs[0];
    push @rows, [ 'Auto Update', $o->auto_update ? 'Yes' : 'No' ];
    return \@rows;
}

# Build [label, value_html] rows for one related record (a listref of pairs).
# Each related record type is a "section" of such record rows.

sub _rr_sections {
    my ($o) = @_;
    my @sections;
    my $name  = $o->name // '';
    my $zone  = $o->zone;
    my $zone_name = $zone ? ( eval { $zone->name } // '' ) : '';

    my @arecs = $o->a_records;
    my @cnames = $o->cnames;
    my @ptrs = $o->ptr_records;
    my @nsrs = $o->ns_records;

    # --- A/AAAA (RRADDR) ---
    my $show_addr = ( $name eq '@' || $name eq $zone_name
                      || ( ! @cnames && ! @ptrs ) );
    if ( $show_addr && @arecs ) {
        @arecs = sort { $a->ipblock->address_numeric <=> $b->ipblock->address_numeric } @arecs;
        my @recs;
        for my $arec (@arecs) {
            my $ipblock = $arec->ipblock;
            next unless $ipblock && $ipblock->id;
            my @row = (
                [ 'IP',  _obj_link($ipblock) ],
                [ 'TTL', _esc( $arec->ttl ) ],
            );
            # DHCP host scope for this address (MAC or DUID), like host.html
            my $scope = eval { $ipblock->dhcp_scopes->first };
            if ( $scope ) {
                if ( my $phys = eval { $scope->physaddr } ) {
                    push @row, [ 'DHCP', 'MAC: ' . _obj_link($phys) ];
                }
                elsif ( $ipblock->version == 6 && eval { $scope->duid } ) {
                    push @row, [ 'DHCP', 'DUID: ' . _esc( $scope->duid ) ];
                }
            }
            push @recs, \@row;
        }
        push @sections, { title => 'Address (A/AAAA)', records => \@recs } if @recs;
    }

    # --- HINFO (RRHINFO) ---
    my @hinfos = $o->hinfo_records;
    push @sections, { title => 'Hardware Information (HINFO)',
        records => [ map { [
            [ 'CPU', _esc($_->cpu) ], [ 'OS', _esc($_->os) ], [ 'TTL', _esc($_->ttl) ],
        ] } @hinfos ] } if @hinfos;

    # --- TXT (RRTXT) ---
    my @txts = $o->txt_records;
    push @sections, { title => 'Text Records (TXT)',
        records => [ map { [
            [ 'TXT', _esc($_->txtdata) ], [ 'TTL', _esc($_->ttl) ],
        ] } @txts ] } if @txts;

    # --- MX (RRMX) ---
    my @mxs = sort { $a->preference <=> $b->preference } $o->mx_records;
    push @sections, { title => 'Mail Exchangers (MX)',
        records => [ map { [
            [ 'Preference', _esc($_->preference) ],
            [ 'Exchange',   _name_link($_->exchange) ],
            [ 'TTL',        _esc($_->ttl) ],
        ] } @mxs ] } if @mxs;

    # --- MX records pointing to $o ---
    my @mxtarget = _search_all( 'RRMX', exchange => _rr_label($o) );
    if ( @mxtarget ) {
        @mxtarget = sort { $a->rr->name cmp $b->rr->name } @mxtarget;
        push @sections, { title => 'MX records pointing to ' . _rr_label($o),
            records => [ map { [ [ 'Owner', _obj_link($_->rr) ] ] } @mxtarget ] };
    }

    # --- CNAME: aliases of $o (something points to $o) ---
    my @aliases = $o->aliases;
    if ( @aliases ) {
        @aliases = sort { $a->rr->name cmp $b->rr->name } @aliases;
        push @sections, { title => 'Aliases of ' . _rr_label($o) . ' (CNAME)',
            records => [ map { [
                [ 'Alias', _obj_link($_->rr) ], [ 'TTL', _esc($_->ttl) ],
            ] } @aliases ] };
    }

    # --- CNAME: $o is an alias of something ---
    if ( ! @arecs && ! @ptrs && ! @nsrs ) {
        my @recs;
        for my $cname (@cnames) {
            my @row = ( [ 'TTL', _esc( $cname->ttl ) ] );
            unshift @row, [ 'Canonical Name', _name_link( $cname->cname ) ];
            push @recs, \@row;
        }
        push @sections, { title => _rr_label($o) . ' is an alias of (CNAME)',
            records => \@recs } if @recs;
    }

    # --- PTR: reverse for each A record IP ---
    if ( ! @cnames ) {
        my @recs;
        for my $arec (@arecs) {
            my $ipblock = $arec->ipblock;
            next unless $ipblock && $ipblock->id;
            my $ptr = eval { $ipblock->ptr_records->first };
            next unless $ptr;
            push @recs, [
                [ 'Reverse for', _obj_link($ipblock) ],
                [ 'Points to',   _obj_link( $ptr->rr ) ],
                [ 'TTL',         _esc( $ptr->ttl ) ],
            ];
        }
        push @sections, { title => 'Reverse DNS (PTR)', records => \@recs } if @recs;
    }

    # --- PTR: pointer records of $o (name is a PTR's name) ---
    if ( ! @arecs && ! @nsrs && @ptrs ) {
        my @recs;
        for my $ptr (@ptrs) {
            my $ipblock = $ptr->ipblock;
            push @recs, [
                [ 'IP',  _obj_link($ipblock) ],
                [ 'PTR', _name_link( $ptr->ptrdname ) ],
                [ 'TTL', _esc( $ptr->ttl ) ],
            ];
        }
        push @sections, { title => 'Pointer Records (PTR)', records => \@recs } if @recs;
    }

    # --- NS (RRNS) ---
    my $show_ns = ( $name eq '@' || $name eq $zone_name
                    || ( ! @arecs && ! @ptrs ) );
    if ( $show_ns && @nsrs ) {
        push @sections, { title => 'Name Servers (NS)',
            records => [ map { [
                [ 'Name Server', _name_link($_->nsdname) ], [ 'TTL', _esc($_->ttl) ],
            ] } @nsrs ] };
    }

    # --- DS (RRDS) ---
    my @dss = $o->ds_records;
    if ( ! @arecs && ! @ptrs && @dss ) {
        push @sections, { title => 'Delegation Signers (DS)',
            records => [ map { [
                [ 'Key Tag',     _esc($_->key_tag) ],
                [ 'Algorithm',   _esc($_->algorithm) ],
                [ 'Digest Type', _esc($_->digest_type) ],
                [ 'Digest',      _esc($_->digest) ],
                [ 'TTL',         _esc($_->ttl) ],
            ] } @dss ] };
    }

    # --- NAPTR (RRNAPTR) ---
    my @naptrs = $o->naptr_records;
    if ( ! @ptrs && @naptrs ) {
        push @sections, { title => 'Name Authority Pointer (NAPTR)',
            records => [ map { [
                [ 'Order',       _esc($_->order_field) ],
                [ 'Preference',  _esc($_->preference) ],
                [ 'Flags',       _esc($_->flags) ],
                [ 'Services',    _esc($_->services) ],
                [ 'Regex',       _esc($_->regexpr) ],
                [ 'Replacement', _esc($_->replacement) ],
                [ 'TTL',         _esc($_->ttl) ],
            ] } @naptrs ] };
    }

    # --- LOC (RRLOC) ---
    my @locs = $o->loc_records;
    if ( ! @ptrs && ! @nsrs && @locs ) {
        push @sections, { title => 'Location Records (LOC)',
            records => [ map { [
                [ 'Latitude',   _esc($_->latitude) ],
                [ 'Longitude',  _esc($_->longitude) ],
                [ 'Altitude',   _esc($_->altitude) ],
                [ 'Size',       _esc($_->size) ],
                [ 'Horiz. Pre', _esc($_->horiz_pre) ],
                [ 'Vert. Pre',  _esc($_->vert_pre) ],
                [ 'TTL',        _esc($_->ttl) ],
            ] } @locs ] };
    }

    # --- SRV (RRSRV) ---
    my @srvs = $o->srv_records;
    if ( $name =~ /^_.+\._.+/ && @srvs ) {
        push @sections, { title => 'Service Records (SRV)',
            records => [ map { [
                [ 'Priority', _esc($_->priority) ],
                [ 'Weight',   _esc($_->weight) ],
                [ 'Port',     _esc($_->port) ],
                [ 'Target',   _name_link($_->target) ],
                [ 'TTL',      _esc($_->ttl) ],
            ] } @srvs ] };
    }

    return \@sections;
}

1;
