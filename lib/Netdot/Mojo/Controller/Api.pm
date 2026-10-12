package Netdot::Mojo::Controller::Api;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Exporter;
use Netdot::Mojo::Api;
use Netdot::Mojo::Detail;
use Netdot::Mojo::Permissions;
use Netdot::Mojo::OpenAPI;
use Mojo::Util qw(url_escape);

# JSON API (port of the legacy /rest handlers + Netdot::REST), served under
# /api. Auth = the Netdot web session (same as the HTML views). Serializes to
# JSON only. OpenAPI spec at /api/openapi.yaml, Swagger UI at /api/docs.
#
# Resources:
#   GET    /api/{table}            list all (or search with ?col=val)
#   GET    /api/{table}/{id}       single object (depth, linked_from options)
#   GET    /api/{table}/meta_data  class metadata
#   POST   /api/{table}            create        (body: {col:val, fk: <id>})
#   POST   /api/{table}/{id}       update
#   DELETE /api/{table}/{id}       delete
#   GET    /api/devinfo[?site=]    device info dump
#   GET    /api/host_contacts      DNS + contact info for an IP
#   GET    /api/ipattr?addr=       inherited IP attributes
#   GET/POST/DELETE /api/host      DNS/DHCP host manipulation
#   GET/POST/DELETE /api/host_like same as host, fuzzy name search
#   POST   /api/updatedev          device discovery

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# Logged-in Person, or render 401 and return undef.
sub _person {
    my ($c) = @_;
    my $p = $c->current_person;
    unless ($p) {
        $c->render( json => { error => 'Authentication required' }, status => 401 );
        return undef;
    }
    return $p;
}

# Run a block; convert Netdot::Mojo::Api::Error -> its HTTP code, anything else
# -> 500. Returns the block's return value on success.
sub _run {
    my ( $c, $code ) = @_;
    my $result = eval { $code->() };
    if ( my $e = $@ ) {
        if ( ref $e && $e->isa( 'Netdot::Mojo::Api::Error' ) ) {
            $c->render( json => { error => $e->msg }, status => $e->code );
        }
        else {
            $c->app->log->error( "API error: $e" );
            $c->render( json => { error => "Internal error: $e" }, status => 500 );
        }
        return;
    }
    return $result;
}

sub _err {
    my ( $code, $msg ) = @_;
    die Netdot::Mojo::Api::Error->new( code => $code, msg => $msg );
}

# Merge query params + JSON body (body wins) into one hashref.
# NB: use params->to_hash, NOT params->names: the system Mojo::Parameters is
# patched so names() returns an arrayref (not a list), which would corrupt the
# hash (single key "ARRAY(0x..)"). to_hash() is unpatched and returns the last
# value per key, matching the original intent.
sub _args {
    my ($c) = @_;
    my %a = %{ $c->req->params->to_hash };
    my $body = eval { $c->req->json };
    %a = ( %a, %$body ) if ref $body eq 'HASH';
    return \%a;
}

# Search args: drop control keys, undef and empty-string values.
sub _search_args {
    my ($a) = @_;
    my %c;
    for my $k ( keys %$a ) {
        next if $k eq 'depth'     || $k eq 'linked_from';
        next if $k eq 'limit'     || $k eq 'offset';
        next unless defined $a->{$k};
        next if ref $a->{$k};
        $c{$k} = $a->{$k} if $a->{$k} ne '';
    }
    return \%c;
}

# lc(db_name) => model class, for the generic resource router.
sub _model_tables {
    my %tables;
    my $m = Netdot->meta;
    for my $t ( $m->get_tables() ) { $tables{ lc( $t->db_name ) } = $t->name }
    return %tables;
}

# CDBI search that turns a bad-column error into a 400.
sub _search {
    my ( $class, %args ) = @_;
    my $r = eval { $class->search(%args) };
    _err( 400, "Bad search: $@" ) if $@;
    return $r;
}

# ---------------------------------------------------------------------------
# API index (GET /api)
# ---------------------------------------------------------------------------

