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
use Log::Log4perl;
use Netdot::Util::Log;

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
#   POST   /api/device             create a device (discover: true = SNMP
#                                  discovery, false/absent = manual add)
#   POST   /api/device/:id/update  SNMP update (re-poll) of an existing device

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
    # JSON booleans decode to blessed scalar objects (JSON::PP::Boolean).
    # The legacy models assume a blessed value is a Netdot object — e.g.
    # _audit() calls ->get_label() on any blessed field value (and the
    # _adjust_vals "" handling skips blessed values) — so normalize them to
    # plain 0/1 here, at the JSON boundary. This keeps the models fed plain
    # scalars, exactly like the non-API callers (SNMP poller, wizards).
    for my $k ( keys %a ) {
        my $r = ref $a{$k};
        $a{$k} = 0 + $a{$k} if $r && $r ne 'HASH' && $r ne 'ARRAY';
        next unless ref $a{$k} eq 'ARRAY';
        for my $item ( @{ $a{$k} } ) {
            my $ir = ref $item;
            $item = 0 + $item if $ir && $ir ne 'HASH' && $ir ne 'ARRAY';
        }
    }
    return \%a;
}

# Truthy test for client-supplied flags: JSON boolean true or "1"/"true"/
# "yes"/"on" (the form hidden inputs send the strings "false"/"0").
sub _is_true {
    my ($v) = @_;
    return 0 unless defined $v;
    return $v =~ /^(?:1|true|yes|on)$/i ? 1 : 0;
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

=encoding utf8

=head1 NAME

Netdot::Mojo::Controller::Api - JSON API controller (port of the legacy /rest handlers + Netdot::REST)

    All DB writes of the management UI go through these actions. Permission
    checks (Netdot::Mojo::Permissions) and argument shape validation are done
    here; the write semantics themselves live in the model overloads.

=head1 SYNOPSIS

    # Wired in Netdot::Mojo (specific endpoints first, then the generic
    # resource router):
    #   ->any('/api')->to('api#root')
    #   ->get('/api/openapi.yaml')->to('api#spec')
    #   ->get('/api/docs')->to('api#docs')
    #   ->get('/api/prometheus')->to('api#prometheus')
    #   ->post('/api/:table/batch')->to('api#batch_edit')
    #   ->post('/api/device')->to('api#create_device')
    #   ->any('/api/:table')->to('api#generic')
    #   ->any('/api/:table/:id')->to('api#generic')

=head1 INSTANCE METHODS

=cut

# A machine-readable landing point, Netbox-style: a flat {resource: absolute-url}
# map. Every model table plus the purpose-built endpoints and the docs/spec.
# GET only (else 405 JSON).
=head2 root - API index

Arguments:  Controller (GET /api)
Returns:    A machine-readable landing point, Netbox-style: a flat
            {resource: absolute-url} map of every model table plus the
            purpose-built endpoints and the docs/spec
Description: GET only (else 405 JSON).

=cut

sub root {
    my ($c) = @_;
    my $p = _person($c) or return;
    return $c->render( json => { error => 'Method not allowed', path => $c->web_prefix . '/api' }, status => 405 )
        unless $c->req->method eq 'GET';

    my $base = _base_url($c);
    my $url  = sub { $base . $_[0] };

    my %index;
    my %tables = _model_tables();
    $index{$_} = $url->("/api/$_") for sort keys %tables;

    # Purpose-built endpoints (same flat name -> url style).
    for my $ep (qw(devinfo host_contacts host host_like ipattr prometheus)) {
        $index{$ep} = $url->("/api/$ep");
    }
    $index{docs}           = $url->('/api/docs');
    $index{'openapi.yaml'} = $url->('/api/openapi.yaml');

    $c->render( json => \%index, status => 200 );
}

# ---------------------------------------------------------------------------
# generic resource router
# ---------------------------------------------------------------------------

=head2 generic - Generic resource router

Arguments:  Controller (stash: table; params: id plus merged query/JSON
            args)
Returns:    JSON per operation:
            - GET /api/<table>          paginated list (count/next/previous/
              results); ?kw=<kw>&limit=N returns lightweight {id,label} FK
              search results (the edit-mode FK picker; big tables are
              searched, never dumped)
            - GET /api/<table>/meta_data the model meta
            - GET /api/<table>/<id>     the object (depth/linked_from
              options); 403 when the user may not view it
            - POST|PATCH|PUT .../<id>   create or update (FK fields as ids)
            - DELETE .../<id>           delete; ?id=1,2,3 batch delete
              ({deleted: [...], skipped: {id: reason}}, each id
              permission-checked on its own)
Description: Port of the legacy /rest handlers. Permission checks and
            shape validation live here (_can_create: per-parent FK gating
            for Interface/RR/Contact, admin-only classes); the write
            semantics live in the model's insert/update overloads.

=cut

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
=head2 alias - Create a new alias (CNAME) for a DNS record

Arguments:  Controller (POST /api/rr/<id>/alias, body: {name, ttl?})
Returns:    The created CNAME record (200); 400/403/404 otherwise
Description: Port of the legacy host alias form: creates a new RR (the
            alias name) plus a CNAME pointing at the target. The zone for
            the new name is resolved from the entered name: a short name
            stays in the target's zone; a name whose domain part matches a
            zone the user can edit is mapped to that zone; any other long
            name is placed in the target's zone as a label. Conflicts (the
            name already has records) are handled by RRCNAME->insert.

