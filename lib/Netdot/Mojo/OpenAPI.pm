package Netdot::Mojo::OpenAPI;

# Build an OpenAPI 3.0 document for the Netdot JSON API from Netdot's meta
# (lib/Netdot/Meta.pm), i.e. the same source of truth as the model. One schema
# and a set of paths per Netdot table, plus the specific (non-generic)
# endpoints. This is the single source of truth used both by the generator
# script (api/gen_openapi.pl -> api/openapi.yaml) and, on the fly, by the
# /api/openapi.yaml route when the file is absent.
#
#   my $spec = Netdot::Mojo::OpenAPI->build_spec();   # -> hashref

use strict;
use warnings;

use Netdot;
use Netdot::Model;

# sql_type -> OpenAPI type (+ optional format)
my %TYPE_MAP = (
    bigint    => 'integer',
    integer   => 'integer',
    numeric   => 'number',
    bool      => 'boolean',
    date      => [ 'string', 'date' ],
    timestamp => [ 'string', 'date-time' ],
    varchar   => 'string',
    text      => 'string',
    longblob  => 'string',
);

# Build the full OpenAPI document (hashref).
sub build_spec {
    my @tabs = Netdot->meta->get_tables();
    my ( %schemas, %paths );

    # Public base (config WEB_BASE_URL when set, else relative) so "servers"
    # points at the real API root (matters behind a sub-path proxy).
    my $cfg = eval { Netdot->config->get('WEB_BASE_URL') };
    $cfg = '' unless defined $cfg && !ref $cfg;
    $cfg =~ s{/+$}{};
    my $server = ( $cfg ne '' ) ? "$cfg/api" : '/api';

    for my $t ( sort { $a->db_name cmp $b->db_name } @tabs ) {
        my $table = $t->db_name;
        my $class = $t->name;
        my %lt;
        eval { %lt = $t->get_links_to };

        $schemas{$class} = _schema( $t, $class, \%lt );

        $paths{ "/api/$table" } = {
            get => {
                summary   => "List $table objects (all, or filtered with ?column=value)",
                operationId => "list_$table",
                parameters => _list_search_params( $t, \%lt ),
                responses => {
                    '200' => {
                        description => "Paginated list of $class objects (count / next / previous / results).",
                        content     => {
                            'application/json' => {
                                schema => {
                                    type       => 'object',
                                    properties => {
                                        count    => { type => 'integer', description => 'Total number of matching objects (before paging).' },
                                        next     => { type => 'string', nullable => 1, description => 'URL of the next page, or null.' },
                                        previous => { type => 'string', nullable => 1, description => 'URL of the previous page, or null.' },
                                        results  => {
                                            type  => 'array',
                                            description => 'Objects on this page (up to "limit").',
                                            items => { '$ref' => "#/components/schemas/$class" },
                                        },
                                    },
                                },
                            },
                        },
                    },
                    '401' => _err(401),
                },
            },
            post => {
                summary     => "Create a $class (body = field values; FK fields as their id)",
                operationId => "create_$table",
                requestBody => _req_body($class),
                responses   => {
                    '200' => _ok("Created object.", $class),
                    '400' => _err(400),
                    '401' => _err(401),
                    '403' => _err(403),
                },
            },
        };

        $paths{ "/api/$table/{id}" } = {
            parameters => [ _id_param() ],
            get => {
                summary     => "Get a $class by id (options: depth, linked_from)",
                operationId => "get_$table",
                parameters  => [ _id_param(), _depth_param(), _linked_from_param() ],
                responses   => {
                    '200' => _ok("The $class object.", $class),
                    '404' => _err(404),
                    '401' => _err(401),
                    '403' => _err(403),
                },
            },
            post => {
                summary     => "Update a $class (body = fields to change; FK fields as their id)",
                operationId => "update_$table",
                requestBody => _req_body($class),
                responses   => {
                    '200'   => _ok("Updated object.", $class),
                    '400'   => _err(400),
                    '404'   => _err(404),
                    '401'   => _err(401),
                    '403'   => _err(403),
                },
            },
            delete => {
                summary     => "Delete a $class",
                operationId => "delete_$table",
                responses   => {
                    '200' => { description => 'Deleted.' },
                    '404' => _err(404),
                    '401' => _err(401),
                    '403' => _err(403),
                },
            },
        };

        $paths{ "/api/$table/meta_data" } = {
            get => {
                summary     => "Class metadata for $table (columns, order, labels, links)",
                operationId => "meta_$table",
                responses   => {
                    '200' => {
                        description => 'The class metadata as a JSON object.',
                        content     => { 'application/json' => { schema => { type => 'object' } } },
                    },
                    '401' => _err(401),
                },
            },
        };
    }

    # Per-class reference schemas: a foreign key to class X is rendered on read
    # as a nested {id, url, ...label fields} reference (schema FkReference_X).
    # Build one for every class that some FK points at, so the docs match the
    # runtime get_hashref exactly (both derive from get_ref_field_spec).
    my %referenced;
    for my $t (@tabs) {
        my %lt;
        eval { %lt = $t->get_links_to };
        $referenced{$_} = 1 for values %lt;
    }
    $schemas{ "FkReference_$_" } = _ref_schema($_) for sort keys %referenced;

    _add_specific_endpoints(\%paths);

    return {
        openapi => '3.0.3',
        info    => {
            title       => 'Netdot API',
            version     => '1.0.0',
            description => join( "\n",
                'JSON API for Netdot (port of the legacy `/rest` interface).',
                'Every Netdot table is exposed as a resource:',
                '',
                '  GET    /api/{table}            list all, or search (?column=value)',
                '  GET    /api/{table}/{id}       single object (depth, linked_from options)',
                '  GET    /api/{table}/meta_data  class metadata',
                '  POST   /api/{table}            create (body: field values, FK fields as id)',
                '  POST   /api/{table}/{id}       update',
                '  DELETE /api/{table}/{id}       delete',
                '',
                'List responses are paginated (Netbox-style): {count, next, previous, results}.',
                'Use ?limit=N (default 50, max 1000) and ?offset=N; follow "next"/"previous".',
                '',
                'Foreign keys: on write pass the target id (integer); on read the field is a',
                'nested reference object: {id, url} plus the target\'s label fields, e.g.',
                '  "zone": {"id":2,"url":"/netdot/api/zone/2/","name":"example.com"}.',
                'The label fields are the columns that identify the object (e.g. "name" for a',
                'zone/device, "address" + "prefix" for an ipblock, "name" + "zone" for an rr).',
                'Every object also carries a "url" field (e.g. /netdot/api/<table>/<id>/).',
                'Use ?depth=N to inline full referenced objects, ?linked_from=1 for back-references.',
                '',
                'Authentication: the Netdot web session (log in at /login). Unauthenticated',
                'requests get 401.',
            ),
        },
        servers => [ { url => $server, description => ( $cfg ne '' ? 'Public API root (from WEB_BASE_URL prefix).' : 'Relative to the Netdot base URL.' ) } ],
        tags    => [
            { name => 'generic',     description => 'Generic per-table resource access' },
            { name => 'specific',    description => 'Purpose-built endpoints' },
        ],
        paths    => \%paths,
        components => {
            securitySchemes => {
                session => {
                    type    => 'apiKey',
                    in      => 'cookie',
                    name    => 'netdot_session',
                    description => 'Netdot session cookie (obtained via POST /login).',
                },
            },
            schemas => \%schemas,
        },
        security => [ { session => [] } ],
    };
}