# Public base (no trailing slash) for absolute API URLs. If WEB_BASE_URL is a
# full URL, use it; if it is a bare path prefix (/netdot), build <request
# origin><prefix> so the result is correct on dev and prod alike (Netbox-style).
sub _base_url {
    my ($c) = @_;
    my $cfg = eval { Netdot->config->get('WEB_BASE_URL') };
    $cfg = '' unless defined $cfg && !ref $cfg;
    my $b;
    if ( $cfg =~ m{^https?://} ) {
        $b = $cfg;
    }
    else {
        my $origin = $c->req->url->base->to_string;   # scheme://host[:port]/
        $origin =~ s{/+$}{};
        $b = $origin . $cfg;                          # <origin> + prefix
    }
    $b =~ s{/+$}{};
    return $b;
}

# Paginated list URL for a table: <base>/<lc table>/?<search args>&limit=&offset=
# Uses the relative API base (WEB_BASE_URL + /api) so the pointer is host-agnostic.
sub _page_url {
    my ( $class, $sargs, $limit, $offset ) = @_;
    my @kv;
    push @kv, url_escape($_) . '=' . url_escape($sargs->{$_}) for sort keys %$sargs;
    push @kv, "limit=$limit", "offset=$offset";
    my $base = Netdot::Mojo::Api::_api_base() . '/' . lc( $class->short_class ) . '/';
    return $base . '?' . join( '&', @kv );
}

# A machine-readable landing point, Netbox-style: a flat {resource: absolute-url}
# map. Every model table plus the purpose-built endpoints and the docs/spec.
# GET only (else 405 JSON).
sub root {
    my ($c) = @_;
    return $c->render( json => { error => 'Method not allowed', path => $c->web_prefix . '/api' }, status => 405 )
        unless $c->req->method eq 'GET';

    my $base = _base_url($c);
    my $url  = sub { $base . $_[0] };

    my %index;
    my %tables = _model_tables();
    $index{$_} = $url->("/api/$_") for sort keys %tables;

    # Purpose-built endpoints (same flat name -> url style).
    for my $ep (qw(devinfo host_contacts host host_like ipattr updatedev)) {
        $index{$ep} = $url->("/api/$ep");
    }
    $index{docs}           = $url->('/api/docs');
    $index{'openapi.yaml'} = $url->('/api/openapi.yaml');

    $c->render( json => \%index, status => 200 );
}

# ---------------------------------------------------------------------------
# generic resource router
# ---------------------------------------------------------------------------

sub generic {
    my ($c) = @_;
    my $p = _person($c) or return;

    my $tparam = $c->param('table');
    my $id     = $c->param('id');
    my $args   = _args($c);
    my $method = $c->req->method;

    my %tables = _model_tables();
    my $class  = $tables{ lc($tparam) };
    unless ($class) {
        return $c->render( json => { error => "Unknown table: $tparam" }, status => 400 );
    }

    return _run( $c, sub {
        if ( defined $id && $id eq 'meta_data' ) {
            my $m    = $class->meta_data;
            my %meta = %$m;
            delete $meta{meta};
            return $c->render( json => \%meta, status => 200 );
        }

        if ( defined $id && $id =~ /^\d+(?:,\d+)*$/ ) {
            if ( $method eq 'DELETE' ) {
                my @ids = split /,/, $id;
                if ( @ids > 1 ) {
                    # Batch delete: one call for many rows (?id=2,3,4). Each id is
                    # resolved and permission-checked on its own, so one bad id does
                    # not abort the rest (the UI reports the per-id outcome).
                    my ( $deleted, $skipped ) = _batch_delete( $class, $p, \@ids );
                    my %res = ( deleted => $deleted );
                    $res{skipped} = $skipped if keys %$skipped;
                    return $c->render( json => \%res, status => @$deleted ? 200 : 400 );
                }
                _delete( $class, $id, $p, $args );
                return $c->render( json => { deleted => "$class/$id" }, status => 200 );
            }
            _err( 400, "Bad id: $id" ) if $id =~ /,/;    # lists are DELETE-only

            if ( $method eq 'GET' ) {
                my $obj = $class->retrieve($id);
                _err( 404, "$class/$id not found" ) unless $obj;
                unless ( Netdot::Mojo::Permissions->can( $p, 'view', $obj ) ) {
                    _err( 403, 'User not allowed to view this object' );
                }
                my %ga = ( obj => $obj );
                $ga{depth}       = int( $args->{depth} ) if defined $args->{depth} && $args->{depth} ne '';
                $ga{linked_from} = 1                   if defined $args->{linked_from} && $args->{linked_from} ne '0';
                return $c->render( json => Netdot::Mojo::Api::get( $obj, $p, undef, %ga ), status => 200 );
            }
            elsif ( $method eq 'POST' || $method eq 'PATCH' || $method eq 'PUT' ) {
                return $c->render( json => _post( $class, $id, $args, $p ), status => 200 );
            }
            elsif ( $method eq 'DELETE' ) {
                _delete( $class, $id, $p );
                return $c->render( json => { deleted => "$class/$id" }, status => 200 );
            }
            else {
                return $c->render( json => { error => "Method $method not allowed" }, status => 405 );
            }
        }

        # plural (no id) -> paginated list (Netbox-style envelope)
        if ( $method eq 'GET' ) {
            # FK keyword search (?kw=<kw>&limit=N): lightweight {id,label} results
            # for a <select> (edit-mode FK picker). Mirrors the legacy select_lookup:
            # big tables (RR, Ipblock, ...) are searched, never dumped into a dropdown.
            # Default: LIKE %kw% on the label column. Ipblock is special: its address
            # is a bigint (decimal), so a raw LIKE can't match the dotted form -- use
            # the model's search overrides (string->int): exact/CIDR match first, then
            # the prefix-range search_like for partial addresses.
            if ( defined $args->{kw} && length $args->{kw} ) {
                my $kw   = $args->{kw};
                my @lbl  = eval { $class->meta_data->get_labels };
                my $lcol = @lbl ? $lbl[0] : 'name';
                my $lim  = int( $args->{limit} // 50 );
                $lim = 50  if $lim < 1;
                $lim = 500 if $lim > 500;
                my @objs;
                if ( $class eq 'Ipblock' ) {
                    # exact / CIDR match first (string->int). List context is kept
                    # inside the eval so the Class::DBI iterator expands to a full
                    # list; on a partial keyword search() throws and we fall through
                    # to the prefix-range search_like (which handles '10.0' etc.).
                    my $ok = eval { @objs = $class->search( address => $kw ); 1 };
                    @objs = () unless $ok;
                    if ( !@objs ) {
                        $ok = eval { @objs = $class->search_like( address => $kw ); 1 };
                        @objs = () unless $ok;
                    }
                    # search_like can resolve the same block more than once; dedupe
                    # by id (the legacy keyword_search did so via a hash keyed by id).
                    my %seen;
                    @objs = grep { !defined $_ || !$seen{ $_->id }++ } @objs;
                    @objs = @objs[ 0 .. ( $lim - 1 ) ] if @objs > $lim;
                }
                else {
                    my ( $pwhere ) = Netdot::Mojo::Permissions->viewable_predicate( $class, $p );
                    @objs = eval {
                        $class->search_page( where => $pwhere, like => [ $lcol, $kw ], order_by => $lcol, limit => $lim, offset => 0 );
                    };
                    _err( 500, "Search failed: $@" ) if $@;
                }
                if ( Netdot::Mojo::Permissions->user_type( $p ) eq 'User' ) {
                    my $access = Netdot::Mojo::Permissions->allowed_objects( $class, $p );
                    @objs = grep { Netdot::Mojo::Permissions->can( $class, $p, 'view', $_, $access ) } @objs;
                }
                my @results =
                    map { { id => $_->id, label => ( eval { $_->get_label } || '#' . $_->id ) } } @objs;
                return $c->render( json => { count => scalar( @results ), results => \@results }, status => 200 );
            }

            my $depth       = ( defined $args->{depth} && $args->{depth} ne '' ) ? int( $args->{depth} ) : 0;
            my $linked_from = ( defined $args->{linked_from} && $args->{linked_from} ne '0' ) ? 1 : undef;
            my $limit       = ( defined $args->{limit}   && $args->{limit}   ne '' ) ? int( $args->{limit}   ) : 50;
            my $offset      = ( defined $args->{offset}  && $args->{offset}  ne '' ) ? int( $args->{offset}  ) : 0;
            $limit  = 50   if $limit  < 1;
            $limit  = 1000 if $limit  > 1000;
            $offset = 0    if $offset < 0;

            my $sargs = _search_args( $args );
            # Permission filter at the query level (fast count + paging): a User
            # sees only objects they may 'view'; Admin/Operator are unrestricted.
            my ( $pwhere ) = Netdot::Mojo::Permissions->viewable_predicate( $class, $p );
            my $count = $class->search_count( %$sargs, where => $pwhere );
            my @page  = $class->search_page( %$sargs, limit => $limit, offset => $offset, where => $pwhere );

            my @results;
            for my $o (@page) {
                # Safety net: skip anything the query-level predicate let through
                # that the fine-grained rule does not actually allow viewing.
                next unless Netdot::Mojo::Permissions->can( $p, 'view', $o );
                my %ga = ( obj => $o, depth => $depth );
                $ga{linked_from} = $linked_from if $linked_from;
                push @results, Netdot::Mojo::Api::get( $o, $p, undef, %ga );
            }

            my $next = ( $offset + $limit < $count )
                ? _page_url( $class, $sargs, $limit, $offset + $limit )
                : undef;
            my $prev = $offset > 0
                ? _page_url( $class, $sargs, $limit, $offset - $limit )
                : undef;

            return $c->render( json => {
                count    => $count,
                next     => $next,
                previous => $prev,
                results  => \@results,
            }, status => 200 );
        }
        elsif ( $method eq 'POST' ) {
            return $c->render( json => _post( $class, undef, $args, $p ), status => 200 );
        }
        else {
            return $c->render( json => { error => "Method $method not allowed" }, status => 405 );
        }
    });
}

# Parent class + FK column a CREATE must be gated on (per-parent enforcement).
# Mirrors the inheritance the permission model applies on read (Interface->Device,
# RR*->Zone, Contact->ContactList). Returns () if the class has no such parent ->
# fall back to the class-level 'edit' right.
sub _create_parent {
    my ( $class ) = @_;
    my $otype = eval { $class->short_class } // lc($class);
    return ( 'Device',      'device' )      if $otype eq 'Interface';
    return ( 'ContactList', 'contactlist' ) if $otype eq 'Contact';
    # A base RR owns its zone directly; record sub-types (rrtxt, rrcname, rrns,
    # ...) hang off a parent RR (fk `rr`), whose zone grants the rights.
    return ( 'Zone',        'zone' )        if $otype eq 'RR';
    return ( 'RR',          'rr' )          if $otype =~ /^RR/;
    return ();
}

# Classes whose write operations (create/update/delete) are reserved to Admins:
# raw values written verbatim to zone files; a bad value can invalidate the zone.
sub _admin_only_write {
    my ( $class ) = @_;
    my $short = eval { $class->short_class } // lc( $class );
    return $short eq 'RRAttr';
}

# May $p create an object of $class from args %a?
#   - Admin: yes (insert validates required fields).
#   - Parented class: require 'edit' on the SPECIFIC parent the record would
#     belong to (e.g. an RR only if the zone it's created in is editable).
#   - Otherwise: require 'edit' on the class as a whole (has_action).
sub _can_create {
    my ( $class, $p, $a ) = @_;
    return 1 if Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin';
    return 0 if _admin_only_write( $class );
    my ( $parent_class, $fk ) = _create_parent( $class );
    if ( $parent_class ) {
        my $pid = $a->{$fk};
        return 0 unless defined $pid && $pid =~ /^\d+$/;
        my $parent = $parent_class->retrieve( $pid );
        return 0 unless $parent;
        return Netdot::Mojo::Permissions->can( $p, 'edit', $parent );
    }
    return Netdot::Mojo::Permissions->has_action( $class, $p, 'edit' );
}

# Create or update via the generic router. FK fields are passed as their id.
sub _post {
    my ( $class, $id, $args, $p ) = @_;
    my %a = %$args;
    # Never let a client control model-update internals: `validate` /
    # `no_update_tree` are read by the models' update() and would let a request
    # skip validation / tree maintenance (e.g. an invalid Ipblock status).
    delete @a{qw(depth linked_from validate no_update_tree)};
    my $obj;
    if ($id) {
        $obj = $class->retrieve($id);
        _err( 404, "$class/$id not found" ) unless $obj;
        _err( 403, 'Editing this object is reserved for administrators' )
            if _admin_only_write( $class ) && Netdot::Mojo::Permissions->user_type( $p ) ne 'Admin';
        unless ( Netdot::Mojo::Permissions->can( $p, 'edit', $obj ) ) {
            _err( 403, 'User not allowed to edit this object' );
        }
        eval { $obj->update(\%a) };
        _err( 400, "Bad request: $@" ) if $@;
    }
    else {
        # Note: no argument translation here. The record models already handle
        # domain knowledge: RRADDR/RRPTR->_convert_ipblock resolve an `ipblock`
        # given as an address string (Ipblock->search, created if missing),
        # RR->insert dispatches on `type` to the right record class, RRCNAME/
        # RRPTR enforce mutual exclusivity, and TTLs fall back to the zone
        # default. The controller only adds permission checks.
        # Per-parent enforcement: a User may create the object only if they hold
        # 'edit' on the specific parent it belongs to (or, for parentless classes,
        # on the class as a whole). Admin is unrestricted.
        unless ( _can_create( $class, $p, \%a ) ) {
            _err( 403, 'User not allowed to create this object' );
        }
        # Drop empty-string values so the model's insert() applies its defaults
        # (and column defaults) instead of storing '' — the form sends blank
        # text/number fields as "". FK selects already submit null when empty.
        delete @a{ grep { defined $a{$_} && $a{$_} eq '' } keys %a };
        my $new = eval { $class->insert(\%a) };
        _err( 400, "Bad request: $@" ) if $@;
        $obj = $new;
    }
    return Netdot::Mojo::Api::get( $obj, $p, undef, depth => 0 );
}

sub _delete {
    my ( $class, $id, $p, $args ) = @_;
    $args = {} unless ref $args eq 'HASH';
    my $obj = $class->retrieve($id);
    _err( 404, 'Not found' ) unless $obj;
    _err( 403, 'Deleting this object is reserved for administrators' )
        if _admin_only_write( $class ) && Netdot::Mojo::Permissions->user_type( $p ) ne 'Admin';
    unless ( Netdot::Mojo::Permissions->can( $p, 'delete', $obj ) ) {
        _err( 403, 'User not allowed to delete this object' );
    }
    # Per-class delete options (default-off, offered by the UI). $class is the SHORT
    # package name (see _model_tables / _admin_only_write), so compare via short_class,
    # not the full Netdot::Model::* name.
    #   Device  - delete_ips also removes the device's IP addresses (and their DNS
    #             A/AAAA records), which cascades to the name RR once it has no
    #             sub_records.
    #   Ipblock - recursive deletes the block AND all its children; when omitted,
    #             _tree_delete() re-attaches the children to the block's parent.
    # Other classes' delete() take no args, so thread only where needed.
    my %dopts;
    my $dshort = eval { $class->short_class } // lc( $class );
    if ( $dshort eq 'Device' ) {
        $dopts{delete_ips}     = 1 if _truthy( $args->{delete_ips} );
        $dopts{no_delete_name} = 1 if _truthy( $args->{no_delete_name} );
    }
    elsif ( $dshort eq 'Ipblock' ) {
        $dopts{recursive} = 1 if _truthy( $args->{recursive} );
    }
    eval { $obj->delete( %dopts ) };
    _err( 400, 'Bad request' ) if $@;
}

# Coerce a request value (query string / JSON) to a boolean flag (1/0). Empty,
# "0"/"false"/"no" and undef are falsy; anything else is truthy.
sub _truthy {
    my ($v) = @_;
    return 0 unless defined $v;
    return 0 if $v eq '' || $v eq '0' || $v eq 'false' || $v eq 'no';
    return 1;
}

# Batch delete (?id=1,2,3): one call for many rows. Mirrors _delete's checks per
# object; a missing id or a denied delete is reported per id instead of aborting.
sub _batch_delete {
    my ( $class, $p, $ids ) = @_;
    my ( @deleted, %skipped );
    for my $oid ( @$ids ) {
        my $obj = eval { $class->retrieve( $oid ) };
        if ( $@ || ! $obj ) { $skipped{$oid} = 'not found'; next; }
        my $ok = Netdot::Mojo::Permissions->can( $p, 'delete', $obj );
        $ok = 0 if _admin_only_write( $class ) && Netdot::Mojo::Permissions->user_type( $p ) ne 'Admin';
        unless ($ok) { $skipped{$oid} = 'not allowed'; next; }
        if ( eval { $obj->delete } ) { push @deleted, "$class/$oid"; }
        else { $skipped{$oid} = 'delete failed'; }
    }
    return ( \@deleted, \%skipped );
}

# Create a new alias (CNAME) pointing at $o: a new RR (the alias name) plus a
# rrcname (rr=new, cname=$o). The zone for the new name is resolved from the
# entered name: a short name stays in $o's zone; a name whose domain part matches
# a zone the user can edit is mapped to that zone (zone part stripped); any other
# long name is placed in $o's zone as a label (www.google.com -> www.google.com.localdomain).
# Conflicts (the name already has records) are handled by RRCNAME->insert internally.
sub _create_alias {
    my ( $o, $name, $ttl, $p ) = @_;
    my $zone = $o->zone;
    _err( 400, 'This RR has no zone' ) unless $zone && $zone->id;
    my $an    = $name;
    my @parts = split /\./, $name;
    if ( @parts > 1 ) {
        for my $i ( 1 .. $#parts ) {
            my $dom = join( '.', @parts[ $i .. $#parts ] );
            my $z   = eval { Zone->search( name => $dom )->first };
            if ( $z && Netdot::Mojo::Permissions->can( $p, 'edit', $z ) ) {
                $zone = $z;
                $an   = join( '.', @parts[ 0 .. $i - 1 ] );
                last;
            }
        }
    }
    my %ins = ( name => $an, zone => $zone->id, type => 'CNAME', cname => $o->get_label );
    $ins{ttl} = $ttl if defined $ttl && length $ttl;
    my $rec = eval { RR->insert( \%ins ) };
    _err( 400, "Bad request: $@" ) if $@;
    return $rec;
}

 # POST /api/rr/:id/alias  {name, ttl} — create a new alias pointing at the RR.
sub alias {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $tparam = $c->param('table');
        my $id     = $c->param('id');
        my $args   = _args($c);
        _err( 400, 'Alias creation is only supported for RR' )
            unless lc($tparam) eq 'rr';
        _err( 400, 'Missing id' ) unless defined $id && $id =~ /^\d+$/;
        my $o = RR->retrieve($id);
        _err( 404, "RR/$id not found" ) unless $o;
        unless ( Netdot::Mojo::Permissions->can( $p, 'edit', $o ) ) {
            _err( 403, 'User not allowed to edit this object' );
        }
        my $name = _trim( $args->{name} // '' );
        _err( 400, 'Missing alias name' ) unless length $name;
        my $ttl  = _trim( $args->{ttl}  // '' );
        my $rec  = _create_alias( $o, $name, $ttl, $p );
        return $c->render( json => Netdot::Mojo::Api::get( $rec, $p, undef, depth => 0 ),
                           status => 200 );
    });
}

# POST /api/ipblock/:id/range  {start, end, status, owner?, used_by?, description?}
# Create a range of /32 or /128 IP blocks under the parent subnet.
sub range {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $id   = $c->param('id');
        my $args = _args($c);
        _err( 400, 'Missing id' ) unless defined $id && $id =~ /^\d+$/;
        my $o = Netdot::Model::Ipblock->retrieve($id);
        _err( 404, "Ipblock/$id not found" ) unless $o;
        unless ( Netdot::Mojo::Permissions->can( $p, 'edit', $o ) ) {
            _err( 403, 'User not allowed to edit this object' );
        }
        my $start = _trim( $args->{start} // '' );
        my $end   = _trim( $args->{end}   // '' );
        my $status = _trim( $args->{status} // '' );
        _err( 400, 'Missing start, end and/or status' ) unless $start && $end && $status;
        my %params = ( start => $start, end => $end, status => $status );
        $params{owner}       = $args->{owner}       if $args->{owner} && $args->{owner} ne '';
        $params{used_by}     = $args->{used_by}     if $args->{used_by} && $args->{used_by} ne '';
        $params{description} = $args->{description} if $args->{description} && $args->{description} ne '';
        $params{gen_dns}     = $args->{gen_dns}     if $args->{gen_dns};
        $params{name_prefix} = $args->{name_prefix} if $args->{name_prefix} && $args->{name_prefix} ne '';
        $params{name_suffix} = $args->{name_suffix} if $args->{name_suffix} && $args->{name_suffix} ne '';
        $params{fzone}       = $args->{fzone}       if $args->{fzone} && $args->{fzone} ne '';
        my $newips = eval { $o->add_range(%params) };
        _err( 400, "Range creation failed: $@" ) if $@;
        return $c->render( json => {
            created => scalar(@$newips),
            start   => $start,
            end     => $end,
            status  => $status,
        }, status => 201 );
    });
}

# POST /api/ipblock/batch
# Batch edit of a block's children (the Children list "Edit" mode): several
# field updates and several deletes applied in ONE request, so the client
# acts on a single consistent outcome (one status box, one reload) instead of
# firing N parallel per-row calls that can half-apply.
#   Body:  { "updates": [ { "id": 123, "status"?, "owner"?, "used_by"?,
#                            "description"? }, ... ],
#            "deletes": [ 456, 789 ] }
#   ->    { "updated": [123], "deleted": [456, 789],
#           "errors":  { "789": "not allowed" } }     # per-id, when any
# Only the fields a caller actually sends are written (the client sends only
# the dirty cells), so each audit-trail row reflects a real user change:
# CDBI's after_update trigger records only columns whose value changed.
sub batch {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $args    = _args($c);
        my $updates = $args->{updates} // [];
        my $deletes = $args->{deletes} // [];
        _err( 400, 'Bad request: "updates" (array of {id, fields...}) and/or "deletes" (array of ids) expected' )
            unless ref $updates eq 'ARRAY' || ref $deletes eq 'ARRAY';
        if ( defined $updates && ref $updates ne 'ARRAY' ) {
            _err( 400, '"updates" must be an array' );
        }
        elsif (
            grep { ref $_ ne 'HASH' || !defined $_->{id} || $_->{id} !~ /^\d+$/ } @$updates
          )
        {
            _err( 400, '"updates" entries must be objects with a numeric "id"' );
        }
        if ( defined $deletes && ref $deletes ne 'ARRAY' ) {
            _err( 400, '"deletes" must be an array' );
        }
        elsif ( grep { !defined || !/^\d+$/ } @$deletes ) {
            _err( 400, '"deletes" entries must be numeric ids' );
        }

        # The only fields the edit UI can change on a child (same set as the
        # model's recursive update, plus status).
        my @fields = qw(status owner used_by description);

        # Resolve + permission-check every target up front (same checks as
        # _post / _delete); a missing or denied id is reported per id and the
        # remaining operations still proceed, mirroring _batch_delete.
        my ( @uobjs, %dobjs, %errs );
        for my $u ( @$updates ) {
            my $id  = $u->{id};
            my $obj = Netdot::Model::Ipblock->retrieve($id);
            $errs{$id} = "Ipblock/$id not found" unless $obj;
            next unless $obj;
            $errs{$id} = 'User not allowed to edit this object'
                unless Netdot::Mojo::Permissions->can( $p, 'edit', $obj );
            next if $errs{$id};
            my %a;
            $a{$_} = $u->{$_} for grep { exists $u->{$_} } @fields;
            $errs{$id} = 'No editable field sent' unless keys %a;
            next if $errs{$id};
            push @uobjs, [ $obj, \%a ];
        }
        for my $did ( @$deletes ) {
            next if exists $dobjs{$did};
            my $obj = Netdot::Model::Ipblock->retrieve($did);
            $errs{$did} = "Ipblock/$did not found" unless $obj;
            next unless $obj;
            $errs{$did} = 'User not allowed to delete this object'
                unless Netdot::Mojo::Permissions->can( $p, 'delete', $obj );
            next if $errs{$did};
            $dobjs{$did} = $obj;
        }

        # Deletes first: an id present in both lists gets a clean "not found"
        # on its update instead of an ambiguous double operation.
        my ( @deleted, @updated );
        for my $did ( sort keys %dobjs ) {
            push @deleted, $did if eval { $dobjs{$did}->delete };
            $errs{$did} = "delete failed: $@" if $@;
        }
        for my $pair ( @uobjs ) {
            my ( $obj, $a ) = @$pair;
            push @updated, $obj->id if eval { $obj->update($a) };
            $errs{ $obj->id } = "update failed: $@" if $@;
        }

        my %res = ( updated => \@updated, deleted => \@deleted );
        $res{errors} = \%errs if keys %errs;
        return $c->render( json => \%res, status => ( @updated || @deleted ) ? 200 : 400 );
    });
}

# POST /api/:table/batch
# Generic bulk edit of a list / search selection (port of the legacy
# edit-multiple.html, driven by the JSON API): the client picks which fields to
# change and posts, per selected object, the values to write.
#   Body:  { "updates": [ { "id": 123, "info": "x", "active": 1 },
#                           { "id": 456, "info": "y" }, ... ] }
#   ->    { "updated": [123,456], "errors": { "789": "not allowed" } }
# Each id is resolved + permission-checked on its own (a denied id is reported
# per id, the rest proceed), mirroring _batch_delete and the ipblock batch. Only
# the fields the client actually sends are written, and only if they are a real
# editable column of the table (the same set the edit form offers, via
# Detail::editable_field_specs) — so the audit trail reflects a real user change
# (CDBI's after_update trigger records only columns whose value changed).
sub batch_edit {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';

        my %tables = _model_tables();
        my $class  = $tables{ lc( $c->param('table') ) };
        unless ($class) {
            return $c->render( json => { error => 'Unknown table: ' . $c->param('table') }, status => 400 );
        }

        my $args    = _args($c);
        my $updates = $args->{updates} // [];
        _err( 400, 'Bad request: "updates" (array of {id, fields...}) expected' )
            unless ref $updates eq 'ARRAY';
        if ( grep { ref $_ ne 'HASH' || !defined $_->{id} || $_->{id} !~ /^\d+$/ } @$updates ) {
            _err( 400, '"updates" entries must be objects with a numeric "id"' );
        }

        # The editable columns of the target table (single source of truth, shared
        # with the UI field picker); any other field is dropped, so a client can
        # never write to a non-editable / internal column (id, timestamps, ...).
        my %editable = map { $_->{name} => 1 } @{ Netdot::Mojo::Detail::editable_field_specs( $class ) };

        my ( @uobjs, %errs );
        for my $u ( @$updates ) {
            my $id  = $u->{id};
            my $obj = $class->retrieve($id);
            $errs{$id} = "$class/$id not found" unless $obj;
            next unless $obj;
            $errs{$id} = 'User not allowed to edit this object'
                unless Netdot::Mojo::Permissions->can( $p, 'edit', $obj );
            next if $errs{$id};
            my %a;
            $a{$_} = $u->{$_} for grep { exists $u->{$_} && $editable{$_} } keys %$u;
            $errs{$id} = 'No editable field sent' unless keys %a;
            next if $errs{$id};
            push @uobjs, [ $obj, \%a ];
        }

        my @updated;
        for my $pair ( @uobjs ) {
            my ( $obj, $a ) = @$pair;
            push @updated, $obj->id if eval { $obj->update($a) };
            $errs{ $obj->id } = "update failed: $@" if $@;
        }

        my %res = ( updated => \@updated );
        $res{errors} = \%errs if keys %errs;
        return $c->render( json => \%res, status => @updated ? 200 : 400 );
    });
}

sub _trim {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

# ---------------------------------------------------------------------------
# devinfo
# ---------------------------------------------------------------------------

sub devinfo {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'GET';
        my %eargs;
        $eargs{site} = $c->param('site') if defined $c->param('site') && $c->param('site') ne '';
        my $info = Netdot::Exporter->get_device_info(%eargs);
        $c->render( json => { device => $info }, status => 200 );
    });
}