=cut

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
=head2 range - Create a range of IP blocks under a subnet

Arguments:  Controller (POST /api/ipblock/<id>/range, body: {start, end,
            status, owner?, used_by?, description?, gen_dns?, name_prefix?,
            name_suffix?, fzone?})
Returns:    {created, start, end, status} (201)
Description: Creates /32 (v4) or /128 (v6) blocks for the address range
            under the parent subnet, with the optional DNS generation
            (forward zone, name prefix/suffix). The model's add_range does
            the work; 'edit' on the subnet is required.

=cut

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
=head2 batch - Batch edit of an Ipblock's children

Arguments:  Controller (POST /api/ipblock/batch, body: {updates: [{id,
            status?, owner?, used_by?, description?}, ...], deletes:
            [id, ...]})
Returns:    {updated: [...], deleted: [...], errors: {id: reason}}
Description: Several field updates and several deletes applied in ONE
            request (the Children list "Edit" mode), so the client acts on
            a single consistent outcome instead of firing N parallel
            per-row calls that can half-apply. Each id is resolved and
            permission-checked on its own; only the sent fields are
            written, so each audit-trail row reflects a real user change
            (CDBI's after_update records only changed columns).

=cut

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
=head2 batch_edit - Generic bulk edit of a list/search selection

Arguments:  Controller (POST /api/<table>/batch, body: {updates: [{id,
            <field>: value}, ...]})
Returns:    {updated: [...], errors: {id: reason}}
Description: Port of the legacy edit-multiple.html: each id is resolved
            and permission-checked on its own (a denied id is reported, the
            rest is applied); the fields are validated against
            Detail::editable_field_specs (the single source of truth shared
            with the bulk-edit UI), so the audit trail reflects a real user
            change.

=cut

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

=head2 devinfo - Device information (exporter)

Arguments:  Controller (GET /api/devinfo, param: site, optional)
Returns:    {device: ...} from Netdot::Exporter->get_device_info (200)

=cut

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
# prometheus — Prometheus file-SD inventory (port of prometheus-inventory.php)
# ---------------------------------------------------------------------------

# All MONITORED devices, grouped by (type, manufacturer, site, env), in the
# Prometheus file-based service-discovery shape: an array of groups
# {labels => {__meta_netdot_…}, targets => ["name.zone", …]}. Port of the
# legacy prometheus-inventory.php, built on the OBJECT MODEL
# (Device->search + FK accessors — no raw SQL). Differences vs the PHP
# script (intentional):
#   - env = the device's `used_by` (Entity) `short_name`, not the constant
#     "CI" (JSON null when the device has no used_by);
#   - env is part of the group key, because 27 of the 172 (type,
#     manufacturer, site) groups mix several used_by values and a group's
#     labels must stay consistent (Prometheus requirement).
=head2 prometheus - Prometheus file-based service-discovery inventory

Arguments:  Controller (GET /api/prometheus, no params)
Returns:    An array of groups {labels => {__meta_netdot_type,
            __meta_netdot_manufacturer, __meta_netdot_site,
            __meta_netdot_env}, targets => ["name.zone", ...]} (200, with a
            no-cache header)
Description: Port of the legacy prometheus-inventory.php, built on the
            OBJECT MODEL (Device->search + FK accessors — no raw SQL). All
            MONITORED devices, grouped by (type, manufacturer, site, env);
            env = the device's used_by (Entity) short_name (JSON null when
            the device has no used_by) and is part of the group key,
            because a group's labels must stay consistent (Prometheus
            requirement). Devices missing any link of the rr/zone/site/
            asset/product/type/manufacturer chain are skipped (PHP
            inner-join parity). Gated on view rights on Device (403
            otherwise).

