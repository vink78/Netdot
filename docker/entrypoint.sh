#!/bin/sh
# Netdot 2.0 container entrypoint.
#
#  1. Generate etc/Site.conf from the environment when the operator has
#     not provided one (a mounted or pre-existing Site.conf wins).
#  2. Wait for the database to accept TCP connections. The database and the
#     application account are pre-provisioned by the DBA; the entrypoint then
#     compares the schema version stored in the database to the application's
#     own version and, as the application account (non-interactive, credentials
#     from etc/Site.conf), either applies the schema + seed (first boot),
#     upgrades the schema (outdated version), or does nothing (up to date).
#  3. exec the Hypnotoad pre-fork server in the foreground (the container
#     main process), as the unprivileged `netdot' user.
#
# Supported database type: mysql (MariaDB) — the default. For anything
# else, mount a Site.conf yourself (it overlays etc/Default.conf, see
# lib/Netdot/Config.pm).
set -e

PREFIX=/usr/local/netdot
ETC=$PREFIX/etc

# Normalize the database coordinates (defaults match the template below).
# The database and the application account are pre-provisioned by the DBA;
# the application connects as the application account. The first-boot
# initializer also runs as that account, so the legacy DBA config keys are
# mapped to it (no separate DBA is needed or accepted).
DB_TYPE=${DB_TYPE:-mysql}
DB_HOST=${DB_HOST:-localhost}
DB_PORT=${DB_PORT:-3306}
DB_DATABASE=${DB_DATABASE:-netdot}
DB_NETDOT_USER=${DB_NETDOT_USER:-netdot_user}
DB_NETDOT_PASS=${DB_NETDOT_PASS:-netdot_pass}
DB_DBA=${DB_NETDOT_USER}
DB_DBA_PASSWORD=${DB_NETDOT_PASS}
export DB_TYPE DB_HOST DB_PORT DB_DBA DB_DBA_PASSWORD DB_DATABASE DB_NETDOT_USER DB_NETDOT_PASS

# --- 1) Site.conf overlay (only when absent) ------------------------------
if [ ! -f "$ETC/Site.conf" ]; then
    sed -e "s|<<DB_TYPE>>|$DB_TYPE|g" \
        -e "s|<<DB_HOST>>|$DB_HOST|g" \
        -e "s|<<DB_PORT>>|$DB_PORT|g" \
        -e "s|<<DB_DBA>>|$DB_DBA|g" \
        -e "s|<<DB_DBA_PASSWORD>>|$DB_DBA_PASSWORD|g" \
        -e "s|<<DB_DATABASE>>|$DB_DATABASE|g" \
        -e "s|<<DB_NETDOT_USER>>|$DB_NETDOT_USER|g" \
        -e "s|<<DB_NETDOT_PASS>>|$DB_NETDOT_PASS|g" \
        /etc/netdot/Site.conf.template > "$ETC/Site.conf"
    echo "netdot: generated $ETC/Site.conf from the environment"
fi

# `initdb` expects its cwd to be bin/ (use lib "../lib", DBUTIL uses
# "../etc" for the config directory).
cd "$PREFIX/bin"

# --- 2a) Wait for the DB server to accept TCP connections (no auth) -------
# Probing the port (not an account) keeps this environment-agnostic: it
# works against a fresh database, an existing one, or an external server.
n=0
until perl -MIO::Socket::INET -e '
    exit(IO::Socket::INET->new(PeerAddr => "$ENV{DB_HOST}:$ENV{DB_PORT}",
        Proto => "tcp", Timeout => 5) ? 0 : 1)';
do
    n=$((n + 1))
    if [ $n -ge 30 ]; then
        echo "netdot: database $DB_HOST:$DB_PORT still unreachable after 150s" >&2
        exit 1
    fi
    echo "netdot: waiting for database $DB_HOST:$DB_PORT ..."
    sleep 5
done

# --- 2b) Schema initialization / upgrade ------------------------------------
# The database and the application account are pre-provisioned by the DBA, so
# the app account is expected to connect. The entrypoint reads the schema
# version stored in `schemainfo` and, compared to the application's own
# version, either applies the schema + seed (first boot: no version yet),
# upgrades the schema (stored version is outdated), or does nothing (up to
# date). The probe prints the stored version, or "error" / "none".
NETDOT_SCHEMA_VERSION=$(perl -ne 'print $1 if /our \$VERSION = "([^"]+)"/' "$PREFIX/lib/Netdot.pm")
[ -n "$NETDOT_SCHEMA_VERSION" ] || { echo "netdot: ERROR: cannot determine the application schema version" >&2; exit 1; }
set +e
DB_SCHEMA_VERSION=$(perl -MDBI -e '
    # RaiseError must stay 0 here: modern DBI applies the connect attributes
    # to the connect call itself, so a failing connect would die (and print
    # nothing to stdout) instead of returning undef.
    my $dbh = DBI->connect("dbi:mysql:$ENV{DB_DATABASE};host=$ENV{DB_HOST};port=$ENV{DB_PORT}",
        $ENV{DB_NETDOT_USER}, $ENV{DB_NETDOT_PASS},
        { PrintError => 0, RaiseError => 0 })
        or do { print "error"; exit 0; };
    my $v = eval { $dbh->{RaiseError} = 1;
                   $dbh->selectrow_array("SELECT version FROM schemainfo WHERE id=1") };
    print(defined $v && $v ne "" ? $v : "none");' 2>/dev/null)
set -e
case "$DB_SCHEMA_VERSION" in
    error)
        echo "netdot: ERROR: cannot connect to database '$DB_DATABASE' as '$DB_NETDOT_USER'." >&2
        echo "netdot: the database and the application account must be pre-provisioned by the DBA." >&2
        exit 1
        ;;
    none)
        echo "netdot: first boot -- applying the schema"
        perl initdb initschema
        ;;
    *)
        if [ "$DB_SCHEMA_VERSION" = "$NETDOT_SCHEMA_VERSION" ]; then
            echo "netdot: database schema up to date ($DB_SCHEMA_VERSION)"
        else
            echo "netdot: upgrading schema from $DB_SCHEMA_VERSION to $NETDOT_SCHEMA_VERSION"
            ( cd "$PREFIX/upgrade" && perl updatedb )
            ( cd "$PREFIX/upgrade" && perl upgrade-tasks "$PREFIX" )
        fi
        ;;
esac

# --- 3) The server (foreground, unprivileged) ------------------------------
install -d -o netdot -g netdot -m 750 "$PREFIX/tmp/sessions"
export NETDOT_LISTEN="${NETDOT_LISTEN:-http://0.0.0.0:3000}"
export NETDOT_WORKERS="${NETDOT_WORKERS:-4}"
export NETDOT_PID_FILE="$PREFIX/tmp/hypnotoad.pid"
exec setpriv --reuid=1000 --regid=1000 --clear-groups \
    perl /usr/bin/hypnotoad -f "$PREFIX/bin/mojo"
