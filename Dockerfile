# Netdot 2.0 — application image (Debian 13 "trixie" slim).
#
# Builds the application from the directory that contains this Dockerfile
# (the build context — the current working tree) via `make install`. Tag
# the image after the commit you build from, so each test build is
# traceable and you never need a git tag per commit:
#
#   V=v2.0.0-dev-$(git rev-parse --short HEAD)
#   docker build --build-arg NETDOT_VERSION=$V -t netdot:$V .
#
# Note: the image is built from the working tree, so uncommitted changes
# are included too — this is the simple path for iterating on the in-
# progress 2.0 work. For a public release, build from the sanitized
# public repository instead.
#
# The image runs the application only: the Hypnotoad pre-fork server,
# listening on 0.0.0.0:3000 by default (put a load balancer / ingress in
# front — there is no reverse proxy inside the image). The database is
# external: docker-compose.yml ships a companion MariaDB container, and
# the Helm chart (helm/netdot) targets any reachable MySQL/MariaDB.
#
# The entrypoint is version-aware: it compares the schema version stored in
# the `schemainfo` table to the application's own version and, as the
# pre-provisioned application account, either applies the schema + seed data
# (`bin/initdb initschema`, first boot), runs the upgrade
# (`upgrade/updatedb`, outdated version), or does nothing (up to date).

# ---- Vendor MIBs for SNMP discovery (netdisco-mibs, same source as the
# ---- apt-install step of bin/perldeps.pl) ------------------------------
# Strip the top-level dot-entries (.git, .github, ...) before copying so
# only the MIB data lands in the image (~300 Mo; the shallow .git alone is
# ~38 Mo and would otherwise be baked in).
FROM debian:trixie-slim AS mibs
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates git \
    && git clone --depth 1 https://github.com/netdisco/netdisco-mibs /tmp/netdisco-mibs \
    && find /tmp/netdisco-mibs -mindepth 1 -maxdepth 1 -name '.*' \
         -exec rm -rf {} + \
    && mkdir -p /usr/local/netdisco/mibs \
    && cp -r /tmp/netdisco-mibs/. /usr/local/netdisco/mibs/ \
    && rm -rf /tmp/netdisco-mibs \
    && apt-get purge -y --auto-remove git \
    && rm -rf /var/lib/apt/lists/*

# ---- Build the application from the build context (working tree) --------
FROM debian:trixie-slim AS build
ENV DEBIAN_FRONTEND=noninteractive
# The Makefile `dir` target chowns tmp/ to $(APACHEUSER):$(APACHEGROUP);
# a dedicated `netdot` user stands in for the Apache user of a system
# install.
RUN groupadd --system --gid 1000 netdot \
    && useradd --system --uid 1000 --gid netdot --home-dir /nonexistent \
        --shell /usr/sbin/nologin netdot
# make + rrdtool are the only install-time tools needed: the sub-Makefiles
# are pure sed/copy (no Perl), and var/Makefile creates var/pollstats.rrd
# with rrdtool when it is missing.
RUN apt-get update && apt-get install -y --no-install-recommends \
        make rrdtool \
    && rm -rf /var/lib/apt/lists/*
# Install the working tree to /usr/local/netdot (PREFIX default); the
# sub-Makefiles substitute the <<Make:...>> markers in the installed
# Default.conf.
COPY . /src/netdot
RUN cd /src/netdot \
    && make install APACHEUSER=netdot APACHEGROUP=netdot \
    && cp -r upgrade /usr/local/netdot/upgrade \
    && if [ ! -s /usr/local/netdot/etc/Site.conf ]; then \
         rm -f /usr/local/netdot/etc/Site.conf; \
       fi \
    && rm -rf /src/netdot

# ---- Runtime image --------------------------------------------------------
FROM debian:trixie-slim

# Optional: embed the version/commit for traceability (set at build time,
# see the header). Empty when not provided.
ARG NETDOT_VERSION=
LABEL netdot.version="${NETDOT_VERSION}"

ENV DEBIAN_FRONTEND=noninteractive \
    # Container default: listen on all interfaces (a reverse proxy on a
    # bare-metal install would use http://127.0.0.1:3000).
    NETDOT_LISTEN=http://0.0.0.0:3000 \
    NETDOT_WORKERS=4

# Runtime Perl and system packages (bin/perldeps.pl @DEPS, apt column,
# MySQL flavour). Every dependency comes from a distribution package —
# there is no compiler in the image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        perl ca-certificates \
        libmojolicious-perl libcrypt-urandom-perl libjson-perl \
        libnet-ldap-perl libyaml-libyaml-perl \
        rrdtool librrds-perl graphviz libgraphviz-perl \
        libmodule-build-perl libcgi-pm-perl libclass-dbi-perl \
        libclass-dbi-abstractsearch-perl liburi-perl \
        libsql-translator-perl libsnmp-info-perl libnetaddr-ip-perl \
        liblog-dispatch-perl liblog-log4perl-perl \
        libparallel-forkmanager-perl libnet-patricia-perl \
        libtest-simple-perl libtest-exception-perl libnet-irr-perl \
        libtime-local-perl libfile-spec-perl \
        libnet-appliance-session-perl libbind-config-parser-perl \
        libnet-dns-perl libcarp-assert-perl libdigest-sha-perl \
        libsocket6-perl libxml-simple-perl snmp \
        libexception-class-perl libwww-perl libxml-libxml-perl \
        libanyevent-perl libcoro-perl libtimedate-perl \
        libdbd-mysql-perl libdata-dump-perl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid 1000 netdot \
    && useradd --system --uid 1000 --gid netdot --home-dir /nonexistent \
        --shell /usr/sbin/nologin netdot

COPY --from=mibs  /usr/local/netdisco     /usr/local/netdisco
COPY --from=build /usr/local/netdot       /usr/local/netdot
COPY docker/Site.conf.template /etc/netdot/Site.conf.template
COPY docker/entrypoint.sh      /usr/local/bin/netdot-entrypoint.sh

# The entrypoint runs as root to (possibly) generate etc/Site.conf, then
# drops to the `netdot' user for the server itself.
RUN chmod 0755 /usr/local/bin/netdot-entrypoint.sh \
    && chown -R netdot:netdot /usr/local/netdot/tmp /usr/local/netdot/var \
       /usr/local/netdot/import /usr/local/netdot/export

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD perl -MHTTP::Tiny -e 'exit(HTTP::Tiny->new->get("http://127.0.0.1:3000/login")->{status} < 400 ? 0 : 1)'
ENTRYPOINT ["/usr/local/bin/netdot-entrypoint.sh"]
