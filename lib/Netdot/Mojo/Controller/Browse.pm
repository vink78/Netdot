package Netdot::Mojo::Controller::Browse;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Permissions;
use Netdot::Mojo::Detail;

# Per-type filter columns for list pages (equivalent of Mason's
# search_obj.html?table=..&<col>=..&res=1). Only these columns may be passed.
# 'num' = numeric id only; 'str' = free string (the model quotes it). Filtering
# is done through the model's own search_like() (no hand-written SQL); the
# per-user 'view' rule is re-applied to the match set.
my %FILTERS = (
    device   => { site => 'num', product => 'num', os => 'str' },
    physaddr => { address => 'str' },
);

# Numeric-aware sort key for a display value: both-numeric -> numeric compare,
# otherwise case-insensitive text compare (mirrors the client-side tablesort.js).
sub _kcmp {
    my ( $x, $y ) = @_;
    $x = '' unless defined $x;
    $y = '' unless defined $y;
    if ( $x =~ /^-?\d+(?:\.\d+)?$/ && $y =~ /^-?\d+(?:\.\d+)?$/ ) { return $x <=> $y; }
    return lc( $x ) cmp lc( $y );
}

# BOUNDED, paginated list of one object type (SQL LIMIT/OFFSET + retrieve by id).
# Reuses the Netdot model, out of Apache. Works for every type in the Registry.
sub list ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $table  = $class->table;

    # Default server-side ordering: the type's FIRST display column (the label),
    # id as a stable tie-breaker. Needed because the list is paginated -- the
    # client-side tablesort.js only sorts the current page, so a global order must
    # come from the data. All of that SQL lives in the MODEL layer
    # (search_page/search_count, order_by => $first); a relationship first column
    # (FK, e.g. device.name -> RR) is ordered by the related label via a JOIN there.
    my $first    = $cols->[0];
    my $sort_col = $first;
    $sort_col = 'id' unless $sort_col =~ /^[A-Za-z_][A-Za-z0-9_]*$/;

    # Per-user access: a User sees only the objects they may view (none by
    # default). Admin/Operator are unrestricted (view access to everything).
    my $person = $c->current_person;
    # Per-user 'view' predicate: a RAW fragment like "(id IN (1,2) OR zone IN (3))"
    # (a literal IN list, no placeholders; '0' = nothing viewable). search_page /
    # search_count combine it via _combine_where (they add the WHERE keyword
    # themselves), so it is passed UN-prefixed. undef = unrestricted (Admin/Operator).
    my $frag = undef;
    if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
        my ($w) = Netdot::Mojo::Permissions->viewable_predicate( $class, $person );
        $frag = $w;
    }

    # ipblock: hierarchical view. The list shows the ROOT blocks only (parent is
    # NULL, version 4); clicking one shows its children (see Show#show).
    if ( $type eq 'ipblock' ) {
        # Root filters (port of ip.html rootversion + show_ch_util): an IPv4/IPv6
        # selector and a utilization toggle. Defaults keep the current behaviour
        # (all versions, utilization shown). show_ch_util is a checkbox backed by
        # a hidden =0 field, so it is present after any submit; absent on a fresh
        # load (default ON).
        my $rootversion = $c->param('rootversion') // 'all';
        $rootversion = '4' unless $rootversion =~ /^(?:4|6|all)$/;
        my $su        = $c->param('show_ch_util');
        my $show_util = defined $su ? ( $su eq '1' ? 1 : 0 ) : 1;
        # Direct list-context call: get_roots() uses wantarray, so it must NOT
        # be wrapped in eval{} // () (that degrades to scalar -> first root only).
        my @roots = $class->get_roots($rootversion);
        if ( defined $frag ) {
            # A root is visible if it, any descendant, or an allowed block's
            # ancestor path includes it: i.e. keep the roots that lead down to a
            # viewable block, so the user can drill in.
            my %keep;
            # Viewable block ids via the model layer (no raw SQL in the controller).
            my @viewable = $class->search_page( where => $frag, limit => 0 );
            for my $ip (@viewable) {
                next unless $ip;
                $keep{ $ip->id } = 1;
                $keep{ $_->id } = 1 for eval { $ip->get_ancestors } || ();
            }
            @roots = grep { $keep{ $_->id } } @roots;
        }
        # "New Ipblock" box (roots view only): shown when the user may create a
        # block (class-level 'edit', re-enforced by the API's _can_create at write
        # time). The model's insert() validates address/status (a bad combo -> 400),
        # and a duplicate (same address+prefix) -> 400 (unique constraint), so the
        # UI needs no pre-check / confirm (the error surfaces directly).
        my $can_create = Netdot::Mojo::Permissions->has_action( $class, $person, 'edit' );
        $c->render(
            template    => 'management/ipblock',
            layout      => 'default',
            title       => 'IP Blocks',
            viewtype    => 'block',
            blocks      => \@roots,
            breadcrumb  => [],
            rootversion => $rootversion,
            show_util   => $show_util,
            can_create  => $can_create,
        );
        return;
    }

    my $per    = eval { Netdot::Model->config->get('DEFAULT_PERPAGE') } || 50;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    # Optional column filters (Mason search_obj.html equivalent): resolved through
    # the model's own search_like(); the per-user 'view' rule is re-applied to the
    # (unbounded) match set, which is then paginated.
    my @filters;
    if ( my $spec = $FILTERS{$type} ) {
        for my $col ( keys %$spec ) {
            my $v = $c->param( $col );
            next unless defined $v && length $v;
            if ( $spec->{$col} eq 'num' ) {
                push @filters, ( $col => $v ) if $v =~ /^\d+$/;
            } else {   # 'str' - free string; the model quotes the value
                push @filters, ( $col => $v );
            }
        }
    }

    # Free-text search box (?search=, see list.html.ep): a raw, parameterised
    # LIKE %q% on the type's primary display column, combined with the per-user
    # 'view' predicate. Deliberately NOT search_like() -- that method is
    # overridden per class (e.g. Device::search_like(name=>..) matches DNS RR
    # names / aliases, not device.name), so a uniform free-text box needs the raw
    # query. The dedicated rr/physaddr/ipblock searches override this.
    my $q = $c->param('search');
    $q = '' unless defined $q;
    $q =~ s/^\s+|\s+$//g;

    my ( @objs, $total );
    my $like = length $q ? [ $first, $q ] : undef;    # free-text on the first col
    if ( @filters ) {
        # Per-type filter columns go through the model's own search_like()
        # (overridden per class), then ordered by the first column. No-op sort if
        # @objs holds an iterator (->col fails -> '' keys), so it cannot break a
        # non-list return some classes use.
        @objs  = $class->search_like( @filters );
        my $skey = sub { my $v = eval { $_[0] -> $sort_col }; $v = undef if $@;
                         Netdot::Mojo::Registry::format_value( $v ) // '' };
        @objs   = sort { _kcmp( $skey->($a), $skey->($b) ) } @objs;
        $total = scalar @objs;
        if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
            my $access = Netdot::Mojo::Permissions->allowed_objects( $class, $person );
            @objs = grep { Netdot::Mojo::Permissions->can( $person, 'view', $_, $access ) } @objs;
            $total = scalar @objs;
        }
        my $end = $offset + $per;
        $end     = $total if $end > $total;
        @objs    = $offset < $total ? @objs[ $offset .. $end - 1 ] : ();
    }
    else {    # default + free-text search: one query in the model layer (perms +
              # LIKE + first-column/FK order + pagination all handled there).
        my $ok = eval {
            @objs  = $class->search_page(
                where    => $frag,
                order_by => $first,
                like     => $like,
                limit    => $per,
                offset   => $offset,
            );
            $total = $class->search_count(
                where    => $frag,
                order_by => $first,
                like     => $like,
            );
            1;
        };
        unless ( $ok ) {    # never leak an unfiltered set on an error
            $c->app->log->error( "list on $table failed: $@" );
            ( @objs, $total ) = ( (), 0 );
        }
    }

    # May the current user delete objects of this type? (controls the delete form)
    my $can_delete = Netdot::Mojo::Permissions->has_action( $class, $person, 'delete' );

    # Bulk edit (port of the legacy edit-multiple.html): when the user may edit
    # objects of this type, the "Bulk edit" button opens a field-picker popup
    # (netdot.js initBulkEdit, window.ND_BULK) and then navigates to the
    # dedicated page /management/bulk_edit?table=&object_id=&fields= — a
    # full-width editable table that saves through POST /api/<table>/batch.
    # Only the field names/tags are stashed (the page re-reads the values).
    # (ipblock's list returns earlier with its own children-edit UI, so this
    # covers the generic list types, incl. rr/physaddr.)
    my $bulk;
    if ( @objs && Netdot::Mojo::Permissions->has_action( $class, $person, 'edit' ) ) {
        my @specs = @{ Netdot::Mojo::Detail::editable_field_specs( $class ) };
        $bulk = { type => $type, fields => [ map { { name => $_->{name}, tag => $_->{tag} } } @specs ] };
    }

    # Per-column meta tags (headers) and foreign-key targets (for cell links).
    # ($first / $sort_col are computed above, before the queries.)
    my %coltag  = map { $_ => Netdot::Mojo::Registry::column_tag( $class, $_ ) } @$cols;
    my %linkkey = map { $_ => Netdot::Mojo::Registry::column_link_key( $class, $_ ) } @$cols;

    # Build display rows: id (for the link) + the type's display columns. FK
    # columns render as links to the related object's detail page; the first
    # column stays raw (the template links it to the type's own detail page).
    my @rows;
    for my $obj (@objs) {
        my %row = ( id => $obj->id );
        for my $col (@$cols) {
            my $v = eval { $obj->$col };
            $v = undef if $@;
            my $label = Netdot::Mojo::Registry::format_value( $v );
            if ( $col eq $first ) {
                $row{$col} = $label;
                next;
            }
            my $id = ref( $v ) ? eval { $v->id } : $v;
            $row{$col} = ( $linkkey{$col} && defined $id && $id =~ /^\d+$/ )
                ? sprintf( '<a href="%s">%s</a>',
                           Netdot::Mojo::Registry::set_uri( "/management/$linkkey{$col}/$id" ),
                           Netdot::Mojo::Registry::esc( $label ) )
                : Netdot::Mojo::Registry::esc( $label );
        }
        push @rows, \%row;
    }

    my $start     = @rows ? $offset + 1 : 0;
    my $last_item = $offset + scalar(@rows);

    # Search box on the list page (list.html.ep): shown for every type. Generic
    # types search the primary column via ?search= (see search()); rr/physaddr
    # keep their dedicated richer searches; "Names within" shows only for rr.
    my %extra;
    $extra{search_url}         = $c->url_for( "${type}_search" );
    $extra{search_title}       = 'Search ' . $spec->{label};
    $extra{search_placeholder} = 'Filter by ' . Netdot::Mojo::Registry::column_tag( $class, $cols->[0] );
    if ( $type eq 'rr' ) {
        my @zones = Zone->retrieve_all;
        @zones = sort { $a->name cmp $b->name } @zones;
        $extra{zones}              = \@zones;
        $extra{search_title}       = 'Search DNS Records';
        $extra{search_placeholder} = 'Name / IP / MAC';

        # "New name" box: create a (record-less) name in a chosen zone. A User
        # only sees the zones they hold 'edit' on (the API re-enforces it at
        # write time: _can_create requires can('edit',$zone)). Default selection
        # is the DEFAULT_DNSDOMAIN zone.
        my $editable = \@zones;
        if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
            my $access = Netdot::Mojo::Permissions->allowed_objects( $class, $person );
            my %edit = map { $_ => 1 } grep {
                my $a = $access->{Zone}{$_};
                ref $a && !exists $a->{none} && exists $a->{edit};
            } keys %{ $access->{Zone} || {} };
            $editable = [ grep { $edit{ $_->id } } @zones ];
        }
        if ( @$editable ) {
            my $def    = Netdot::Model->config->get('DEFAULT_DNSDOMAIN');
            my $def_id;
            for my $z (@$editable) {
                $def_id = $z->id, last if defined $def && $z->name eq $def;
            }
            $def_id = $editable->[0]->id unless $def_id;
            $extra{new_rr} = {
                zones  => $editable,
                def_id => $def_id,
                api    => $c->web_prefix . '/api/rr',
                goto   => Netdot::Mojo::Registry::set_uri( '/management/rr/' ),
            };
        }
    } elsif ( $type eq 'physaddr' ) {
        $extra{search_title}       = 'Search MAC addresses';
        $extra{search_placeholder} = 'MAC address / OUI';
    }

    # "New <type>" create box for the generic list page (every type except rr,
    # which has its own name+zone box, and device, which has its own two boxes
    # — Discover / Add manually — instead of the generic insert): shown when
    # the user may create an object of this type (class-level 'edit' —
    # has_action already returns 1 for Admins; the API re-enforces it at write
    # time via _can_create). The form POSTs to /api/<table> and the model's
    # insert() validates the required fields (a missing one -> 400 with the
    # model's own message).
    if ( $type ne 'rr' && $type ne 'device'
         && Netdot::Mojo::Permissions->has_action( $class, $person, 'edit' ) ) {
        my @cfields = @{ Netdot::Mojo::Detail::build_create_fields( $class ) };
        if (@cfields) {
            $extra{new_obj} = {
                label  => $spec->{label},
                fields => \@cfields,
                api    => $c->web_prefix . '/api/' . $class->table,
                goto   => Netdot::Mojo::Registry::set_uri( '/management/' . $type . '/' ),
            };
        }
    }

    # Device only: "Add Device manually" (port of the legacy device_tasks.html)
    # — a second form inside the New Device box: one input (name or IP) calling
    # Device->manual_add via POST /api/device/manual_add (DNS resolution +
    # monitored device + interface + /32 (or /128) block + snmp_target).
    # Admin-only, as in Mason.
    if ( $type eq 'device' && Netdot::Mojo::Permissions->user_type( $person ) eq 'Admin' ) {
        $extra{new_device_manual} = {
            # Unified device-create endpoint (POST /api/device): this box
            # sends {discover: false, host} -> Device->manual_add.
            api      => $c->web_prefix . '/api/device',
            goto     => Netdot::Mojo::Registry::set_uri( '/management/device/' ),
            # "Discover Device" box (legacy device_tasks.html view=new):
            # posts to the wizard step 1 (review + guesses, then
            # Device->discover). Community select from the config.
            discover => Netdot::Mojo::Registry::set_uri( '/management/device/discover' ),
            comms    => [ @{ Netdot::Model->config->get('DEFAULT_SNMPCOMMUNITIES') || ['public'] } ],
            defver   => Netdot::Model->config->get('DEFAULT_SNMPVERSION') || 2,
            # v3 credentials, pre-filled from the config (Mason:
            # device_tasks.html prefilled the same DEFAULT_SNMP_* values and
            # showed the v3 fields only when version=3 was selected).
            v3       => {
                sec_name   => Netdot::Model->config->get('DEFAULT_SNMP_SECNAME')   // 'netdot',
                sec_level  => Netdot::Model->config->get('DEFAULT_SNMP_SECLEVEL')  // 'authPriv',
                auth_proto => Netdot::Model->config->get('DEFAULT_SNMP_AUTHPROTO') // 'SHA',
                auth_pass  => Netdot::Model->config->get('DEFAULT_SNMP_AUTHPASS')  // '',
                priv_proto => Netdot::Model->config->get('DEFAULT_SNMP_PRIVPROTO') // 'AES',
                priv_pass  => Netdot::Model->config->get('DEFAULT_SNMP_PRIVPASS')  // '',
            },
        };
    }

    $c->render(
        template  => 'management/list',
        layout    => 'default',
        title     => ucfirst($type),
        type      => $type,
        cols      => $cols,
        coltags   => \%coltag,
        rows      => \@rows,
        total     => $total,
        per       => $per,
        offset    => $offset,
        start     => $start,
        last_item => $last_item,
        can_delete => $can_delete,
        bulk       => $bulk,
        %extra,
    );
}