# ---------------------------------------------------------------------------
# ipattr
# ---------------------------------------------------------------------------

sub ipattr {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'GET';
        my $addr = $c->param('addr');
        _err( 400, 'Missing addr' ) unless defined $addr && $addr ne '';
        my $ip = Ipblock->search( address => $addr )->first;
        _err( 404, 'IP not found' ) unless $ip;
        my $attrs = $ip->get_inherited_attributes();
        $c->render( json => $attrs, status => 200 );
    });
}

# ---------------------------------------------------------------------------
# host_contacts
# ---------------------------------------------------------------------------

sub host_contacts {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'GET';
        my $ip       = $c->param('ip');
        my $dns      = $c->param('dns');
        my $contacts = $c->param('contacts');
        my %res;

        if ($ip) {
            my $ipb = Ipblock->search( address => $ip )->first;
            _err( 404, "$ip not found" ) unless $ipb;
            unless ( Netdot::Mojo::Permissions->can( $p, 'view', $ipb ) ) {
                _err( 403, 'User not allowed to view this IP' );
            }
            $res{address} = $ipb->address;

            if ($dns) {
                for my $ar ( _list( $ipb->a_records ) ) {
                    my $rr   = $ar->rr;
                    my $fqdn = $rr->get_label;
                    if ( my @txt = _list( $rr->txt_records ) ) {
                        push @{ $res{name}{$fqdn}{txt} }, map { $_->txtdata } @txt;
                    }
                    if ( my $hinfo = _first( $rr->hinfo_records ) ) {
                        $res{name}{$fqdn}{hinfo}{cpu} = $hinfo->cpu;
                        $res{name}{$fqdn}{hinfo}{os}  = $hinfo->os;
                    }
                    my $cn_it  = eval { RRCNAME->search( cname => $fqdn ) };
                    my @cnames = _list($cn_it);
                    push @{ $res{name}{$fqdn}{cname} }, map { $_->rr->get_label } @cnames;
                    $res{name}{$fqdn}{info} = $rr->info;
                }
                if ( my $dhcp = _first( $ipb->dhcp_scopes ) ) {
                    $res{ether}     = $dhcp->physaddr->address;
                    $res{ethertype} = $dhcp->physaddr->vendor;
                }
            }

            if ($contacts) {
                my %clists;
                if ( my $subnet = $ipb->parent ) {
                    $res{subnet} = $subnet->get_label;
                    if ( $subnet->used_by && ( my $cl = $subnet->used_by->contactlist ) ) {
                        $clists{ $cl->id } = $cl;
                    }
                    for my $ss ( _list( $subnet->sites ) ) {
                        my $site = $ss->site;
                        if ( my $scl = $site->contactlist ) { $clists{ $scl->id } = $scl }
                        for my $ents ( _list( $site->entities ) ) {
                            my $e = $ents->entity;
                            for my $key (qw(name aliases)) { $res{entities}{ $e->id }{$key} = $e->$key }
                            $res{entities}{ $e->id }{availability} = $e->availability->name if $e->availability;
                            if ( my $ecl = $e->contactlist ) { $clists{ $ecl->id } = $ecl }
                        }
                    }
                    for my $cl ( values %clists ) {
                        $res{contact_list}{ $cl->id }{name} = $cl->name;
                        for my $con ( _list( $cl->contacts ) ) {
                            my $person = $con->person;
                            for my $key (qw(lastname firstname aliases position email office cell home pager)) {
                                $res{contact_list}{ $cl->id }{contacts}{ $con->id }{$key} = $person->$key;
                            }
                            $res{contact_list}{ $cl->id }{contacts}{ $con->id }{type}     = $con->contacttype->name;
                            $res{contact_list}{ $cl->id }{contacts}{ $con->id }{employer} = $person->entity->name if $person->entity;
                        }
                    }
                }
            }
        }

        $c->render( json => ( %res ? \%res : {} ), status => 200 );
    });
}

