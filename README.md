# Netdot 2.0

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](gpl.txt)

**Netdot is an open source network documentation tool** — it discovers
your layer-2 fabric automatically, manages the IP address space, and
generates the configuration your network runs on (DNS zones, DHCP
config, monitoring inventories).

Netdot was initially developed at the University of Oregon and has been
maintained and expanded by volunteers. **Netdot 2.0** is a complete
rewrite of the web layer and the API, carried out in *vibe coding* mode
(human + AI), bringing the project to a modern stack while keeping the
discovery and IPAM engine that made it legendary:

* **HTML::Mason is completely gone.** The legacy monolithic web layer
  (Apache + mod_perl + Mason) was replaced by a
  [Mojolicious](https://mojolicious.org) application, running
  multi-worker under Hypnotoad.
* **API-first, JSON only.** Every write operation (POST / PATCH /
  DELETE) goes through a decoupled JSON API; the web UI is a pure
  client of it.
* **NetDevOps-ready.** An OpenAPI 3 specification documents the whole
  API surface, and a Prometheus endpoint exposes the inventory for
  service discovery.

## What Netdot does

* **Discovery** — zero-touch documentation of your fabric:
  * devices via SNMP
  * layer-2 topology via CDP/LLDP, Spanning Tree Protocol, switch
    forwarding tables and router point-to-point subnets
* **IPAM** — IPv4 and IPv6 address space management and visualization
* **Generation** — BIND DNS zone files, ISC DHCPD configuration, and
  export scripts for Nagios, Sysmon, RANCID, Cacti and SmokePing
* **Inventory** — IP and MAC address tracking, BGP peers and Autonomous
  Systems, cable plant (sites, floors, rooms and closets), contacts
  (departments, providers, vendors)
* **Access control** — multi-level roles: Admin, Operator, User

### New in 2.0

* Modern flat web UI with in-place editing on list and detail pages, an
  audit trail (Changelog) and global search (IP / MAC / hostname)
* JSON API for **all** CRUD operations, with per-resource permissions
  and Netbox-style pagination
* OpenAPI 3 specification + Swagger UI (`/api/openapi.yaml`,
  `/api/docs`)
* Prometheus file-based service discovery inventory (`/api/prometheus`)
* Modern DNS record types (CAA, HTTPS, SSHFP, SMIMEA, SVCB, TLSA, URI)
  as "Other Record Types" — stored as raw values and exported to zone
  files unchanged
* Server-side flat-file sessions (opaque random-id cookie,
  multi-worker safe) and deployment behind a reverse proxy under a URL
  prefix (e.g. `/netdot`)

### Dropped in 2.0

* Cable plant **wiring and circuits** (`backbonecable`,
  `horizontalcable`, `circuit`) — deprecated; a dedicated product such
  as Netbox is a better fit for cable/circuit management
* Kerberos and RADIUS web authentication (legacy mod_perl configs) —
  authentication now lives in the app (LDAP or local accounts)
* Interactive IP allocation (`choose_ip`) and the ad-hoc database
  access of the Advanced menu (generic Browse / custom SQL queries) —
  replaced by the Changelog (audit trail); the equivalent operations
  remain available through the JSON API
* The legacy XML interface — replaced by the JSON API (no CPAN client
  for the new API yet)

## Getting started

Requirements: a recent Perl (5.38+) and MariaDB or MySQL. Tested
end-to-end on Debian 13.

```bash
~# apt-get install build-essential
~# git clone https://github.com/vink78/Netdot.git
~# cd Netdot
~# make apt-install            # RPM systems: make rpm-install
~# make testdeps               # report missing Perl modules, if any
~# make installdeps
~# cp etc/Default.conf etc/Site.conf    # then customize
~# make installdb              # initialize the database
~# make install
~# systemctl restart netdot
```

The [manual](doc/manual/netdot-manual.pdf) covers the complete setup:
database preparation, configuration items, first login and operation.

## The JSON API

The JSON API is the single write path of the application and the
preferred interface for automation and CI:

* `GET /api/openapi.yaml` — OpenAPI 3 specification
  (see also [api/openapi.yaml](api/openapi.yaml) in this repository)
* `GET /api/docs` — Swagger UI
* `GET /api/prometheus` — Prometheus file-based service discovery
* All CRUD operations, with per-resource permissions and Netbox-style
  pagination

## Documentation

[Manual (2.0), PDF](doc/manual/netdot-manual.pdf) ·
[HTML](doc/manual/netdot-manual.html)

## Contributing

When contributing to this repository, please first discuss the change
you wish to make via issue, email, or any other method with the owners
of this repository before making a change.

The most effective way to submit changes is to issue a GitHub pull
request.

## Authors

[Carlos Vicente](https://github.com/cvicente)

Also see [Contributors](CONTRIBUTORS).

## License

This project is licensed under the [GPL v3](gpl.txt). All files
without an explicit license notice are released under the same
license.

## Acknowledgments

* The University of Oregon and the Network Startup Resource Center (NSRC)
* All the individuals who contributed patches, ideas, suggestions and
  feedback.