=cut

sub prometheus {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'GET';
        _err( 403, 'Insufficient privileges' )
            unless Netdot::Mojo::Permissions->has_action( 'Device', $p, 'view' );
        my @devices = Device->search( { monitored => 1 } );
        # Group by (type, manufacturer, site, env), keeping first-seen order,
        # like the keyed array of the PHP script.
        my ( %groups, @order );
        for my $d (@devices) {
            my $rr      = $d->name;
            my $zone    = $rr && $rr->zone;
            my $site    = $d->site;
            my $asset   = $d->asset_id;
            my $product = $asset && $asset->product_id;
            my $type    = $product && $product->type;
            my $mfr     = $product && $product->manufacturer;
            # Same selection as the PHP inner joins: skip devices missing any
            # link of the chain.
            next unless $rr && $zone && $site && $asset && $product && $type && $mfr;
            my $name     = $rr->name;
            my $zonename = $zone->name;
            my $siteno   = $site->number;
            my $typename = $type->name;
            my $mfrname  = lc( $mfr->name );   # as in the PHP LOWER(entity.name)
            my $env      = $d->used_by && $d->used_by->short_name;  # may be undef
            # Manufacturer transform (as in the PHP script): first
            # [A-Za-z0-9 ]+ run, trimmed, spaces -> _.
            my $mfrlabel = $mfrname;
            if ( my ($m) = $mfrname =~ /([A-Za-z0-9 ]+)/ ) {
                $mfrlabel = _trim($m);
                $mfrlabel =~ s/ /_/g;
            }
            my $key = join '-', ( $typename // '', $mfrlabel // '', $siteno // '', $env // '' );
            unless ( exists $groups{$key} ) {
                $groups{$key} = {
                    labels => {
                        __meta_netdot_type         => $typename,
                        __meta_netdot_manufacturer => $mfrlabel,
                        __meta_netdot_site         => $siteno,
                        __meta_netdot_env          => $env,
                    },
                    targets => [],
                };
                push @order, $key;
            }
            push @{ $groups{$key}{targets} }, "$name.$zonename";
        }
        $c->res->headers->header(
            'Cache-Control' => 'no-cache, must-revalidate, max-age=0'
        );
        $c->render( json => [ map { $groups{$_} } @order ], status => 200 );
    });
}

# ---------------------------------------------------------------------------
# ipattr
# ---------------------------------------------------------------------------

=head2 ipattr - IP attributes

Arguments:  Controller (GET /api/ipattr, param: addr)
Returns:    The Ipblock's inherited attributes
            (Ipblock->get_inherited_attributes) (200); 404 when the IP is
            unknown

=cut

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

=head2 host_contacts - DNS + contact information for an IP

Arguments:  Controller (GET /api/host_contacts, params: ip, dns, contacts)
Returns:    {address, name: {<fqdn>: {txt, hinfo, cname, info}}, ether,
            ethertype, subnet, entities, contact_list} (200); 403 when the
            user may not view the IP
Description: The IP's DNS data (the A records' TXT/HINFO/CNAME sub-records,
            the DHCP scope's ether/ethertype) and/or its contact lists (the
            parent subnet's used_by contact list + the sites' entities and
            their contact lists, with the contact details).

=cut

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

=head2 host - Host manipulation (exact name match)