# ---------------------------------------------------------------------------
# host / host_like
# ---------------------------------------------------------------------------

sub host      { my ( $c ) = @_; _host( $c, 0 ); }
sub host_like { my ( $c ) = @_; _host( $c, 1 ); }

# Shared host manipulation. $like selects fuzzy name search for the "name"
# criterion (host_like) vs exact (host).
sub _host {
    my ( $c, $like ) = @_;
    my $p = _person($c) or return;
    my $method = $c->req->method;
    my %A = %{ _args($c) };

    return _run( $c, sub {
        if ( $method eq 'GET' ) {
            my ( $rrs, $ips ) = _host_collect( \%A, $p, $like );
            my %ret;
            for my $rr ( values %$rrs ) { push @{ $ret{RR} }, Netdot::Mojo::Api::get( $rr, $p, undef, depth => 0 ) }
            for my $ip ( values %$ips ) { push @{ $ret{Ipblock} }, Netdot::Mojo::Api::get( $ip, $p, undef, depth => 0 ) }
            $c->render( json => \%ret, status => 200 );
        }
        elsif ( $method eq 'POST' ) {
            _host_post( \%A, $p, $c );
        }
        elsif ( $method eq 'DELETE' ) {
            _host_delete( \%A, $p );
            $c->render( json => { deleted => 1 }, status => 200 );
        }
        else {
            _err( 405, "Method $method not allowed" );
        }
    });
}

