package Netdot::Mojo::Controller::Contactlist;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot;
use Netdot::Model;
use Netdot::Mojo::Registry;
use Netdot::Mojo::Detail;

# Detail page for a Contact List (port of generic/contactlist.html, read-only).
# The "contacts" has_many is rendered as a dedicated section (one row per role:
# the linked Person + contact type + notify/escalation fields), sorted by the
# person's label. All other has_many relations are shown as generic tables.
# Write actions ([new]/[edit]/[delete]) are omitted (edit interface not migrated).
sub show ($c) {
    my $id = $c->param('id');
    $id =~ /^\d+$/ or return $c->reply->not_found;
    my $o = eval { ContactList->retrieve($id) };
    return $c->reply->not_found unless $o;
    return if $c->deny_unless( 'view', $o );    # per-object access (User: none by default)

    my $perpage = eval { $o->config->get('DEFAULT_PERPAGE') };
    $perpage = 50 unless $perpage && $perpage > 0;
    my $offset = int( $c->param('offset') // 0 );
    $offset = 0 if $offset < 0;

    my $attrs = Netdot::Mojo::Detail::build_attrs( $o, 'ContactList' );
    my $contacts = _contacts( $o );

    # Generic has_many tables, minus the specially-rendered `contacts` relation.
    my $relations = Netdot::Mojo::Detail::build_relations( $o, $perpage, $offset );
    $relations = [ grep { $_->{csv_rel} ne 'contacts' } @$relations ];

    $c->render(
        template  => 'management/contactlist',
        layout    => 'default',
        title     => 'Contact List ' . ( $o->get_label // $id ),
        type      => 'contactlist',
        id        => $id,
        attrs     => $attrs,
        contacts  => $contacts,
        relations => $relations,
    );
}

# Contact roles of this list, sorted by the person's label. Each row: the linked
# Person plus the role's contact type and notify/escalation fields.
sub _contacts {
    my ($o) = @_;
    my @roles = eval { $o->contacts };
    @roles = sort { _p_label($a) cmp _p_label($b) } @roles;

    my @rows;
    for my $r (@roles) {
        my $person   = eval { $r->person };
        my $plabel   = eval { $person->get_label } // '';
        my $phref    = $person ? Netdot::Mojo::Registry::set_uri( '/management/person/' . $person->id ) : '';
        my $ct       = eval { $r->contacttype };
        push @rows, {
            person           => [ $plabel, $phref ],
            contacttype      => eval { $ct->name } // '',
            notify_email     => _str( $r, 'notify_email' ),
            notify_pager     => _str( $r, 'notify_pager' ),
            notify_voice     => _str( $r, 'notify_voice' ),
            escalation_level => _str( $r, 'escalation_level' ),
        };
    }
    return \@rows;
}

sub _p_label {
    my ($r) = @_;
    my $p = eval { $r->person };
    return eval { $p->get_label } // '';
}

sub _str {
    my ($o, $col) = @_;
    my $v = eval { $o->$col };
    return ( defined $v ? $v : '' );
}

1;