Arguments:  Controller (GET /api/host: criteria name/ip/device/...;
            POST/PATCH/DELETE: create/update/delete of the matched RRs and
            IPs)
Returns:    GET: {RR: [...], Ipblock: [...]} (serialized objects); write
            ops: the JSON of the shared host handler
Description: Port of the legacy host manipulation (host.html): gathers the
            RRs and IPs matching the criteria and applies the requested
            operations on them. The "name" criterion is matched exactly.

=head2 host_like - Host manipulation (fuzzy name match)

Arguments:  (same as host)
Returns:    (same as host)
Description: Same as host, but the "name" criterion is a fuzzy search
            (LIKE) instead of an exact match.

=cut

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
# create_device — unified device creation (the two legacy
# device_tasks.html?view=new modes, admin-only, as in Mason):
#   {discover: false, host} -> Device->manual_add (DNS + monitored device +
#                              interface + /32 block + snmp_target)
#   {discover: true, name, snmp_version, community | v3 fields}
#                          -> SNMP discovery: Device->get_snmp_info with the
#                              supplied credentials, then Device->discover.
# The static /api/device route wins over the generic /api/:table, so the
# generic device insert is unreachable by design: device creation only goes
# through these two modes.
# Run Device->discover inside a transaction and capture the model log lines
# (Mason showed them on the wizard result page; the UI now renders them
# client-side from the API response, since all DB writes go through the API).
# Returns ( $dev, \@loglines, $err ).
sub _discover_captured {
    my (%argv) = @_;
    my $appender_name = 'nd_device_discover_api';
    if ( my $old = Log::Log4perl::appender_by_name($appender_name) ) {
        Log::Log4perl->eradicate_appender($appender_name);
    }
    my $logstr = Netdot::Util::Log->new_appender( 'String', name => $appender_name );
    for my $ln ( 'Netdot::Model::Device', 'Netdot::Model::DNS', 'Netdot::Model::Ipblock' ) {
        Log::Log4perl->get_logger($ln)->add_appender($logstr);
    }
    my $dev = eval { Netdot::Model->do_transaction( sub { Device->discover( %argv ) } ) };
    my $err = $@;
    Log::Log4perl->eradicate_appender($appender_name);
    my @loglines;
    if ( $logstr && $dev && ! $err ) {
        # Filter the log to lines mentioning the device (as in Mason).
        @loglines = grep { index( $_, $argv{name} ) >= 0 } split /\n/, $logstr->string;
    }
    return ( $dev, \@loglines, $err );
}

=head2 create_device - Create a device (manual add or SNMP discovery)

Arguments:  Controller (POST /api/device, body: {discover: false, host}
            for a manual add (Device->manual_add: DNS resolution + monitored
            device + interface + /32 or /128 block + snmp_target), or
            {discover: true, name, snmp_version, community | v3 fields} for
            an SNMP discovery (Device->get_snmp_info then Device->discover,
            run in a transaction with the model log captured for the UI))
Returns:    {device: <serialized device>, log: [model log lines]} (200)
Description: Admin-only. The static /api/device route wins over the
            generic /api/:table, so the generic device insert is
            unreachable by design: device creation only goes through these
            two modes.

=cut