# Gather the %rrs / %ips sets for a host GET from the given criteria.
sub _host_collect {
    my ( $A, $p, $like ) = @_;
    my %rrs;
    my %ips;

    if ( $A->{rrid} ) {
        my $rr = RR->retrieve( $A->{rrid} );
        _err( 404, 'RR not found' ) unless $rr;
        $rrs{ $rr->id } = $rr;
    }
    elsif ( $A->{ipid} ) {
        my $ipb = Ipblock->retrieve( $A->{ipid} );
        _err( 404, 'IP not found' ) unless $ipb;
        $ips{ $ipb->id } = $ipb;
    }
    elsif ( $A->{name} ) {
        my $name_it = $like ? RR->search_like( name => $A->{name} )
                            : RR->search( name => $A->{name} );
        my @list = _list($name_it);
        _err( 404, 'Name not found' ) unless @list;
        $rrs{ $_->id } = $_ for @list;
    }
    elsif ( $A->{address} ) {
        my $ipb;
        if ( Ipblock->matches_v4( $A->{address} ) ) {
            $ipb = Ipblock->search( address => $A->{address}, version => 4, prefix => 32 )->first;
        }
        elsif ( Ipblock->matches_v6( $A->{address} ) ) {
            $ipb = Ipblock->search( address => $A->{address}, version => 6, prefix => 128 )->first;
        }
        else {
            _err( 400, 'Bad request: invalid address' );
        }
        if ($ipb) { $ips{ $ipb->id } = $ipb } else { _err( 404, 'Address not found' ) }
    }
    elsif ( $A->{ethernet} ) {
        if ( my $phy = PhysAddr->search( address => $A->{ethernet} )->first ) {
            for my $host ( _list( $phy->dhcp_hosts ) ) {
                my $ip = $host->ipblock;
                $ips{ $ip->id } = $ip if $ip;
            }
        }
        else { _err( 404, 'MAC not found' ) }
    }
    elsif ( $A->{duid} ) {
        if ( my $host = DhcpScope->search( duid => $A->{duid} )->first ) {
            my $ip = $host->ipblock;
            $ips{ $ip->id } = $ip if $ip;
        }
    }
    elsif ( $A->{zone} ) {
        my $zoneobj = Zone->objectify( $A->{zone} ) or _err( 400, 'Bad request: invalid zone' );
        _err( 403, 'User not allowed to view this zone' )
            unless Netdot::Mojo::Permissions->can( $p, 'view', $zoneobj );
        $rrs{ $_->id } = $_ for _list( $zoneobj->records );
    }
    elsif ( $A->{subnet} ) {
        my $subnetobj = Ipblock->objectify( $A->{subnet} ) or _err( 400, 'Bad request: invalid subnet' );
        _err( 403, 'User not allowed to view this subnet' )
            unless Netdot::Mojo::Permissions->can( $p, 'view', $subnetobj );
        $ips{ $_->id } = $_ for _list( $subnetobj->children );
    }
    else {
        unless ( Netdot::Mojo::Permissions->can( $p, 'access_section', 'rest/host:get_all' ) ) {
            _err( 403, 'User not allowed to view all records' );
        }
        my $all_it = RR->retrieve_all;
        my @allrrs = _list($all_it);
        _err( 404, 'No records' ) unless @allrrs;
        $rrs{ $_->id } = $_ for @allrrs;
    }

    # Expand to related IPs and names.
    for my $rr ( values %rrs ) {
        for my $ar ( _list( $rr->a_records ) ) {
            my $ip = $ar->ipblock;
            $ips{ $ip->id } = $ip if $ip;
        }
    }
    for my $ipb ( values %ips ) {
        for my $ar ( _list( $ipb->a_records ) ) {
            my $rr = $ar->rr;
            $rrs{ $rr->id } = $rr if $rr;
        }
        for my $ptr ( _list( $ipb->ptr_records ) ) {
            my $rr = $ptr->rr;
            $rrs{ $rr->id } = $rr if $rr;
        }
    }

    return ( \%rrs, \%ips );
}

