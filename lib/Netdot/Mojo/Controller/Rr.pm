package Netdot::Mojo::Controller::Rr;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

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
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    # In-place edit form: scalar + FK fields, written via the JSON API (PATCH).
    # The system-managed timestamps (created/modified) are not user-editable.
    my $can_edit = $c->perm( 'edit', $o );
    my $fields   = [];
    my $api_path = '';
    if ($can_edit) {
        my %system = ( created => 1, modified => 1 );
        $fields   = [ grep { !$system{ $_->{name} } }
                      @{ Netdot::Mojo::Detail::build_edit_fields( $o, 'RR' ) } ];
        $api_path = $c->web_prefix . '/api/rr/' . $id;
    }

    $c->render(
        template   => 'management/rr',
        layout     => 'default',
        title      => 'DNS Record ' . _rr_label($o),
        rr         => $o,
        rr_attrs   => _rr_attributes( $o ),
        can_edit   => $can_edit,
        fields     => $fields,
        api_path   => $api_path,
        sections   => _rr_sections( $o ),
    );
}

# DNS Records search (port of host_tasks.html "search" action). The query term
# can be a name, an IP, or a MAC; an optional "names within" zone narrows the
# name lookup. A MAC resolves to PhysAddr, an IP to Ipblock, anything else to RR.
# A single hit goes straight to the object's detail page; otherwise the matches
# are listed (or a "not found" notice).
sub search ($c) {
    my $search = _trim( $c->param('search') // '' );
    $search = '*' if $search eq '';
    my $zone_id = $c->param('zone_id') // '';
    $zone_id = 0 if $zone_id !~ /^\d+$/;

    my $mac  = Netdot->get_mac_regex();
    my @list;
    if ( $search =~ /^$mac$/ ) {
        @list = _search_all( 'PhysAddr', address => $search );
    }
    elsif ( Ipblock->matches_ip($search) ) {
        @list = _search_all( 'Ipblock', address => $search );
    }
    else {
        my %args = ( name => $search );
        $args{zone} = $zone_id if $zone_id;
        @list = RR->search_like( %args );
    }

    # A single match opens the object's own page directly.
    if ( @list == 1 ) {
        my $obj   = $list[0];
        my $short = ref $obj; $short =~ s/.*:://;
        my $type  = lc $short;   # RR -> rr, Ipblock -> ipblock, PhysAddr -> physaddr
        return $c->redirect_to( Netdot::Mojo::Registry::set_uri( "/management/$type/" . $obj->id ) );
    }

    my ( @headers, @rows );
    if ( @list && ref( $list[0] ) =~ /PhysAddr/ ) {
        @headers = ( 'MAC Address' );
        @rows = map { { href => Netdot::Mojo::Registry::set_uri( "/management/physaddr/" . $_->id ), label => $_->address // '', cells => [] } } @list;
    }
    elsif ( @list && ref( $list[0] ) =~ /Ipblock/ ) {
        @headers = map { Netdot::Mojo::Registry::column_tag( 'Ipblock', $_ ) }
                   qw(address prefix status);
        @rows = map {
            { href => Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $_->id ), label => $_->address // '',
              cells => [ $_->prefix // '', Netdot::Mojo::Registry::format_value( $_->status ) ] }
        } @list;
    }
    else {
        @headers = ( 'Name', 'Zone' );
        @rows = map {
            { href => Netdot::Mojo::Registry::set_uri( "/management/rr/" . $_->id ), label => _rr_label( $_ ),
              cells => [ Netdot::Mojo::Registry::format_value( $_->zone ) ] }
        } @list;
    }

    $c->render(
        template   => 'management/search_results',
        layout     => 'default',
        title      => 'DNS Record Search',
        search     => $search,
        headers    => \@headers,
        rows       => \@rows,
        search_url => $c->url_for( 'rr_search' ),
    );
}

# Trim leading/trailing whitespace.
sub _trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
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

# The record's own detail-page href with a custom link text (plain text if the
# type has no detail route). Used to merge a value field with its record link.
sub _link_text {
    my ( $o, $text ) = @_;
    return _esc( $text ) unless $o;
    my ( $t, $href ) = @{ Netdot::Mojo::Registry::link_for( $o ) };
    return $href ? '<a href="' . $href . '">' . _esc( $text ) . '</a>' : _esc( $text );
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
    my @devs;
    eval { @devs = $o->devices };
    push @rows, [ 'Device', _obj_link( $devs[0] ) ] if @devs && $devs[0];
    push @rows, [ 'Auto Update', $o->auto_update ? 'Yes' : 'No' ];
    return \@rows;
}

# Field builders for the per-record inline edit. Each field has:
#   tag   : the display label.
#   ro    : pre-rendered read-only display HTML (always shown in the readonly
#           table; also shown in the edit form for non-editable fields, so the
#           user keeps context while editing).
#   name  : the column name, if the field is editable (undef otherwise).
#   kind  : input kind (number / text / textarea) for editable fields.
#   value : the scalar value (input default) for editable fields.
# Editable value fields: TTL (all types) + the record's own value(s) — cname,
# txtdata, MX exchange+preference, NS nsdname, NAPTR fields, PTR ptrdname.
# Written via the JSON API (PATCH /api/<type>/<id>), which runs the model
# update() (TTL validated by the model).

sub _f_ro {
    my ( $tag, $html ) = @_;
    return { tag => $tag, ro => ( defined $html ? $html : '' ) };
}

sub _f_ed {
    my ( $tag, $name, $kind, $value, $ro ) = @_;
    $value = '' unless defined $value;
    return {
        tag   => $tag,
        ro    => ( defined $ro ? $ro : _esc( $value ) ),
        name  => $name,
        kind  => $kind,
        value => $value,
    };
}

# A select field (kind 'select'). $options is an arrayref of [value, label]
# pairs (value = the DB column value, label = the human-readable text). The
# read-only display shows the current value's label (falls back to the raw
# value if it is not in the list).
sub _f_sel {
    my ( $tag, $name, $value, $options ) = @_;
    $value   = '' unless defined $value;
    $options = [] unless ref $options && ref $options eq 'ARRAY';
    my $label = $value;
    for my $opt ( @$options ) { $label = $opt->[1] if defined $opt->[0] && $opt->[0] eq $value; }
    return {
        tag     => $tag,
        ro      => _esc( $label ),
        name    => $name,
        kind    => 'select',
        value   => $value,
        options => $options,
    };
}

# Wrap a record's unified field list into the section-record structure the
# template renders (a readonly table + an inline edit form that shows every
# field — editable as inputs, non-editable as read-only).
sub _rec {
    my ( $rec, $type, $fields ) = @_;
    return { fields => $fields, id => eval { $rec->id }, type => $type };
}

# Build the unified field list (a listref of _f_ro/_f_ed hashes) for one related
# record. Each related record type is a "section" of such records.

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
                _f_ro( 'IP', _obj_link($ipblock) ),
                _f_ed( 'TTL', 'ttl', 'number', $arec->ttl ),
            );
            # DHCP host scope for this address (MAC or DUID), like host.html
            my $scope = eval { $ipblock->dhcp_scopes->first };
            if ( $scope ) {
                if ( my $phys = eval { $scope->physaddr } ) {
                    push @row, _f_ro( 'DHCP', 'MAC: ' . _obj_link($phys) );
                }
                elsif ( $ipblock->version == 6 && eval { $scope->duid } ) {
                    push @row, _f_ro( 'DHCP', 'DUID: ' . _esc( $scope->duid ) );
                }
            }
            push @recs, _rec( $arec, 'rraddr', \@row );
        }
        push @sections, { title => 'Address (A/AAAA)', records => \@recs } if @recs;
    }

    # --- HINFO (RRHINFO) ---
    # CPU/OS values come from the config lists (key = DB value, value = label),
    # rendered as a <select>. The current value is always offered as an option.
    my @hinfos = $o->hinfo_records;
    if ( @hinfos ) {
        my $cpu_vals = eval { Netdot->config->get('DEFAULT_HINFO_CPU_VALUES') } // {};
        my $os_vals  = eval { Netdot->config->get('DEFAULT_HINFO_OS_VALUES') } // {};
        my $opts = sub {
            my ( $hash, $cur ) = @_;
            my @o = map { [ $_, $hash->{$_} // $_ ] } sort keys %$hash;
            push @o, [ $cur, $cur ] if defined $cur && length $cur && !exists $hash->{$cur};
            return \@o;
        };
        push @sections, { title => 'Hardware Information (HINFO)',
            records => [ map {
                _rec( $_, 'rrhinfo', [
                    _f_sel( 'CPU', 'cpu', $_->cpu, $opts->( $cpu_vals, $_->cpu ) ),
                    _f_sel( 'OS',  'os',  $_->os,  $opts->( $os_vals,  $_->os  ) ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @hinfos ] };
    }

    # --- TXT (RRTXT) ---
    # The record link is merged into the TXT value (the record detail route is
    # reached by clicking the txtdata); no separate "Record" row (redundant).
    my @txts = $o->txt_records;
    push @sections, { title => 'Text Records (TXT)',
        records => [ map {
            _rec( $_, 'rrtxt', [
                _f_ed( 'TXT', 'txtdata', 'textarea', $_->txtdata, _link_text($_, $_->txtdata) ),
                _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
            ] ) } @txts ] } if @txts;

    # --- MX (RRMX) ---
    my @mxs = sort { $a->preference <=> $b->preference } $o->mx_records;
    push @sections, { title => 'Mail Exchangers (MX)',
        records => [ map {
            _rec( $_, 'rrmx', [
                _f_ed( 'Preference', 'preference', 'number', $_->preference, _link_text($_, $_->preference) ),
                _f_ed( 'Exchange', 'exchange', 'text', $_->exchange, _name_link($_->exchange) ),
                _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
            ] ) } @mxs ] } if @mxs;

    # --- MX records pointing to $o ---
    my @mxtarget = _search_all( 'RRMX', exchange => _rr_label($o) );
    if ( @mxtarget ) {
        @mxtarget = sort { $a->rr->name cmp $b->rr->name } @mxtarget;
        push @sections, { title => 'MX records pointing to ' . _rr_label($o),
            records => [ map {
                _rec( $_, 'rrmx', [
                    _f_ro( 'Owner', _obj_link($_->rr) ),
                    _f_ed( 'Preference', 'preference', 'number', $_->preference ),
                    _f_ed( 'Exchange', 'exchange', 'text', $_->exchange, _name_link($_->exchange) ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @mxtarget ] };
    }

    # --- CNAME: aliases of $o (something points to $o) ---
    # The target (cname) is $o itself — redundant here, so it is NOT shown nor
    # editable. The target is edited from the alias's own record (the "is an
    # alias of" section at the alias's URL).
    my @aliases = $o->aliases;
    if ( @aliases ) {
        @aliases = sort { $a->rr->name cmp $b->rr->name } @aliases;
        push @sections, { title => 'Aliases of ' . _rr_label($o) . ' (CNAME)',
            records => [ map {
                _rec( $_, 'rrcname', [
                    _f_ro( 'Alias', _obj_link($_->rr) ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @aliases ] };
    }

    # --- CNAME: $o is an alias of something ---
    if ( ! @arecs && ! @ptrs && ! @nsrs ) {
        my @recs;
        for my $cname (@cnames) {
            push @recs, _rec( $cname, 'rrcname', [
                _f_ed( 'Canonical Name', 'cname', 'text', $cname->cname, _name_link( $cname->cname ) ),
                _f_ed( 'TTL', 'ttl', 'number', $cname->ttl ),
            ] );
        }
        push @sections, { title => _rr_label($o) . ' is an alias of (CNAME)',
            records => \@recs } if @recs;
    }

    # --- PTR: reverse for each A record IP ---
    # Informational only (shows the reverse PTR of this record's IP). The PTR is
    # edited from the PTR record's own page (the "Pointer Records" section).
    if ( ! @cnames ) {
        my @recs;
        for my $arec (@arecs) {
            my $ipblock = $arec->ipblock;
            next unless $ipblock && $ipblock->id;
            my $ptr = eval { $ipblock->ptr_records->first };
            next unless $ptr;
            push @recs, _rec( $ptr, 'rrptr', [
                _f_ro( 'Reverse for', _obj_link($ipblock) ),
                _f_ro( 'Points to',   _obj_link( $ptr->rr ) ),
                _f_ro( 'TTL', _esc( $ptr->ttl ) ),
            ] );
        }
        push @sections, { title => 'Reverse DNS (PTR)', records => \@recs } if @recs;
    }

    # --- PTR: pointer records of $o (name is a PTR's name) ---
    if ( ! @arecs && ! @nsrs && @ptrs ) {
        my @recs;
        for my $ptr (@ptrs) {
            my $ipblock = $ptr->ipblock;
            push @recs, _rec( $ptr, 'rrptr', [
                _f_ro( 'IP', _obj_link($ipblock) ),
                _f_ed( 'PTR', 'ptrdname', 'text', $ptr->ptrdname, _name_link( $ptr->ptrdname ) ),
                _f_ed( 'TTL', 'ttl', 'number', $ptr->ttl ),
            ] );
        }
        push @sections, { title => 'Pointer Records (PTR)', records => \@recs } if @recs;
    }

    # --- NS (RRNS) ---
    my $show_ns = ( $name eq '@' || $name eq $zone_name
                    || ( ! @arecs && ! @ptrs ) );
    if ( $show_ns && @nsrs ) {
        push @sections, { title => 'Name Servers (NS)',
            records => [ map {
                _rec( $_, 'rrns', [
                    _f_ed( 'Name Server', 'nsdname', 'text', $_->nsdname, _link_text($_, $_->nsdname) ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @nsrs ] };
    }

    # --- DS (RRDS) ---
    my @dss = $o->ds_records;
    if ( ! @arecs && ! @ptrs && @dss ) {
        push @sections, { title => 'Delegation Signers (DS)',
            records => [ map {
                _rec( $_, 'rrds', [
                    _f_ed( 'Key Tag',     'key_tag',     'number', $_->key_tag ),
                    _f_ed( 'Algorithm',   'algorithm',   'number', $_->algorithm ),
                    _f_ed( 'Digest Type', 'digest_type', 'number', $_->digest_type ),
                    _f_ed( 'Digest',      'digest',      'text',   $_->digest ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @dss ] };
    }

    # --- NAPTR (RRNAPTR) ---
    my @naptrs = $o->naptr_records;
    if ( ! @ptrs && @naptrs ) {
        push @sections, { title => 'Name Authority Pointer (NAPTR)',
            records => [ map {
                _rec( $_, 'rrnaptr', [
                    _f_ed( 'Order',       'order_field', 'number', $_->order_field, _link_text($_, $_->order_field) ),
                    _f_ed( 'Preference',  'preference',  'number', $_->preference ),
                    _f_ed( 'Flags',       'flags',       'text',   $_->flags ),
                    _f_ed( 'Services',    'services',    'text',   $_->services ),
                    _f_ed( 'Regex',       'regexpr',     'text',   $_->regexpr ),
                    _f_ed( 'Replacement', 'replacement', 'text',   $_->replacement ),
                    _f_ed( 'TTL',         'ttl',         'number', $_->ttl ),
                ] ) } @naptrs ] };
    }

    # --- LOC (RRLOC) ---
    my @locs = $o->loc_records;
    if ( ! @ptrs && ! @nsrs && @locs ) {
        push @sections, { title => 'Location Records (LOC)',
            records => [ map {
                _rec( $_, 'rrloc', [
                    _f_ed( 'Latitude',   'latitude',  'number', $_->latitude ),
                    _f_ed( 'Longitude',  'longitude', 'number', $_->longitude ),
                    _f_ed( 'Altitude',   'altitude',  'number', $_->altitude ),
                    _f_ed( 'Size',       'size',      'text',   $_->size ),
                    _f_ed( 'Horiz. Pre', 'horiz_pre', 'text',   $_->horiz_pre ),
                    _f_ed( 'Vert. Pre',  'vert_pre',  'text',   $_->vert_pre ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @locs ] };
    }

    # --- SRV (RRSRV) ---
    my @srvs = $o->srv_records;
    if ( $name =~ /^_.+\._.+/ && @srvs ) {
        push @sections, { title => 'Service Records (SRV)',
            records => [ map {
                _rec( $_, 'rrsrv', [
                    _f_ed( 'Priority', 'priority', 'number', $_->priority ),
                    _f_ed( 'Weight',   'weight',   'number', $_->weight ),
                    _f_ed( 'Port',     'port',     'number', $_->port ),
                    _f_ed( 'Target',   'target',   'text',   $_->target, _name_link($_->target) ),
                    _f_ed( 'TTL', 'ttl', 'number', $_->ttl ),
                ] ) } @srvs ] };
    }

    return \@sections;
}

1;