sub create_device {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        _err( 403, 'Creating devices is reserved for administrators' )
            unless Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin';
        my %A = %{ _args($c) };

        if ( _is_true( $A{discover} ) ) {
            # ---- SNMP discovery ----
            my $name = $A{name} // '';
            $name =~ s/\s//g;
            _err( 400, 'Missing required parameter: name' ) unless length $name;
            my $ver = int( $A{snmp_version} // 2 );
            $ver = ( $ver == 1 || $ver == 3 ) ? $ver : 2;
            my %q = ( host => $name, version => $ver );
            if ( $ver == 3 ) {
                # Explicit credentials win; anything missing falls back to the
                # DEFAULT_SNMP_* config values (the same defaults the discovery
                # form pre-fills).
                my %def = (
                    sec_name   => Netdot::Model->config->get('DEFAULT_SNMP_SECNAME'),
                    sec_level  => Netdot::Model->config->get('DEFAULT_SNMP_SECLEVEL'),
                    auth_proto => Netdot::Model->config->get('DEFAULT_SNMP_AUTHPROTO'),
                    auth_pass  => Netdot::Model->config->get('DEFAULT_SNMP_AUTHPASS'),
                    priv_proto => Netdot::Model->config->get('DEFAULT_SNMP_PRIVPROTO'),
                    priv_pass  => Netdot::Model->config->get('DEFAULT_SNMP_PRIVPASS'),
                );
                for my $k ( keys %def ) {
                    my $v = $A{$k};
                    $v = $def{$k} unless defined $v && length $v;
                    $q{$k} = $v if defined $v && length $v;
                }
            }
            else {
                my $comm = $A{community} // '';
                $q{communities} = [ $comm ] if length $comm;   # else: config defaults
            }

            # Already in the DB: refresh it via the update endpoint instead.
            # (The name is the RR's; device.name is its integer id.)
            my $rr = eval { RR->search( name => $name )->first };
            $rr = undef if $@;
            if ( $rr ) {
                my $ex = eval { Device->search( name => $rr )->first };
                $ex = undef if $@;
                if ($ex) {
                    _err( 409, sprintf( 'Device %s already exists (id %d): use POST /api/device/%d/update to refresh its SNMP data',
                                        $ex->fqdn || $name, $ex->id, $ex->id ) );
                }
            }

            my $info = eval { Device->get_snmp_info( %q ) };
            _err( 400, 'SNMP session failed (host unreachable or bad credentials)' )
                if $@ || ! $info;

            # Optional review fields (as in the discovery wizard).
            my %argv = ( name => $name, info => $info );
            $argv{owner}   = $A{owner}   if defined $A{owner}   && length $A{owner};
            $argv{used_by} = $A{used_by} if defined $A{used_by} && length $A{used_by};
            $argv{site}    = $A{site}    if defined $A{site}    && length $A{site};
            my @cls;
            if ( ref $A{contacts} eq 'ARRAY' ) {
                @cls = grep { /^\d+$/ } @{ $A{contacts} };
            }
            elsif ( defined $A{contacts} && length $A{contacts} ) {
                @cls = grep { /^\d+$/ } split /,/, $A{contacts};
            }
            $argv{contacts}   = \@cls if @cls;
            $argv{add_subnets}  = 1 if _is_true( $A{add_subnets} );
            $argv{subs_inherit} = 1 if _is_true( $A{subs_inherit} );

            my ( $dev, $loglines, $err ) = _discover_captured( %argv );
            if ( $err || ! $dev ) {
                # Netdot exceptions stringify with their full stack trace;
                # keep only the message in the API response.
                $err = $err->message if ref $err && $err->can('message');
                _err( 400, "device discovery failed: " . ( $err // 'no device returned' ) );
            }
            return $c->render( json => { %{ Netdot::Mojo::Api::get( $dev, $p, undef, depth => 0 ) }, log => $loglines },
                               status => 201 );
        }

        # ---- Manual add ----
        my $host = $A{host} // '';
        $host =~ s/\s//g;
        _err( 400, 'Missing required parameter: host' ) unless length $host;
        my $dev = eval { Device->manual_add( host => $host ) };
        if ( $@ || ! $dev ) {
            my $err = $@;
            # Netdot exceptions stringify with their full stack trace; keep
            # only the message in the API response.
            $err = $err->message if ref $err && $err->can('message');
            _err( 400, "manual_add failed: $err" );
        }
        return $c->render( json => Netdot::Mojo::Api::get( $dev, $p, undef, depth => 0 ), status => 201 );
    });
}

# ---------------------------------------------------------------------------
# update_device — SNMP update (re-poll) of an existing device with its stored
# credentials (Mason: updatedevice.html?device=<id>, the "snmp-update" link).
# Admin-only. Optional `pretend`: dry run (the model rolls back at the end of
# the info update, but some nested fast_updates commit independently —
# see PORTING_NOTES).
=head2 update_device - SNMP re-poll of an existing device

Arguments:  Controller (POST /api/device/<id>/update, body: optional
            pretend = dry run, or explicit SNMP credentials)
Returns:    {device: <serialized device>, log: [model log lines]} (200)
Description: Admin-only: runs Device->get_snmp_info (stored credentials by
            default) then the model's update, with the model log captured
            for the UI. A dry run (pretend) is rolled back at the end of
            the transaction.

=cut

sub update_device {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        _err( 403, 'Updating a device via SNMP is reserved for administrators' )
            unless Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin';
        my $id = $c->stash('id');
        _err( 400, 'Missing device id' ) unless defined $id && $id =~ /^\d+$/;
        my $dev = eval { Device->retrieve($id) };
        _err( 404, "Device $id not found" ) if $@ || ! $dev;

        my %A    = %{ _args($c) };
        my $info = eval { $dev->get_snmp_info() };
        _err( 400, 'SNMP session failed (device not SNMP-managed or bad stored credentials)' )
            if $@ || ! $info;

        my %argv = ( name => $dev->fqdn, info => $info, do_info => 1 );
        $argv{pretend} = 1 if _is_true( $A{pretend} );

        my ( $upd, $loglines, $err ) = _discover_captured( %argv );
        if ( $err || ! $upd ) {
            $err = $err->message if ref $err && $err->can('message');
            _err( 400, "SNMP update failed: " . ( $err // 'no device returned' ) );
        }
        return $c->render( json => { %{ Netdot::Mojo::Api::get( $upd, $p, undef, depth => 0 ) }, log => $loglines },
                           status => 200 );
    });
}

# ---------------------------------------------------------------------------
# Device IP view actions (port of the legacy device.html "IP" section).
# Permission is 'edit' on the device (Mason: $manager->can($user,'edit',$o)).
# ---------------------------------------------------------------------------

# Add an IP address to the device (Mason: device.html add_ip form).
# Body: {address: "1.2.3.4", interface?: <id>}. Device->add_ip makes a /32
# (v4) or /128 (v6) block: an existing block is re-pointed at the interface,
# a new one is inserted with status Static. Interface defaults to the device's
# first (as in Mason).
=head2 add_ip - Add an IP address to a device

Arguments:  Controller (POST /api/device/<id>/ip, body: {address,
            interface?})
Returns:    The created /32 (v4) or /128 (v6) block (200)
Description: Port of the legacy device.html add_ip form: Device->add_ip
            makes the block — an existing block is re-pointed at the
            interface, a new one is inserted with status Static. The
            interface must belong to the device and defaults to the
            device's first (as in Mason). 'edit' on the device required.

=cut

sub add_ip {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $id = $c->stash('id');
        _err( 400, 'Missing device id' ) unless defined $id && $id =~ /^\d+$/;
        my $dev = eval { Device->retrieve($id) };
        _err( 404, "Device $id not found" ) if $@ || !$dev;
        _err( 403, 'User not allowed to edit this device' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $dev );
        my %A = %{ _args($c) };
        _err( 400, 'Missing "address"' ) unless defined $A{address} && length $A{address};
        my $int;
        if ( defined $A{interface} && length $A{interface} ) {
            $int = eval { Interface->retrieve( $A{interface} ) };
            _err( 404, "Interface $A{interface} not found" ) if $@ || !$int;
            _err( 400, 'Interface does not belong to this device' )
                unless eval { $int->device->id } == $id;
        }
        my $ipb = eval { $dev->add_ip( $A{address}, $int ) };
        _err( 400, "Could not add IP: $@" ) if $@;
        return $c->render( json => Netdot::Mojo::Api::get( $ipb, $p, undef, depth => 0 ),
                           status => 200 );
    });
}

