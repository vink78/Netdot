package Netdot::Mojo::Controller::Api;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Exporter;
use Netdot::Mojo::Api;
use Netdot::Mojo::Permissions;
use Netdot::Mojo::OpenAPI;

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
sub _args {
    my ($c) = @_;
    my %a;
    for my $k ( $c->req->params->names ) { $a{$k} = $c->param($k) }
    my $body = eval { $c->req->json };
    %a = ( %a, %$body ) if ref $body eq 'HASH';
    return \%a;
}

# Search args: drop control keys, undef and empty-string values.
sub _search_args {
    my ($a) = @_;
    my %c;
    for my $k ( keys %$a ) {
        next if $k eq 'depth' || $k eq 'linked_from';
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

# Public base URL (no trailing slash): WEB_BASE_URL from the config when set
# (covers HTTPS + sub-path proxy deployments), else derived from the request
# (correct when the app is served at the domain root).
sub _base_url {
    my ($c) = @_;
    my $cfg = eval { Netdot->config->get('WEB_BASE_URL') };
    $cfg = '' unless defined $cfg && !ref $cfg;
    my $b = ( $cfg ne '' ) ? $cfg : $c->req->url->base->to_string;
    $b =~ s{/+$}{};
    return $b;
}

# A machine-readable landing point, Netbox-style: a flat {resource: absolute-url}
# map. Every model table plus the purpose-built endpoints and the docs/spec.
# GET only (else 405 JSON).
sub root {
    my ($c) = @_;
    return $c->render( json => { error => 'Method not allowed', path => '/api' }, status => 405 )
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

        if ( defined $id && $id =~ /^\d+$/ ) {
            if ( $method eq 'GET' ) {
                my $obj = $class->retrieve($id);
                _err( 404, "$class/$id not found" ) unless $obj;
                my %ga = ( obj => $obj );
                $ga{depth}       = int( $args->{depth} ) if defined $args->{depth} && $args->{depth} ne '';
                $ga{linked_from} = 1                   if defined $args->{linked_from} && $args->{linked_from} ne '0';
                return $c->render( json => Netdot::Mojo::Api::get( $obj, $p, undef, %ga ), status => 200 );
            }
            elsif ( $method eq 'POST' ) {
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

        # plural (no id)
        if ( $method eq 'GET' ) {
            my $depth       = ( defined $args->{depth} && $args->{depth} ne '' ) ? int( $args->{depth} ) : 0;
            my $linked_from = ( defined $args->{linked_from} && $args->{linked_from} ne '0' ) ? 1 : undef;
            my $sargs       = _search_args($args);
            my $results = keys %$sargs ? _search( $class, %$sargs ) : $class->retrieve_all();
            my @objs;
            while ( my $o = $results->next ) {
                # permission-safe list: skip objects the user may not view.
                next unless Netdot::Mojo::Permissions->can( $p, 'view', $o );
                my %ga = ( obj => $o, depth => $depth );
                $ga{linked_from} = $linked_from if $linked_from;
                push @objs, Netdot::Mojo::Api::get( $o, $p, undef, %ga );
            }
            return $c->render( json => { $class => \@objs }, status => 200 );
        }
        elsif ( $method eq 'POST' ) {
            return $c->render( json => _post( $class, undef, $args, $p ), status => 200 );
        }
        else {
            return $c->render( json => { error => "Method $method not allowed" }, status => 405 );
        }
    });
}

# Create or update via the generic router. FK fields are passed as their id.
sub _post {
    my ( $class, $id, $args, $p ) = @_;
    my %a = %$args;
    delete @a{qw(depth linked_from)};
    my $obj;
    if ($id) {
        $obj = $class->retrieve($id);
        _err( 404, "$class/$id not found" ) unless $obj;
        unless ( Netdot::Mojo::Permissions->can( $p, 'edit', $obj ) ) {
            _err( 403, 'User not allowed to edit this object' );
        }
        eval { $obj->update(\%a) };
        _err( 400, "Bad request: $@" ) if $@;
    }
    else {
        my $new = eval { $class->insert(\%a) };
        _err( 400, "Bad request: $@" ) if $@;
        $obj = $new;
    }
    return Netdot::Mojo::Api::get( $obj, $p, undef, depth => 0 );
}

sub _delete {
    my ( $class, $id, $p ) = @_;
    my $obj = $class->retrieve($id);
    _err( 404, 'Not found' ) unless $obj;
    unless ( Netdot::Mojo::Permissions->can( $p, 'delete', $obj ) ) {
        _err( 403, 'User not allowed to delete this object' );
    }
    eval { $obj->delete };
    _err( 400, 'Bad request' ) if $@;
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
            my ( %rrs, %ips ) = _host_collect( \%A, $p, $like );
            my %ret;
            for my $rr ( values %rrs ) { push @{ $ret{RR} }, Netdot::Mojo::Api::get( $rr, $p, undef, depth => 0 ) }
            for my $ip ( values %ips ) { push @{ $ret{Ipblock} }, Netdot::Mojo::Api::get( $ip, $p, undef, depth => 0 ) }
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

sub _list {
    my $it = shift;
    return () unless defined $it;
    # Relation called in scalar context returns a CDBI iterator; otherwise we
    # may have received a plain list/arrayref value.
    if ( ref $it && eval { $it->can('next') } ) {
        my @out;
        while ( my $o = $it->next ) { push @out, $o }
        return @out;
    }
    return ( ref $it eq 'ARRAY' ) ? @$it : ( $it );
}

sub _first {
    my $it = shift;
    return undef unless defined $it;
    return $it->first if ref $it && eval { $it->can('first') };
    return ( ref $it eq 'ARRAY' ) ? $it->[0] : $it;
}

1;
