# Netdot Documentation Tool 2.0

Netdot is an open source tool designed to help network administrators collect, organize and maintain network documentation.

Netdot 2.0 is a rewrite of the Web UI and the API, carried out in *Vibe Coding* mode (human + AI), to bring back to life one of the best open source products for managing a network infrastructure.

Netdot was initially developed at the University of Oregon and continues to be maintained and expanded with support from volunteers.

Features include:

### Original features

* Device discovery via SNMP
* Layer2 topology discovery using:
  * CDP/LLDP
  * Spanning Tree Protocol
  * Switch forwarding tables
  * Router point-to-point subnets
* IPv4 and IPv6 address space management (IPAM)
* Address space visualization
* DNS zone file generation (BIND)
* ISC DHCPD config generation
* IP and MAC address tracking
* BGP peer and Autonomous Systems tracking
* Cable plant (sites, fiber, copper, closets, circuits...)
* Contacts (departments, providers, vendors, etc.)
* Export scripts for various monitoring tools (Nagios, Sysmon, RANCID, Cacti, SmokePing)
* Multi-level user access: Admin, Operator, User

### New features (2.0)

* Web UI and API rewritten in [Mojolicious](https://mojolicious.org) (multi-worker
  under Hypnotoad), replacing the legacy Apache/mod_perl + Mason layer
* JSON REST API (`/api`) for **all** CRUD operations, with per-resource
  permissions and Netbox-style pagination
* OpenAPI 3 specification + Swagger UI (`/api/openapi.yaml`, `/api/docs`)
* Prometheus file-based service discovery inventory (`/api/prometheus`)
* Modern flat UI with in-place editing on list and detail pages
* Changelog (audit trail) and global search (IP / MAC / hostname)
* Server-side flat-file sessions (opaque random-id cookie, multi-worker safe)
* Deployment behind a reverse proxy under a URL prefix (e.g. `/netdot`)

### Dropped features

* Cable plant **wiring and circuits** (`backbonecable`, `horizontalcable`,
  `circuit`) — deprecated; a dedicated product such as Netbox is a better
  fit for cable/circuit management
* Kerberos and RADIUS web authentication (legacy mod_perl configs) —
  authentication now lives in the app (LDAP or local accounts)
* Interactive IP allocation (`choose_ip`)

## Documentation

Read the Manual in [pdf](https://github.com/cvicente/Netdot/blob/master/doc/manual/netdot-manual.pdf) or [html](http://htmlpreview.github.io/?https://github.com/cvicente/Netdot/blob/master/doc/manual/netdot-manual.html)

## Contributing

When contributing to this repository, please first discuss the change you wish to make via issue, email, or any other method with the owners of this repository before making a change.

The most effective way to submit changes is to issue a Github pull request.

## Authors

[Carlos Vicente](https://github.com/cvicente)

Also see [Contributors](https://github.com/cvicente/Netdot/blob/master/CONTRIBUTORS)

## License

This project is licensed under the [GPL](https://github.com/cvicente/Netdot/blob/master/gpl.txt)

## Acknowledgments

* The University of Oregon and the Network Startup Resource Center (NSRC)
* All the individuals who contributed patches, ideas, suggestions and feedback.

Like us on [Facebook](http://www.facebook.com/NetdotTool)