# Set auto DNS on all of the device's IP-bearing interfaces (Mason: the
# "Set Auto DNS on all IP interfaces" form). Body: {value: 0|1}.
=head2 set_auto_dns - Set auto DNS on all of a device's IP interfaces

Arguments:  Controller (POST /api/device/<id>/auto_dns, body: {value: 0|1})
Returns:    {ok: 1} (200)
Description: Port of the legacy "Set Auto DNS on all IP interfaces" form
            (Device->set_interfaces_auto_dns). 'edit' on the device
            required.

=cut

sub set_auto_dns {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $id = $c->stash('id');
        _err( 400, 'Missing device id' ) unless defined $id && $id =~ /^\d+$/;
        my $dev = eval { Device->retrieve($id) };
        _err( 404, "Device $id not found" ) if $@ || !$dev;
        _err( 403, 'User not allowed to edit this device' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $dev );
        my %A = %{ _args($c) };
        _err( 400, '"value" must be 0 or 1' )
            unless defined $A{value} && $A{value} =~ /^(?:0|1)$/;
        eval { $dev->set_interfaces_auto_dns( $A{value} ) };
        _err( 400, "Could not set auto DNS: $@" ) if $@;
        return $c->render( json => { ok => 1 }, status => 200 );
    });
}

# Re-generate DNS names for all interface IPs of the device (Mason: the
# "Re-generate DNS names for all IPs" form). Skips silently when auto DNS is
# disabled (model logs a debug line and returns).
=head2 regen_dns - Re-generate DNS names for a device's interface IPs

