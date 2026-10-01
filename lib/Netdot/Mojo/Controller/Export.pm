package Netdot::Mojo::Controller::Export;

use Mojo::Base 'Mojolicious::Controller', -signatures;

use Netdot::Model;
use Netdot::Exporter;
use Netdot::Util::Log;
use Netdot::Mojo::Permissions;
use Log::Log4perl;

# All exporter types (original config_tasks.html order).
my @ALL_TYPES = qw(BIND NAMED RFC952 GIT PLAYBOOK UNILSTAT DHCPD Nagios Sysmon Rancid Smokeping Apache);
# Types available to anyone holding WRITE rights on DNS records (create/modify/delete
# on a Zone/RR). The remaining types (GIT/PLAYBOOK/UNILSTAT/Nagios/Sysmon/Rancid/
# Smokeping/Apache) are ADMIN-only.
my @WRITE_TYPES = qw(BIND NAMED RFC952 DHCPD);
my %WRITE_TYPE  = map { $_ => 1 } @WRITE_TYPES;
my $APPENDER    = 'mojo_export';

# HTML-escape.
sub _esc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    return $s;
}

# 403 unless the person holds write rights on DNS records (Permissions::can_export).
sub _guard {
    my ($c) = @_;
    return 0 if Netdot::Mojo::Permissions->can_export( $c->current_person );
    $c->render( template => 'error_403', layout => 'default', title => 'Access denied', status => 403 );
    return 1;
}

# Run the requested exporter types, capturing the exporter log in a String appender
# (mirrors htdocs/export/config_tasks.html). Returns ($log_text, \@errors).
sub _run {
    my ( $c, $f ) = @_;

    my $person = $c->current_person;
    my @types  = @{ $f->{types} };

    # Capture the exporter + DHCP loggers into a fresh String appender.
    my $logger      = Netdot->log->get_logger( 'Netdot::Exporter' );
    my $dhcp_logger = Netdot->log->get_logger( 'Netdot::Model::DHCP' );
    eval { Log::Log4perl->eradicate_appender( $APPENDER ) };
    my $logstr = Netdot::Util::Log->new_appender( 'String', name => $APPENDER );
    $logger->add_appender( $logstr );
    $dhcp_logger->add_appender( $logstr );

    my @errors;
    my %common = (
        person => {
            username => $person->username,
            name     => ( $person->firstname // '' ) . ' ' . ( $person->lastname // '' ),
            email    => $person->email,
        },
    );

    for my $type (@types) {
        my %args = %common;
        if ( $type eq 'BIND' ) {
            $args{zone_ids}     = [ @{ $f->{zones} } ] if @{ $f->{zones} };
            $args{force}        = 1 if $f->{bind_force};
            $args{nopriv_hinfo} = 1 if $f->{bind_no_priv_hinfo};
            $args{nopriv_txt}   = 1 if $f->{bind_no_priv_txt};
        }
        elsif ( $type eq 'DHCPD' ) {
            $args{force}  = 1 if $f->{dhcpd_force};
            $args{scopes} = [ @{ $f->{scopes} } ] if @{ $f->{scopes} };
        }
        # NAMED and RFC952 take no arguments (they process all active zones).
        my $err;
        eval {
            my $exporter = Netdot::Exporter->new( type => $type );
            $exporter->generate_configs( %args );
            1;
        } or $err = $@;
        push @errors, "$type: $err" if $err;
    }

    my $log = $logstr->string();
    eval { Log::Log4perl->eradicate_appender( $APPENDER ) };
    return ( $log, \@errors );
}

# GET  -> render the export form.
# POST -> run the selected exporters and re-render with the captured log.
sub index ($c) {
    return if _guard( $c );

    my @zones  = map { { id => $_->id, name => _esc( $_->name ) } } Zone->retrieve_all();
    my @scopes = map { _esc( $_->name ) } DhcpScope->search( type => 'global' );

    # Default (checked-by-default) state of the "exclude private data" checkboxes,
    # driven by config (mirrors the original Mason export page).
    my $def_hinfo = Netdot->config->get( 'CHECKBOX_CHECKED_EXCLUDE_HINFO_PRIVATE_DATA' ) == 1 ? 1 : 0;
    my $def_txt   = Netdot->config->get( 'CHECKBOX_CHECKED_EXCLUDE_TXT_PRIVATE_DATA' )   == 1 ? 1 : 0;

    # Which exporter types this user may run: Admins get all; other (write-rights)
    # users get the DNS + DHCP set only (see @WRITE_TYPES).
    my $is_admin = Netdot::Mojo::Permissions->user_type( $c->current_person ) eq 'Admin';
    my @types    = $is_admin ? @ALL_TYPES : @WRITE_TYPES;
    my %allowed  = map { $_ => 1 } @types;

    my ( $log, @errs );
    if ( $c->req->method eq 'POST' && $c->param( 'submit' ) ) {
        my @req = grep { defined && $_ ne '' } $c->param( 'config_types' );
        my @bad = grep { !$allowed{$_} } @req;
        my @ok  = grep {  $allowed{$_} } @req;
        push @errs, map { "Export type '$_' is not available for your user type." } @bad;
        if ( @ok ) {
            my ( $l, $e ) = _run( $c, {
                # Filter out empty values (an unselected multi-field can yield an empty
                # string; an empty zone id would make BIND throw "Zone  not found").
                types              => \@ok,
                zones              => [ grep { defined && $_ ne '' } $c->param( 'zones' ) ],
                scopes             => [ grep { defined && $_ ne '' } $c->param( 'scopes' ) ],
                bind_force         => $c->param( 'bind_force' ) ? 1 : 0,
                bind_no_priv_hinfo => $c->param( 'bind_no_priv_hinfo' ) ? 1 : 0,
                bind_no_priv_txt   => $c->param( 'bind_no_priv_txt' )   ? 1 : 0,
                dhcpd_force        => $c->param( 'dhcpd_force' ) ? 1 : 0,
            } );
            $log     = $l;
            push @errs, @$e;
        }
        push @errs, 'Please select an export type.' unless @req;
    }
    my $errors = @errs ? \@errs : undef;

    $c->render(
        template  => 'export',
        layout    => 'default',
        title     => 'Export Configurations',
        types     => \@types,
        zones     => \@zones,
        scopes    => \@scopes,
        log       => $log,
        errors    => $errors,
        def_hinfo => $def_hinfo,
        def_txt   => $def_txt,
    );
}

1;