# Schema for a table: every column in meta order, typed, with FK notes.
sub _schema {
    my ( $t, $class, $lt ) = @_;

    my $md    = $class->meta_data;
    my %order;
    eval { %order = $md->get_column_order };

    my %props;
    for my $colname ( sort { ( $order{$a} // 999 ) <=> ( $order{$b} // 999 ) } keys %order ) {
        my $col = eval { $t->get_column($colname) } or next;
        my ( $otype, $ofmt ) = _type($col);

        my %p = ( type => $otype );
        $p{format} = $ofmt if $ofmt;

        my $tag  = eval { $col->tag } // '';
        my $desc = eval { $col->descr } // '';
        my @d;
        push @d, $tag  if $tag  && $tag  ne $colname;
        push @d, $desc if $desc;
        $p{description} = join( ': ', @d ) if @d;

        if ( $colname eq 'id' ) {
            $p{description} = "Id of the $class object.";
        }
        elsif ( exists $lt->{$colname} ) {
            my $target = $lt->{$colname};
            $p{type} = undef;
            # On write: the target id (integer). On read: a nested reference object.
            $p{anyOf} = [ { type => 'integer' }, { '$ref' => "#/components/schemas/FkReference_$target" } ];
            my $note = sprintf(
                "Foreign key to %s (pass the id on write; on read a nested {id, url, ...label fields} reference).",
                $target
            );
            $p{description} = ( $p{description} ? $p{description} . ' ' : '' ) . $note;
        }

        $props{$colname} = \%p;
    }

    # Resource URL (always present): <prefix>/api/<table>/<id>/
    $props{url} = {
        type        => 'string',
        description => 'URL of this resource, e.g. /netdot/api/<table>/<id>/.',
    };

    return {
        type        => 'object',
        description => $t->descr,
        properties  => \%props,
    };
}

# OpenAPI type for a raw sql_type (used by _ref_schema for FK reference fields).
sub _sql_type_to_openapi {
    my ($st) = @_;
    my $v = $TYPE_MAP{ lc( $st // '' ) };
    return ( ref $v eq 'ARRAY' ) ? $v->[0] : ( defined $v ? $v : 'string' );
}

# The nested reference schema for a class: {id, url} plus its label fields.
# Mirrors the runtime get_hashref (both derive from get_ref_field_spec).
sub _ref_schema {
    my ($class) = @_;
    my %props = (
        id  => { type => 'integer', description => 'Id of the referenced object.' },
        url => { type => 'string',  description => 'Resource URL of the referenced object (e.g. /netdot/api/<table>/<id>/).' },
    );
    my @spec;
    eval { @spec = $class->get_ref_field_spec() };
    for my $f (@spec) {
        my $type = $f->{is_fk} ? 'string' : _sql_type_to_openapi( $f->{sql_type} );
        my $note = $f->{is_fk}
            ? "Label field '$f->{name}' (label of the related object)."
            : "Label field '$f->{name}' of the referenced object.";
        $props{ $f->{name} } = { type => $type, description => $note };
    }
    return {
        type        => 'object',
        description => "Nested reference to a $class: {id, url} plus its label fields.",
        properties  => \%props,
        required    => [ 'id' ],
    };
}

sub _type {
    my ($col) = @_;
    my $st = lc( eval { $col->sql_type } // '' );
    my $v  = $TYPE_MAP{$st};
    if ( ref $v eq 'ARRAY' ) { return @$v }
    return ( defined $v ? $v : 'string' );
}

sub _list_search_params {
    my ( $t, $lt ) = @_;
    my @labels;
    eval { @labels = $t->get_labels };
    my @params;
    for my $l (@labels) {
        push @params, {
            name        => $l,
            in          => 'query',
            required    => 0,
            schema      => { type => 'string' },
            description => "Filter by $l.",
        };
    }
    # A free-form note: any column can be used as a filter.
    push @params, {
        name        => 'column',
        in          => 'query',
        required    => 0,
        schema      => { type => 'string' },
        description => 'Any non-FK column can also be used as a ?column=value filter (e.g. ?name=foo&site=2).',
    };
    # Pagination.
    push @params, {
        name        => 'limit',
        in          => 'query',
        required    => 0,
        schema      => { type => 'integer', default => 50, minimum => 1, maximum => 1000 },
        description => 'Maximum results per page (default 50, max 1000).',
    };
    push @params, {
        name        => 'offset',
        in          => 'query',
        required    => 0,
        schema      => { type => 'integer', default => 0, minimum => 0 },
        description => 'Number of results to skip (use the "next" pointer to page forward).',
    };
    return \@params;
}

sub _req_body {
    my ($class) = @_;
    return {
        required => 1,
        content  => { 'application/json' => { schema => { '$ref' => "#/components/schemas/$class" } } },
    };
}

sub _ok {
    my ( $desc, $class ) = @_;
    return {
        '200' => {
            description => $desc,
            content     => { 'application/json' => { schema => { '$ref' => "#/components/schemas/$class" } } },
        },
    };
}

sub _err {
    my ($code) = @_;
    my %msg = ( 400 => 'Bad request', 401 => 'Authentication required', 403 => 'Not allowed', 404 => 'Not found', 405 => 'Method not allowed', 500 => 'Internal error' );
    return { $code => { description => $msg{$code} // 'Error', content => { 'application/json' => { schema => { type => 'object' } } } } };
}

sub _id_param {
    return {
        name        => 'id',
        in          => 'path',
        required    => 1,
        schema      => { type => 'string' },
        description => 'Object id (integer).',
    };
}

sub _depth_param {
    return {
        name        => 'depth',
        in          => 'query',
        required    => 0,
        schema      => { type => 'integer', default => 0 },
        description => 'How many levels of referenced (FK) objects to inline as full objects (0 = nested {id, url, ...label fields} references only).',
    };
}

sub _linked_from_param {
    return {
        name        => 'linked_from',
        in          => 'query',
        required    => 0,
        schema      => { type => 'string' },
        description => 'Set to 1 to include a "linked_from" key of back-references (arrays of {id, url, ...label fields} references).',
    };
}

# The purpose-built endpoints (ports of the legacy /rest handlers).
sub _add_specific_endpoints {
    my ($paths) = @_;
    my $host_params = [
        { name => 'rrid',     in => 'query', schema => { type => 'string' }, description => 'Id of the RR.' },
        { name => 'ipid',     in => 'query', schema => { type => 'string' }, description => 'Id of the Ipblock.' },
        { name => 'name',     in => 'query', schema => { type => 'string' }, description => 'RR name.' },
        { name => 'address',  in => 'query', schema => { type => 'string' }, description => 'IPv4/IPv6 address.' },
        { name => 'ethernet', in => 'query', schema => { type => 'string' }, description => 'MAC address (DHCP host).' },
        { name => 'duid',     in => 'query', schema => { type => 'string' }, description => 'DUID (IPv6 DHCP host).' },
        { name => 'zone',     in => 'query', schema => { type => 'string' }, description => 'Zone name (all RRs in the zone).' },
        { name => 'subnet',   in => 'query', schema => { type => 'string' }, description => 'Subnet address (all IPs in the subnet).' },
    ];
    my $host_resp = {
        '200' => { description => 'RR and/or Ipblock objects.', content => { 'application/json' => { schema => { type => 'object' } } } },
        '400' => _err(400), '403' => _err(403), '404' => _err(404),
    };

    $paths->{'/devinfo'} = {
        get => {
            tags        => [qw(specific)],
            summary     => 'Device info dump (Netdot::Exporter::get_device_info)',
            operationId => 'devinfo',
            parameters  => [ { name => 'site', in => 'query', required => 0, schema => { type => 'string' }, description => 'Filter by site.' } ],
            responses   => { '200' => { description => 'Device info.', content => { 'application/json' => { schema => { type => 'object' } } } }, '401' => _err(401) },
        },
    };

    $paths->{'/host_contacts'} = {
        get => {
            tags        => [qw(specific)],
            summary     => 'DNS + contact information for a given IP address',
            operationId => 'host_contacts',
            parameters  => [
                { name => 'ip',       in => 'query', required => 1, schema => { type => 'string' }, description => 'The IP address.' },
                { name => 'dns',      in => 'query', required => 0, schema => { type => 'string' }, description => 'Set to 1 to include DNS (A/TXT/HINFO/CNAME/DHCP) data.' },
                { name => 'contacts', in => 'query', required => 0, schema => { type => 'string' }, description => 'Set to 1 to include contact lists.' },
            ],
            responses   => { '200' => { description => 'DNS and contact info.', content => { 'application/json' => { schema => { type => 'object' } } } }, '401' => _err(401), '403' => _err(403), '404' => _err(404) },
        },
    };

    $paths->{'/ipattr'} = {
        get => {
            tags        => [qw(specific)],
            summary     => 'Inherited IP attributes for an IP block/address',
            operationId => 'ipattr',
            parameters  => [ { name => 'addr', in => 'query', required => 1, schema => { type => 'string' }, description => 'IP block or address.' } ],
            responses   => { '200' => { description => 'Inherited attributes.', content => { 'application/json' => { schema => { type => 'object' } } } }, '400' => _err(400), '404' => _err(404) },
        },
    };

    for my $ep ( [ 'host' => 'exact name match' ], [ 'host_like' => 'fuzzy name match' ] ) {
        my ( $name, $note ) = @$ep;
        $paths->{ "/$name" } = {
            get => {
                tags        => [qw(specific)],
                summary     => "DNS/DHCP host lookup ($note)",
                operationId => "get_$name",
                parameters  => $host_params,
                responses   => $host_resp,
            },
            post => {
                tags        => [qw(specific)],
                summary     => "Update (rrid/ipid) or create a DNS/DHCP host ($note)",
                operationId => "post_$name",
                parameters  => $host_params,
                requestBody => { required => 0, content => { 'application/json' => { schema => { type => 'object' } } } },
                responses   => $host_resp,
            },
            delete => {
                tags        => [qw(specific)],
                summary     => "Delete a DNS/DHCP host (rrid / ipid / ethernet) ($note)",
                operationId => "delete_$name",
                parameters  => $host_params,
                responses   => { '200' => { description => 'Deleted.' }, '400' => _err(400), '403' => _err(403), '404' => _err(404) },
            },
        };
    }

    $paths->{'/updatedev'} = {
        post => {
            tags        => [qw(specific)],
            summary     => 'Discover / update a device from serialized device info',
            operationId => 'updatedev',
            requestBody => {
                required => 1,
                content  => {
                    'application/json' => {
                        schema => {
                            type        => 'object',
                            properties => {
                                name => { type => 'string', description => 'Device name.' },
                                info => { type => 'object', description => 'Serialized device information.' },
                            },
                        },
                    },
                },
            },
            responses   => { '200' => _ok('Discovered device.', 'Device'), '400' => _err(400), '401' => _err(401) },
        },
    };
}

1;