Arguments:  Controller (POST /api/device/<id>/regen_dns, no body)
Returns:    {ok: 1} (200)
Description: Port of the legacy "Re-generate DNS names for all IPs" form
            (Device->do_auto_dns); skips silently when auto DNS is
            disabled (the model logs a debug line and returns). 'edit' on
            the device required.

=cut

sub regen_dns {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my $id = $c->stash('id');
        _err( 400, 'Missing device id' ) unless defined $id && $id =~ /^\d+$/;
        my $dev = eval { Device->retrieve($id) };
        _err( 404, "Device $id not found" ) if $@ || !$dev;
        _err( 403, 'User not allowed to edit this device' )
            unless Netdot::Mojo::Permissions->can( $p, 'edit', $dev );
        eval { $dev->do_auto_dns() };
        _err( 400, "DNS generation failed: $@" ) if $@;
        return $c->render( json => { ok => 1 }, status => 200 );
    });
}

# Create an IP service (Mason: addservice.html popup). Body:
# {ip: <id>, service: <id>, monitored?: bool, contactlist?: <id>}.
# A duplicate (ip, service) is a 400. Legacy side effect kept: the parent IP
# is set monitored on success.
=head2 add_ipservice - Create an IP service

Arguments:  Controller (POST /api/ipservice, body: {ip: <id>, service:
            <id>, monitored?, contactlist?})
Returns:    The created IpService (200); a duplicate (ip, service) is a 400
Description: Port of the legacy addservice.html popup. Permission is
            'edit' on the device owning the IP. Legacy side effect kept:
            the parent IP is set monitored on success.

=cut

sub add_ipservice {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        my %A = %{ _args($c) };
        _err( 400, 'Missing "ip" and/or "service"' )
            unless defined $A{ip} && $A{ip} =~ /^\d+$/
               && defined $A{service} && $A{service} =~ /^\d+$/;
        my $ipb = eval { Ipblock->retrieve( $A{ip} ) };
        _err( 404, "Ipblock $A{ip} not found" ) if $@ || !$ipb;
        my $dev = eval { $ipb->interface->device };
        _err( 403, 'User not allowed to edit this device' )
            if $dev && !Netdot::Mojo::Permissions->can( $p, 'edit', $dev );
        my $svc = eval { Service->retrieve( $A{service} ) };
        _err( 404, "Service $A{service} not found" ) if $@ || !$svc;
        if ( eval { IpService->search( ip => $A{ip}, service => $A{service} ) } ) {
            _err( 400, 'Service already exists on this IP' );
        }
        my %st = ( ip => $A{ip}, service => $A{service} );
        $st{monitored}   = _is_true( $A{monitored} ) ? 1 : 0;
        $st{contactlist} = $A{contactlist}
            if defined $A{contactlist} && $A{contactlist} =~ /^\d+$/;
        my $new = eval { IpService->insert( \%st ) };
        _err( 400, "Could not add service: $@" ) if $@;
        eval { $ipb->update( { monitored => 1 } ) };    # legacy side effect
        return $c->render( json => Netdot::Mojo::Api::get( $new, $p, undef, depth => 0 ),
                           status => 200 );
    });
}

