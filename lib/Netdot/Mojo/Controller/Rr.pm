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
    my $is_admin   = ( $c->user_type eq 'Admin' );
    my $can_edit   = $c->perm( 'edit', $o );
    my $can_delete = $c->perm( 'delete', $o );
    my $fields     = [];
    my $api_path   = '';
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
        can_delete => $can_delete,
        del_path   => $can_delete ? $c->web_prefix . '/api/rr/' . $id : '',
        del_goto   => $can_delete ? Netdot::Mojo::Registry::set_uri( '/management/rr' ) : '',
        sections   => _rr_sections( $o, is_admin => $is_admin ),
        add_types  => $can_edit ? _rr_add_types( $o, is_admin => $is_admin ) : [],
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

    # Paginate (DEFAULT_PERPAGE, like the list view). The single-match redirect
    # above already handles the 1-result case; offset is clamped into range.
    my $total  = scalar @list;
    my $per    = eval { Netdot::Model->config->get('DEFAULT_PERPAGE') } || 50;
    my $offset = $c->param('offset') // 0;
    $offset = 0 unless $offset =~ /^\d+$/;
    $offset = 0 if $offset >= $total;
    my $last   = $offset + $per; $last = $total if $last > $total;
    my @page   = $total ? @list[ $offset .. $last - 1 ] : ();

    # The result set is homogeneous per query: a MAC -> PhysAddr, an IP ->
    # Ipblock, otherwise RR names. Track the type so the results can offer
    # batch delete (each result type has its own /api/<type> endpoint).
    my ( @headers, @rows, $rclass, $rkey );
    if ( @page && ref( $page[0] ) =~ /PhysAddr/ ) {
        ( $rclass, $rkey ) = ( 'PhysAddr', 'physaddr' );
        @headers = ( 'MAC Address' );
        @rows = map { { id => $_->id, href => Netdot::Mojo::Registry::set_uri( "/management/physaddr/" . $_->id ), label => $_->address // '', cells => [] } } @page;
    }
    elsif ( @page && ref( $page[0] ) =~ /Ipblock/ ) {
        ( $rclass, $rkey ) = ( 'Ipblock', 'ipblock' );
        @headers = map { Netdot::Mojo::Registry::column_tag( 'Ipblock', $_ ) }
                   qw(address prefix status);
        @rows = map {
            { id => $_->id, href => Netdot::Mojo::Registry::set_uri( "/management/ipblock/" . $_->id ), label => $_->address // '',
              cells => [ $_->prefix // '', Netdot::Mojo::Registry::format_value( $_->status ) ] }
        } @page;
    }
    else {
        ( $rclass, $rkey ) = ( 'RR', 'rr' );
        @headers = ( 'Name', 'Zone' );
        @rows = map {
            # First column = rr.name (the relative name); the zone is its own column,
            # so the label must NOT be the full FQDN (get_label would repeat it).
            { id => $_->id, href => Netdot::Mojo::Registry::set_uri( "/management/rr/" . $_->id ), label => $_->name // '',
              cells => [ Netdot::Mojo::Registry::format_value( $_->zone ) ] }
        } @page;
    }

    # Batch delete on the results (only when the user may delete this type).
    my $del;
    if ( $rclass && @rows
         && Netdot::Mojo::Permissions->has_action( $rclass, $c->current_person, 'delete' ) ) {
        $del = { type => $rkey, api => $c->web_prefix . '/api/' . $rkey };
    }

    # Bulk edit on the results (only when the user may edit this type): the shared
    # field specs + each row's current values (netdot.js initBulkEdit, driven by
    # POST /api/<type>/batch). Same API pattern as the batch delete above.
    my $bulk;
    if ( $rclass && @rows
          && Netdot::Mojo::Permissions->has_action( $rclass, $c->current_person, 'edit' ) ) {
        my $data = Netdot::Mojo::Detail::bulk_edit_data( $rclass, \@page );
        $bulk = { type => $rkey, api => $c->web_prefix . '/api/' . $rkey . '/batch', %$data };
    }

    my $start      = @rows ? $offset + 1 : 0;
    my $last_item  = $offset + scalar(@rows);

    $c->render(
        template   => 'management/search_results',
        layout     => 'default',
        title      => 'DNS Record Search',
        search     => $search,
        headers    => \@headers,
        rows       => \@rows,
        search_url => $c->url_for( 'rr_search' ),
        del        => $del,
        bulk       => $bulk,
        total      => $total,
        per        => $per,
        offset     => $offset,
        start      => $start,
        last_item  => $last_item,
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

# Meta-driven field list for one related record (drives the per-record inline
# edit). Columns come from the record type's "all" view (netdot.meta) in meta
# order, so a column added to the meta becomes editable automatically. Each
# field is { tag, ro, name?, kind?, value?, options? }:
#   tag : display label (the meta tag).
#   ro  : read-only display HTML (readonly table; also the edit-form display for
#         non-editable fields so context is kept).
#   name/kind/value(/options) : set only for editable fields.
# FK columns are hidden unless listed in show_fk (they render as read-only
# links). Scalar columns are editable (kind from the meta sql_type) unless
# readonly; timestamp columns are skipped. Written via the JSON API
# (PATCH /api/<type>/<id>), which runs the model update(). Options:
#   readonly => 1                    : whole record read-only (no edit)
#   hidden   => [ cols ]             : hide these columns
#   show_fk  => { col => 'Label' }   : FK columns to show as links (with label)
#   selects  => { col => [ [v,l] ] } : render as a <select> (value = DB value,
#                                      label = display text)
#   links    => [ cols ]             : value is a domain name → link to the
#                                      matching RR (via _name_link)
#   link_on  => 'col'                : merge the record's own detail link onto
#                                      this field's read-only display
sub _rel_record {
    my ( $rec, %o ) = @_;
    my $readonly = $o{readonly} ? 1 : 0;
    my %hidden   = map { $_ => 1 } @{ $o{hidden}  // [] };
    my %show_fk  = %{ $o{show_fk}  // {} };
    my %selects  = %{ $o{selects}  // {} };
    my %links    = map { $_ => 1 } @{ $o{links}   // [] };
    my $link_on  = $o{link_on};

    my $meta  = $rec->meta_data;
    my %order;
    eval { %order = $meta->get_column_order( view => 'all' ) };
    my @cols = sort { $order{$a} <=> $order{$b} } keys %order;
    @cols = grep { $_ ne 'id' } sort keys %{ $meta->get_columns } unless @cols;

    my ( $lbl, $href ) = @{ Netdot::Mojo::Registry::link_for( $rec ) };

    my @fields;
    for my $c (@cols) {
        next if $hidden{$c};
        my $col  = $meta->get_column( $c );
        my $tag  = $col->tag // $c;
        my $sql  = $col->sql_type // '';
        my $lraw = $col->length // '';
        my $len  = $lraw =~ /^\d+$/ ? $lraw + 0 : 0;
        my $isfk = $col->links_to;
        my $val  = eval { $rec->$c };

        if ( $isfk ) {
            next unless exists $show_fk{$c};
            my $rel = eval { $rec->$c };
            my ( $rt, $rh ) = $rel ? @{ Netdot::Mojo::Registry::link_for( $rel ) }
                                   : ( '', undef );
            push @fields, {
                tag => $show_fk{$c},
                ro  => $rh ? '<a href="' . $rh . '">' . _esc( $rt ) . '</a>'
                           : _esc( $rt // '' ),
            };
            next;
        }
        next if $sql eq 'timestamp';

        $val = '' unless defined $val;
        $val = '' if $val =~ /^0000-00-00/;
        my $is_int = $sql =~ /^(?:integer|int|bigint|smallint|mediumint|tinyint)$/;
        my $kind = exists $selects{$c}                    ? 'select'
                 : $is_int                                 ? 'number'
                 : ( $sql eq 'varchar' && $len > 255 )     ? 'textarea'
                 : $sql eq 'text'                          ? 'textarea'
                 :                                           'text';

        my $ro;
        if ( exists $selects{$c} ) {
            my $lab = $val;
            for my $opt ( @{ $selects{$c} } ) {
                $lab = $opt->[1] if defined $opt->[0] && $opt->[0] eq $val;
            }
            $ro = _esc( $lab );
        }
        else {
            $ro = ( $links{$c} && length $val ) ? _name_link( $val ) : _esc( $val );
        }
        $ro = '<a href="' . $href . '">' . _esc( $val ) . '</a>'
            if $href && $c eq $link_on;

        my %f = ( tag => $tag, ro => $ro );
        unless ( $readonly ) {
            $f{name}  = $c;
            $f{kind}  = $kind;
            $f{value} = $val;
            $f{options} = $selects{$c} if exists $selects{$c};
        }
        push @fields, \%f;
    }
    return \@fields;
}

# Wrap a record's unified field list into the section-record structure the
# template renders (a readonly table + an inline edit form that shows every
# field — editable as inputs, non-editable as read-only).
sub _rec {
    my ( $rec, $type, $fields ) = @_;
    return { fields => $fields, id => eval { $rec->id }, type => $type };
}

# lc(db_name) => model class, for the add forms (same mapping the API uses; the
# type names below are lowercase table names, not class names — e.g. rrattr =>
# Netdot::Model::RRAttr).
my %_CLASS_BY_TABLE;
sub _rr_class_for_type {
    my ( $type ) = @_;
    return $_CLASS_BY_TABLE{ $type } if exists $_CLASS_BY_TABLE{ $type };
    for my $t ( Netdot->meta->get_tables() ) {
        $_CLASS_BY_TABLE{ lc( $t->db_name ) } = $t->name;
    }
    return $_CLASS_BY_TABLE{ $type };
}

# Field list for an "add new record" form (POST /api/<type>). Scalar columns come
# from the type's "all" view in meta order; the FK to the parent RR is auto-filled
# as a hidden field; any other FK is rendered as a <select> only when the
# referenced table is a small lookup. RRAttr is Admin-only (its raw value is
# written verbatim to the zone file). The IP-based types (A/AAAA and PTR) take an
# IP *address* the user types (the model's insert creates the Ipblock + any PTR),
# so they get an address field instead of the meta-driven scalar fields.
sub _rel_add_fields {
    my ( $type, $parent_id, $is_admin, $default_ttl ) = @_;
    return if $type eq 'rrattr' && ! $is_admin;
    if ( $type eq 'rraddr' || $type eq 'rrptr' ) {
        my @f = (
            { tag => 'Address',   kind => 'text',   name => 'ipblock',  value => '' },
            { tag => 'TTL',       kind => 'number', name => 'ttl',      value => $default_ttl // '' },
        );
        unshift @f, { tag => 'Forward name', kind => 'text', name => 'ptrdname', value => '' }
            if $type eq 'rrptr';
        return { type => $type, hidden => { rr => $parent_id }, fields => \@f };
    }
    my $classname = _rr_class_for_type( $type );
    my $class     = $classname ? "Netdot::Model::$classname" : undef;
    my $meta      = eval { $class && $class->meta_data };
    return unless $meta;
    my %order;
    eval { %order = $meta->get_column_order( view => 'all' ) };
    my @cols;
    if ( keys %order ) {
        @cols = sort { $order{$a} <=> $order{$b} } keys %order;
    }
    else {
        @cols = grep { $_ ne 'id' } $meta->get_column_names;
    }
    my ( %hidden, @fields );
    for my $c (@cols) {
        my $col  = $meta->get_column( $c );
        my $sql  = $col->sql_type // '';
        next if $c eq 'id' || $sql eq 'timestamp';
        my $lraw = $col->length // '';
        my $len  = $lraw =~ /^\d+$/ ? $lraw + 0 : 0;
        my $fk   = $col->links_to;
        if ( $fk ) {
            if ( $fk eq 'RR' ) {
                $hidden{$c} = $parent_id;      # owner = this record
            }
            else {
                my $refclass = "Netdot::Model::$fk";
                # COUNT via SQL (no row transfer — the target may be huge, e.g.
                # Ipblock). Only fetch the rows themselves when it's a small lookup.
                my $count  = eval { $refclass->search_count() };
                return if ! defined $count || $count > 100;
                my @opts;
                my $it = $refclass->retrieve_all;
                while ( my $r = $it->next ) {
                    my $lab = eval { $r->label };
                    $lab = eval { $r->name } unless defined $lab && length $lab;
                    $lab = $r->id unless defined $lab;
                    push @opts, [ $r->id, $lab ];
                }
                @opts = sort { $a->[1] cmp $b->[1] } @opts;
                push @fields, { tag => $col->tag // $c, kind => 'select',
                                name => $c, value => '', options => \@opts };
            }
            next;
        }
        my $kind = $sql =~ /^(?:integer|int|bigint|smallint|mediumint|tinyint)$/ ? 'number'
                 : ( $sql eq 'varchar' && $len > 255 )                            ? 'textarea'
                 : $sql eq 'text'                                                 ? 'textarea'
                 :                                                                  'text';
        # Default the TTL to the zone's default_ttl (new records inherit it).
        my $val = ( $c eq 'ttl' && defined $default_ttl ) ? $default_ttl : '';
        push @fields, { tag => $col->tag // $c, kind => $kind, name => $c, value => $val };
    }
    return { type => lc $type, hidden => \%hidden, fields => \@fields };
}

# The record types a user may add to this RR (each with its add-form field list).
# Types whose add form cannot be built inline (large FK, or Admin-only for a
# non-Admin) are omitted.
sub _rr_add_types {
    my ( $o, %opts ) = @_;
    my $is_admin    = $opts{is_admin} ? 1 : 0;
    my $default_ttl = eval { $o->zone->default_ttl };
    # No CNAME here: a CNAME is mutually exclusive with the other record types
    # (RFC 1035), so it is added via the dedicated "Add an alias" box instead.
    my $reverse = eval { $o->zone->is_dot_arpa } ? 1 : 0;
    my @types = (
        [ 'rraddr',  'Address (A/AAAA)' ],
        [ 'rrmx',    'MX (Mail Exchanger)' ],
        [ 'rrtxt',   'TXT (Text)' ],
        [ 'rrns',    'NS (Name Server)' ],
        [ 'rrhinfo', 'HINFO (Hardware)' ],
        [ 'rrsrv',   'SRV (Service)' ],
        [ 'rrds',    'DS (Delegation Signer)' ],
        [ 'rrnaptr', 'NAPTR' ],
        [ 'rrloc',   'LOC (Location)' ],
        [ 'rrattr',  'Other (CAA, HTTPS, …)' ],
    );
    push @types, [ 'rrptr', 'PTR (Reverse)' ] if $reverse;
    my @out;
    for my $t (@types) {
        my ( $type, $label ) = @$t;
        my $add = _rel_add_fields( $type, $o->id, $is_admin, $default_ttl );
        push @out, { type => $type, label => $label, add => $add } if $add;
    }
    return \@out;
}

# Build the unified field list (a listref of _f_ro/_f_ed hashes) for one related
# record. Each related record type is a "section" of such records.

sub _rr_sections {
    my ( $o, %opts ) = @_;
    my $is_admin = $opts{is_admin} ? 1 : 0;
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
            my $row = _rel_record( $arec, show_fk => { ipblock => 'IP' } );
            # DHCP host scope for this address (MAC or DUID), like host.html
            my $scope = eval { $ipblock->dhcp_scopes->first };
            if ( $scope ) {
                if ( my $phys = eval { $scope->physaddr } ) {
                    push @$row, { tag => 'DHCP', ro => 'MAC: ' . _obj_link($phys) };
                }
                elsif ( $ipblock->version == 6 && eval { $scope->duid } ) {
                    push @$row, { tag => 'DHCP', ro => 'DUID: ' . _esc( $scope->duid ) };
                }
            }
            push @recs, _rec( $arec, 'rraddr', $row );
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
                _rec( $_, 'rrhinfo', _rel_record(
                    $_,
                    selects => {
                        cpu => $opts->( $cpu_vals, $_->cpu ),
                        os  => $opts->( $os_vals,  $_->os  ),
                    },
                ) ) } @hinfos ] };
    }

    # --- TXT (RRTXT) ---
    # The record link is merged into the TXT value (the record detail route is
    # reached by clicking the txtdata); no separate "Record" row (redundant).
    my @txts = $o->txt_records;
    push @sections, { title => 'Text Records (TXT)',
        records => [ map {
            _rec( $_, 'rrtxt', _rel_record( $_, link_on => 'txtdata' ) )
        } @txts ] } if @txts;

    # --- MX (RRMX) ---
    my @mxs = sort { $a->preference <=> $b->preference } $o->mx_records;
    push @sections, { title => 'Mail Exchangers (MX)',
        records => [ map {
            _rec( $_, 'rrmx', _rel_record(
                $_, link_on => 'preference', links => [ 'exchange' ] ) )
        } @mxs ] } if @mxs;

    # --- MX records pointing to $o ---
    my @mxtarget = _search_all( 'RRMX', exchange => _rr_label($o) );
    if ( @mxtarget ) {
        @mxtarget = sort { $a->rr->name cmp $b->rr->name } @mxtarget;
        push @sections, { title => 'MX records pointing to ' . _rr_label($o),
            records => [ map {
                _rec( $_, 'rrmx', _rel_record(
                    $_, show_fk => { rr => 'Owner' }, links => [ 'exchange' ] ) )
            } @mxtarget ] };
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
                _rec( $_, 'rrcname', _rel_record(
                    $_, show_fk => { rr => 'Alias' }, hidden => [ 'cname' ] ) )
            } @aliases ] };
    }

    # --- CNAME: $o is an alias of something ---
    if ( ! @arecs && ! @ptrs && ! @nsrs ) {
        my @recs;
        for my $cname (@cnames) {
            push @recs, _rec( $cname, 'rrcname',
                _rel_record( $cname, links => [ 'cname' ] ) );
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
            push @recs, _rec( $ptr, 'rrptr', _rel_record(
                $ptr,
                readonly  => 1,
                show_fk   => { rr => 'Points to', ipblock => 'Reverse for' },
                hidden    => [ 'ptrdname' ],
            ) );
        }
        push @sections, { title => 'Reverse DNS (PTR)', records => \@recs } if @recs;
    }

    # --- PTR: pointer records of $o (name is a PTR's name) ---
    if ( ! @arecs && ! @nsrs && @ptrs ) {
        my @recs;
        for my $ptr (@ptrs) {
            push @recs, _rec( $ptr, 'rrptr', _rel_record(
                $ptr, show_fk => { ipblock => 'IP' }, link_on => 'ptrdname' ) );
        }
        push @sections, { title => 'Pointer Records (PTR)', records => \@recs } if @recs;
    }

    # --- NS (RRNS) ---
    my $show_ns = ( $name eq '@' || $name eq $zone_name
                    || ( ! @arecs && ! @ptrs ) );
    if ( $show_ns && @nsrs ) {
        push @sections, { title => 'Name Servers (NS)',
            records => [ map {
                _rec( $_, 'rrns', _rel_record( $_, link_on => 'nsdname' ) )
            } @nsrs ] };
    }

    # --- DS (RRDS) ---
    my @dss = $o->ds_records;
    if ( ! @arecs && ! @ptrs && @dss ) {
        push @sections, { title => 'Delegation Signers (DS)',
            records => [ map {
                _rec( $_, 'rrds', _rel_record( $_ ) )
            } @dss ] };
    }

    # --- NAPTR (RRNAPTR) ---
    my @naptrs = $o->naptr_records;
    if ( ! @ptrs && @naptrs ) {
        push @sections, { title => 'Name Authority Pointer (NAPTR)',
            records => [ map {
                _rec( $_, 'rrnaptr', _rel_record( $_, link_on => 'order_field' ) )
            } @naptrs ] };
    }

    # --- LOC (RRLOC) ---
    my @locs = $o->loc_records;
    if ( ! @ptrs && ! @nsrs && @locs ) {
        push @sections, { title => 'Location Records (LOC)',
            records => [ map {
                _rec( $_, 'rrloc', _rel_record( $_ ) )
            } @locs ] };
    }

    # --- SRV (RRSRV) ---
    my @srvs = $o->srv_records;
    if ( $name =~ /^_.+\._.+/ && @srvs ) {
        push @sections, { title => 'Service Records (SRV)',
            records => [ map {
                _rec( $_, 'rrsrv', _rel_record( $_, links => [ 'target' ] ) )
            } @srvs ] };
    }

    # --- RR attributes (modern record types: CAA, HTTPS, SSHFP, ...) ---
    # The value is a raw DNS record value (may contain spaces/quotes) written
    # verbatim to the zone file; a bad value can invalidate the whole zone. Editing
    # is therefore reserved to Admins (non-Admins see it read-only).
    my @attrs = eval { $o->attributes };
    if ( @attrs ) {
        push @sections, {
            title  => 'Other Record Types (CAA, HTTPS, …)',
            warn   => 'Reserved for administrators. The value is written to the zone '
                    . 'file verbatim; an invalid value can invalidate the whole zone.',
            records => [ map {
                _rec( $_, 'rrattr', _rel_record(
                    $_, show_fk => { name => 'Type' }, readonly => ( $is_admin ? 0 : 1 ) ) )
            } @attrs ] };
    }

    return \@sections;
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