# host POST: update (rrid / ipid) or add a new host.
sub _host_post {
    my ( $A, $p, $c ) = @_;
    my $user_type = Netdot::Mojo::Permissions->user_type($p);

    if ( $A->{rrid} ) {
        my $rr = RR->retrieve( $A->{rrid} );
        _err( 404, 'RR not found' ) unless $rr;
        _err( 403, 'User not allowed to edit this object' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $rr );
        my %args;
        $args{$_} = $A->{$_} for grep { defined $A->{$_} } qw(name expiration info);
        if ( $args{name} && $user_type ne 'Admin' ) {
            eval { RR->validate_name( $args{name} ) };
            _err( 400, "Bad request: $@" ) if $@;
        }
        eval { $rr->update(\%args) };
        _err( 400, "Bad request: $@" ) if $@;
        $c->render( json => Netdot::Mojo::Api::get( $rr, $p, undef, depth => 0 ), status => 200 );
    }
    elsif ( $A->{ipid} ) {
        my $ipb = Ipblock->retrieve( $A->{ipid} );
        _err( 404, 'IP not found' ) unless $ipb;
        _err( 403, 'User not allowed to edit this object' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $ipb );
        _err( 403, 'User not allowed to edit this object' ) unless $ipb->status->name eq 'Static';
        if ( $A->{ethernet} || $A->{duid} ) {
            my %args;
            $args{duid} = $A->{duid} if $A->{duid};
            $args{physaddr} = $A->{ethernet} if ( $A->{ethernet} && !$args{duid} );
            if ( my $host = _first( $ipb->dhcp_scopes ) ) {
                eval { $host->update(\%args) };
                _err( 400, "Bad request: $@" ) if $@;
            }
            else {
                eval { DhcpScope->insert({ type => 'host', ipblock => $ipb, %args }) };
                _err( 400, "Bad request: $@" ) if $@;
            }
        }
        $c->render( json => Netdot::Mojo::Api::get( $ipb, $p, undef, depth => 0 ), status => 200 );
    }
    else {
        # add a new host
        my %add_args;
        if ( $A->{name} && $user_type ne 'Admin' ) {
            eval { RR->validate_name( $A->{name} ) };
            _err( 400, "Bad request: $@" ) if $@;
        }
        $add_args{name} = $A->{name};
        $add_args{$_} = $A->{$_} for grep { defined $A->{$_} } qw(subnet expiration aliases cpu os info);
        $add_args{duid}     = $A->{duid} if $A->{duid};
        $add_args{ethernet} = $A->{ethernet} if ( $A->{ethernet} && !$add_args{duid} );

        # If the requested address already exists, "add a host" means adding a
        # new hostname (a new RRADDR) to that IP -- no new IP is allocated.
        # Allowed iff the target zone AND the specific IP are both editable.
        my $existing_ipb;
        if ( defined $A->{address} && $A->{address} ne '' ) {
            my $ver = Ipblock->matches_v4( $A->{address} ) ? 4
                    : Ipblock->matches_v6( $A->{address} ) ? 6 : 0;
            _err( 400, 'Bad request: invalid address' ) unless $ver;
            $existing_ipb = Ipblock->search(
                address => $A->{address}, version => $ver,
                prefix  => $ver == 6 ? 128 : 32,
            )->first;
        }

        if ( $existing_ipb ) {
            my $zoneobj;
            if ( defined $A->{zone} && $A->{zone} ne '' ) {
                $zoneobj = Zone->objectify( $A->{zone} ) or _err( 400, 'Bad request: invalid zone' );
            }
            else {
                $zoneobj = _first( Zone->search( name => $A->{name} ) );
            }
            _err( 400, 'Could not determine a zone' ) unless $zoneobj;
            _err( 403, 'User not allowed to edit this zone' )
                unless Netdot::Mojo::Permissions->can( $p, 'edit', $zoneobj );
            _err( 403, 'User not allowed to edit this IP' )
                unless Netdot::Mojo::Permissions->can( $p, 'edit', $existing_ipb );

            my $zname = $zoneobj->name;
            my $short = $add_args{name};
            $short =~ s/\.$zname$// if defined $short;
            my $rraddr = eval {
                RR->insert( {
                    type       => $existing_ipb->version == 6 ? 'AAAA' : 'A',
                    ipblock    => $existing_ipb,
                    name       => $short,
                    zone       => $zoneobj,
                    expiration => $add_args{expiration},
                    info       => $add_args{info},
                    update_ptr => 1,
                } );
            };
            _err( 400, "Bad request: $@" ) if $@;
            return $c->render( json => Netdot::Mojo::Api::get( $rraddr->rr, $p, undef, depth => 0 ), status => 200 );
        }

        my $subnet = $A->{subnet};
        unless ($subnet) {
            if ( $A->{address} ) {
                $subnet = Ipblock->get_covering_block( address => $A->{address} );
            }
            else { _err( 400, 'Bad request: Need to pass either a subnet or IP address' ) }
        }
        my $subnetobj = Ipblock->objectify($subnet) or _err( 400, 'Bad request: invalid subnet' );
        _err( 403, 'User not allowed to edit this subnet' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $subnetobj );

        my $zoneobj = $subnetobj->forward_zone();
        unless ($zoneobj) {
            my $dfzname = Netdot->config->get('DEFAULT_DNSDOMAIN');
            $zoneobj = _first( Zone->search( name => $dfzname ) );
        }
        my $zone_from_name = _first( Zone->search( name => $A->{name} ) );
        my $given_zone_name = $A->{zone} || $zone_from_name;
        if ($given_zone_name) {
            my $given_zone = Zone->objectify($given_zone_name) or _err( 400, 'Bad request: invalid zone given' );
            if ( !$zoneobj || ( $zoneobj->id != $given_zone->id ) ) {
                if ( Netdot::Mojo::Permissions->can( $p, 'edit', $given_zone ) ) {
                    $zoneobj = $given_zone;
                }
                else { _err( 403, 'User not allowed to edit this zone' ) }
            }
        }
        _err( 400, 'Could not determine a zone' ) unless $zoneobj;

        my $zname = $zoneobj->name;
        $add_args{name} =~ s/\.$zname$// if defined $add_args{name};
        $add_args{zone} = $zoneobj;

        if ( $A->{address} ) {
            if ( Netdot::Mojo::Permissions->can( $p, 'choose_ip', $subnetobj ) ) {
                $add_args{address} = $A->{address};
            }
            else { _err( 403, 'User not allowed to choose an address' ) }
        }
        my $rr = eval { RR->add_host(%add_args) };
        _err( 400, "Bad request: $@" ) if $@;
        $c->render( json => Netdot::Mojo::Api::get( $rr, $p, undef, depth => 0 ), status => 200 );
    }
}