# Grant access rights on an object (Mason: the generic access_right_form.html
# "Add rights" form, used from the Ipblock and Device Rights sections).
# Body: {object_class, object_id, subject_type: user|group, subject_id,
# rights: [view|edit|delete|choose_ip|none]}. All the grant semantics — allowed
# classes (AccessRight->get_classes), find-or-create of the AccessRight row,
# join-row dedup and the 'none' right semantics — live in the model's insert
# overloads (Model/AccessRight.pm + Model/UserRight.pm / GroupRight.pm); the
# API only adds the permission check and input-shape validation, and maps the
# model's throw_user errors to a 400. Row removal goes through the generic
# DELETE /api/userright/<id> / /api/groupright/<id>.
=head2 accessright - Grant access rights on an object

Arguments:  Controller (POST /api/accessright, body: {object_class,
            object_id, subject_type: user|group, subject_id, rights:
            [view|edit|delete|choose_ip|none]})
Returns:    {ok: 1} (200); the model's validation errors are mapped to 400
Description: Port of the generic access_right_form.html "Add rights" form
            (used from the Ipblock and Device Rights sections). Admin-only.
            All the grant semantics (allowed classes, find-or-create of the
            AccessRight row, join-row dedup, the 'none' right semantics)
            live in the model's insert overloads; the API only adds the
            permission check and input-shape validation. Row removal goes
            through the generic DELETE /api/userright/<id> /
            /api/groupright/<id>.

=cut

sub accessright {
    my ($c) = @_;
    my $p = _person($c) or return;
    return _run( $c, sub {
        _err( 405, 'Method not allowed' ) unless $c->req->method eq 'POST';
        _err( 403, 'Managing access rights is reserved for administrators' )
            unless Netdot::Mojo::Permissions->user_type( $p ) eq 'Admin';
        my %A = %{ _args($c) };
        _err( 400, 'Missing object id' )
            unless defined $A{object_id} && $A{object_id} =~ /^\d+$/;
        _err( 400, 'Missing subject id' )
            unless defined $A{subject_id} && $A{subject_id} =~ /^\d+$/;
        _err( 400, 'Select at least one right' )
            unless ref $A{rights} eq 'ARRAY' && @{ $A{rights} };
        my $obj = eval { $A{object_class}->retrieve( $A{object_id} ) };
        _err( 404, 'Object not found' ) if $@ || ! $obj;
        my $ar = eval {
            # The model's insert overload takes a hashref (its plain-insert
            # fallback forwards it to Netdot::Model::insert).
            AccessRight->insert( {
                object_class => $A{object_class},
                object_id    => $A{object_id},
                subject_type => $A{subject_type},
                subject_id   => $A{subject_id},
                rights       => $A{rights},
            } );
        };
        if ( my $e = $@ ) {
            $e = $e->message if ref $e && $e->can( 'message' );
            _err( 400, "Could not grant rights: $e" );
        }
        return $c->render( json => { ok => 1 }, status => 200 );
    });
}

# ---------------------------------------------------------------------------
# OpenAPI spec + Swagger UI
# ---------------------------------------------------------------------------

# Serve the OpenAPI 3 spec (YAML) at /api/openapi.yaml. Uses the generated
# file (api/gen_openapi.pl) when present; otherwise builds it on the fly from
# the model's meta (Netdot::Mojo::OpenAPI::build_spec).
=head2 spec - Serve the OpenAPI 3 spec

Arguments:  Controller (GET /api/openapi.yaml)
Returns:    The OpenAPI 3 document as YAML (application/yaml)
Description: Uses the generated file (api/gen_openapi.pl) when present;
            otherwise builds it on the fly from the model's meta
            (Netdot::Mojo::OpenAPI::build_spec).

=cut

sub spec {
    my ($c) = @_;
    my $p = _person($c) or return;
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
=head2 docs - Swagger UI

Arguments:  Controller (GET /api/docs)
Returns:    The Swagger UI page (loads /api/openapi.yaml via the Swagger UI
            CDN), standalone (no Netdot layout) so it works at the root or
            behind a sub-path proxy

=cut

sub docs {
    my ($c) = @_;
    my $p = _person($c) or return;
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