# Dedicated bulk-edit page (port of the legacy edit-multiple.html): the
# full-width editable table for the selected objects. Params: table (type) +
# object_id (comma-separated ids) + fields (comma-separated; the field picker
# itself is a popup on the list / search page, netdot.js initBulkEdit). The GET
# only renders — saving is client-side (netdot.js initBulkEditPage) via
# POST /api/<table>/batch, which re-checks per-object edit rights on every id.
sub bulk_edit ($c) {
    my $type = $c->param( 'table' ) // '';
    my $spec = Netdot::Mojo::Registry::spec( $type )
        or return $c->reply->not_found;
    my $class  = $spec->{class};
    my $person = $c->current_person;

    # The selected objects (object_id=3,10,12): keep the resolvable, viewable
    # ones; edit rights are enforced per id by the batch API at save time.
    my @ids  = grep { /^\d+$/ } split /,/, ( $c->param( 'object_id' ) // '' );
    my @objs;
    for my $id (@ids) {
        my $o = eval { $class->retrieve($id) };
        next unless $o;
        next unless Netdot::Mojo::Permissions->can( $person, 'view', $o );
        push @objs, $o;
    }
    return $c->reply->not_found unless @objs;

    # Chosen fields: the picker (a popup on the list / search page) submits them
    # comma-separated; validate against the editable set (the same set the batch
    # API accepts — single source of truth, editable_field_specs). A direct GET
    # without any valid field bounces back to the list.
    my $fields  = Netdot::Mojo::Detail::editable_field_specs( $class );
    my %fbyname = map { $_->{name} => $_ } @$fields;
    my @sel     = grep { m/^\S+$/ } split /,/, join( ',', $c->req->param( 'fields' ) );
    my @selfields = map { $fbyname{$_} } grep { $fbyname{$_} } @sel;
    return $c->redirect_to( Netdot::Mojo::Registry::set_uri( '/management/' . $type ) ) unless @selfields;

    # Current value of each chosen field for each object (+ the current FK label
    # for a large target, whose <select> is pre-filled with it).
    my ( %vals, %fklabel );
    for my $o (@objs) {
        my %row;
        for my $f (@selfields) {
            my $col = $f->{name};
            my $val = Netdot::Mojo::Detail::bulk_edit_value( $f, $o );
            $row{$col} = $val;
            if ( $f->{kind} eq 'fk' && !$f->{options} && $val && !$fklabel{$col}{$val} ) {
                my $fo = eval { $o->$col };
                my $l  = $fo ? eval { $fo->get_label } : undef;
                $fklabel{$col}{$val} = ( defined $l && length $l ) ? $l : $val;
            }
        }
        $vals{ $o->id } = \%row;
    }

    my @objects = map {
        my $l = eval { $_->get_label };
        { id => $_->id, label => ( defined $l && length $l ) ? $l : '#' . $_->id }
    } @objs;

    $c->render(
        template  => 'management/bulk_edit',
        layout    => 'default',
        title     => 'Bulk edit',
        type      => $type,
        label     => $spec->{label},
        objects   => \@objects,
        sel       => \@selfields,
        vals      => \%vals,
        fk_labels => \%fklabel,
        back      => Netdot::Mojo::Registry::set_uri( '/management/' . $type ),
        api       => $c->web_prefix . '/api/' . $type . '/batch',
    );
}

# Generic per-type search box (route /management/<type>/search). Delegates to
# list(), which reads ?search= and filters the primary display column through
# the model's search_like(); the per-user 'view' rule is re-applied and the
# results are paginated and rendered by the same list template. The dedicated
# rr/physaddr/ipblock controllers override this for their richer multi-field
# searches (name / IP / MAC, hierarchical IP blocks, ...).
sub search ($c) { $c->list; }

# CSV export of ALL objects of one type (header line + every row), streamed from
# the model iterator. Relationships are rendered via ->get_label (like viewtext.html).
sub csv ($c) {
    my $type  = $c->stash('type');
    my $spec  = Netdot::Mojo::Registry::spec($type)
        or return $c->reply->not_found;
    my $class = $spec->{class};
    my $cols  = $spec->{cols};
    my $meta  = $class->meta_data;

    # Pre-compute per-column metadata once (header tag + whether it is a relationship).
    my @colmeta;
    for my $col (@$cols) {
        my $tag   = Netdot::Mojo::Registry::column_tag( $class, $col );
        my $links = eval { $meta->get_column( $col )->links_to };
        push @colmeta, { col => $col, tag => $tag, links => $links };
    }

    my $csv  = join( ',', map { Netdot::Mojo::Registry::csv_field( $_->{tag} ) } @colmeta ) . "\n";

    # Per-user filter: a User exports only the objects they may view (none by
    # default). Admin/Operator export everything.
    my $person = $c->current_person;
    # Raw 'view' fragment (un-prefixed; see list) -- combined by search_page.
    my $frag = undef;
    if ( Netdot::Mojo::Permissions->user_type( $person ) eq 'User' ) {
        my ($w) = Netdot::Mojo::Permissions->viewable_predicate( $class, $person );
        $frag = $w;
    }

    my $emit = sub {
        my ($o) = @_;
        my @vals;
        for my $cm (@colmeta) {
            my $col = $cm->{col};
            my $val = $cm->{links}
                     ? eval { my $fo = $o->$col; $fo ? $fo->get_label : '' }
                     : eval { $o->$col };
            push @vals, Netdot::Mojo::Registry::csv_field( defined $val ? $val : '' );
        }
        $csv .= join( ',', @vals ) . "\n";
    };

    # All rows, in the list view's first-column order (order_by handles a
    # relationship first column via a JOIN); limit 0 = no page window.
    my @objs = $class->search_page( where => $frag, order_by => $cols->[0], limit => 0 );
    $emit->($_) for @objs;

    my $h = $c->res->headers;
    $h->content_type( 'text/csv' );
    $h->content_disposition( 'attachment; filename="' . $type . '.csv"' );
    $c->render( data => $csv );
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