# host DELETE: remove an RR (rrid), a host IP (ipid), or a DHCP host (ethernet).
sub _host_delete {
    my ( $A, $p ) = @_;
    my @to_delete;

    if ( $A->{rrid} ) {
        my $rr = RR->retrieve( $A->{rrid} );
        _err( 404, 'RR not found' ) unless $rr;
        push @to_delete, $rr;
    }
    elsif ( $A->{ipid} ) {
        my $ipb = Ipblock->retrieve( $A->{ipid} );
        _err( 404, 'IP not found' ) unless $ipb;
        _err( 400, 'Bad request: Cannot operate on blocks of addresses' ) unless $ipb->is_address;
        push @to_delete, map { $_->rr } _list( $ipb->a_records );
        push @to_delete, map { $_->rr } _list( $ipb->ptr_records );
        push @to_delete, _list( $ipb->dhcp_scopes );
    }
    elsif ( $A->{ethernet} ) {
        my $phy = PhysAddr->search( address => $A->{ethernet} )->first;
        _err( 404, 'MAC not found' ) unless $phy;
        push @to_delete, _list( $phy->dhcp_hosts );
    }

    return unless @to_delete;

    eval {
        Netdot::Model->do_transaction( sub {
            for my $obj (@to_delete) {
                next if ref($obj) eq 'Class::DBI::Object::Has::Been::Deleted';
                unless ( Netdot::Mojo::Permissions->can( $p, 'delete', $obj ) ) {
                    _err( 403, 'User not allowed to delete this object' );
                }
                $obj->delete();
            }
        });
    };
    _err( 400, "Bad request: $@" ) if $@;
}

# ---------------------------------------------------------------------------
# updatedev
# ---------------------------------------------------------------------------

sub updatedev {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my %A = %{ _args($c) };
        my $name = $A{name};
        _err( 400, 'Missing name' ) unless defined $name && $name ne '';
        my $info = ref $A{info} eq 'HASH' ? $A{info} : $A{info};
        my $obj  = eval {
            Netdot::Model->do_transaction( sub { Device->discover( name => $name, info => $info ) } );
        };
        _err( 400, "Bad request: $@" ) if $@;
        $c->render( json => Netdot::Mojo::Api::get( $obj, $p, undef, depth => 0 ), status => 200 );
    });
}

# Add a device manually (port of the legacy device_tasks.html "Add Device
# manually"): one input (name or IP) -> Device->manual_add(host=>...). The lib
# resolves the host via DNS, creates the device (monitored=1, snmp_managed=0)
# with an interface, its /32 (or /128) block (Static, monitored) and the
# snmp_target, plus an ARP-based neighbor if one is known. Admin-only, as in
# Mason (access_admin_section).
sub manual_add {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        _err( 403, 'Adding devices manually is reserved for administrators' )
            unless Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin';
        my %A    = %{ _args($c) };
        my $host = $A{host} // '';
        $host =~ s/\s//g;
        _err( 400, 'Missing required parameter: host' ) unless length $host;
        my $dev = eval { Device->manual_add( host => $host ) };
        _err( 400, "manual_add failed: $@" ) if $@ || !$dev;
        $c->render( json => { id => $dev->id }, status => 200 );
    });
}

# ---------------------------------------------------------------------------
# OpenAPI spec + Swagger UI
# ---------------------------------------------------------------------------

# Serve the OpenAPI 3 spec (YAML) at /api/openapi.yaml. Uses the generated
# file (api/gen_openapi.pl) when present; otherwise builds it on the fly from
# the model's meta (Netdot::Mojo::OpenAPI::build_spec).
sub spec {
    my ($c) = @_;
    my $base = Netdot->config->get('NETDOT_PATH');
    my $file = $base ? "$base/api/openapi.yaml" : undef;
    my $yaml;
    if ( $file && -f $file ) {
        $yaml = Mojo::File->new($file)->slurp;
    }
    else {
        $yaml = eval { YAML::XS::Dump( Netdot::Mojo::OpenAPI::build_spec() ) };
        return $c->render( json => { error => "Could not build OpenAPI spec: $@" }, status => 500 ) if $@;
    }
    $c->render( data => $yaml, status => 200 );
    $c->res->headers->content_type( 'application/yaml; charset=utf-8' );
}

# Swagger UI page at /api/docs (loads /api/openapi.yaml via the Swagger UI CDN).
# Standalone (no Netdot layout) so it works at the root or behind a sub-path
# proxy without pulling in site CSS/nav that assume a root deployment.
sub docs {
    my ($c) = @_;
    $c->render( template => 'api_docs', layout => undef );
}

# ---------------------------------------------------------------------------
# list helpers (CDBI iterators -> arrays / first)
# ---------------------------------------------------------------------------

# Accept any of: a CDBI iterator (relation/search called in scalar context),
# an arrayref, or a flat list (relation called in list context, which is what
# happens when it is passed directly as a function argument). Returns a flat
# list of objects. NB: we must take all of @_, not just shift(1) -- a
# list-context relation already arrives as a full list and shift would drop
# every element after the first.
sub _list {
    my @in = @_;
    # Single iterator argument: drain it fully.
    if ( @in == 1 && ref $in[0] && eval { $in[0]->can('next') } ) {
        my @out;
        while ( my $o = $in[0]->next ) { push @out, $o }
        return @out;
    }
    # Single arrayref argument: dereference.
    if ( @in == 1 && ref $in[0] eq 'ARRAY' ) {
        return @{ $in[0] };
    }
    # Otherwise it already arrived as a flat list (possibly empty): as-is.
    return @in;
}

# Same accepted forms as _list; returns the first object (or undef).
sub _first {
    my @in = @_;
    return undef unless @in;
    my $it = $in[0];
    if ( @in == 1 && ref $it && eval { $it->can('first') } ) {
        return $it->first;
    }
    return ( @in == 1 && ref $it eq 'ARRAY' ) ? $it->[0] : $it;
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