# Netdot → Mojolicious: porting notes

Goal: port the Netdot web app (Apache/mod_perl + Mason `.mhtml`) to
**Mojolicious**, reusing `Netdot::Model`. Port type by type,
**read-only** controllers first.

## Stack / environment
- Perl 5.40.1 + Mojolicious 9.39.
- **mysql DB** (see `etc/Site.conf`).
- LDAP auth + local fallback.
- Git branch `dev`. The user commits at each step.
  **Never commit/push without being asked.**

## Validation workflow
- Syntax: `perl -c -Ilib` on each modified perl file.
- E2E test:
  `bin/mojo daemon -l http://127.0.0.1:8899 -m development &` → kill by port.
  Login: `curl -c ck.txt -d "username=<user>&password=<pass>" /login` (302).
- Bare-`-e`: `use Netdot::Model` loads config+DB; but the RR* classes
  (RRMX, RRNS, …) only load via the RR relations.
- At each step: verify the target page (200, content present) **and** a
  regression (the type's list + one generic type).

## Target architecture
- **One dedicated controller per major type** (`Controller/Ipblock.pm`,
  `Controller/Rr.pm`, …), action `show`. The generic detail stays in
  `Controller/Show.pm`.
- `lib/Netdot/Mojo.pm`: route `/management/<type>/<id>`, dispatch map
   `my %show_ctrl = ( ipblock => 'ipblock', rr => 'rr' );` → dedicated controller if
   present, else `show#show` (generic). Adding a type = one entry in the
   map + one `Controller/<Type>.pm`.
- **Route paths**: list = `/management/<type>` (route *name* `<type>_list`),
   search = `/management/<type>/search`, detail = `/management/<type>/<id>`.
   `<type>_list` is the route NAME (for `url_for`/`redirect_to`), NOT a path —
   hitting `/management/<type>_list` 404s.
- Template per type: `htdocs/management/<type>.html.ep`.
- Root/breadcrumb pages are rendered by `Browse#list`; they do NOT expose the
  detail-page variables (e.g. `$block_attrs`) → hence the preamble rule below.
- **Base path `/netdot`**: the app is mounted under a configurable prefix —
  `WEB_BASE_URL` in `etc/Site.conf` is a **bare path** (e.g. `/netdot`), host-agnostic
  so dev and prod share one value. All routes are wrapped in `->under($base)`;
  static assets (`css|img|java_script`) are served under the prefix; `before_dispatch`,
  the nav builder, and the `web_prefix()` helper are prefix-aware. `url_for` picks the
  prefix up automatically (routes are under it) — only a handful of hard-coded template
  links use `$c->web_prefix`. The reverse proxy must **preserve** the prefix:
  `ProxyPass /netdot → http://127.0.0.1:3000/netdot` (nginx: `location /netdot/
  { proxy_pass http://127.0.0.1:3000; }` **without a trailing slash**). Dev =
  `http://127.0.0.1:3000/netdot/`. The JSON API lives under the same prefix (`/netdot/api`).

## Pitfalls (critical)

### 1. CDBI + `wantarray`
`eval { $class->search(...) } // ()` degrades `wantarray`: the **CDBI
iterators** (returned by `->children` AND by `->search()`) are then stringified
at the first `@{ }` / `->first` → `[eval ...] is not an ARRAY reference`.
- Never wrap a CDBI call that iterates in `// ()`.
- Iterate the iterator explicitly (`$it = $obj->children; while ($c = $it->next)`)
  ; local helper `_search_all($class, ...)` = `my $r=$c->search(...); my @out;
  while (my $o=$r->next){push @out,$o} @out` when an array is expected.
- **`->search_like(...)` (PhysAddr) also returns an iterator** → same rule:
  `my $it = $class->search_like(...); while (my $o=$it->next){...}`. Never
  `eval { $class->search_like(...) } // ()` (yields 1 element = the iterator,
  `->id` then fails). Plain list context (`my @r = $class->search_like(...)`)
  expands fine — it is the `eval{ } // ()` that breaks it.
- **Same trap on relation methods** (`->devices`, `->interfaces`, `->dhcp_hosts`,
  …) : `my @x = eval { $o->rel } // ()` degrades wantarray → 1 iterator/count
  (renders as `Iterator#0` / a bare number). Correct form:
  `my @x; eval { @x = $o->rel };` (list context preserved inside the eval).

### 2. Templates `.ep`
- **Preamble**: every stash variable used in the body must be declared
  `my $x = $c->stash->{x} // default;`. A var missing from the stash →
  `strict` error "requires explicit package name".
- `% if/else`, `% for { <tr> }` **on a single line DO NOT compile** → multi-line.
- `esc` does not exist in the controller Perl code (it's a template helper) →
  local helper `_esc` (`s/([&<>"])/\u$1/ge`) or `escape()` in `.ep`.
- `esc()` in `.ep` escapes HTML; for already-formatted HTML (grid,
  percent_bar) use `==` (`<%== $var %>`).
- **Cache**: Mojolicious caches templates **compiled in memory** in the
  process → after editing a `.ep`, **restart the daemon** (and hard-refresh the
  browser), otherwise the old version is served.
- **Code** comments are in **English** (international project).

### 2b. Mojolicious helper gotchas
- **Permission helper is named `perm`** (NOT `can`): `can` clashes with
  `UNIVERSAL::can`, which Mojolicious uses for dispatch resolution. Always
  call `$c->perm('view', 'Device')`, never `$c->can(...)`.
- **2-arg stash**: `$c->stash('key', $value)` is the correct form.
  `$c->stash(key => $value)` (named-arg form) does NOT work in Mojolicious.
- **String appender for log capture** (Export): `Log::Log4perl::Logger->get_logger`
  + a `Log::Log4perl::Appender::String` appender captures the exporter's log
  output into a variable for display in the template.

### 2c. System `Mojo::Parameters` is patched (`names` returns an arrayref)
The system `/usr/share/perl5/Mojo/Parameters.pm` is **patched**: `names` was
replaced with `sub names { [sort keys %{shift->to_hash}] }`, so it returns an
**arrayref** (sorted, deduped) instead of a list.
- Never `for my $k ( $c->req->params->names )` → it loops once with the
  arrayref as `$k`, so the hash key becomes the string `"ARRAY(0x..)"` and every
  real param is lost.
- Use `$c->req->params->to_hash` (unpatched; hashref, last value per key) or
  `$c->param($name)` directly.
- This silently broke `_args()` (hence the generic search + host endpoints):
  `?address=…` was dropped → `host` fell into its "retrieve ALL RRs" branch →
  the request looked like a "hang" (173k records + per-record expansion).

### 2d. Relations passed as function args evaluate in **list context**
`_list( $obj->rel )` (and any helper) evaluates `$obj->rel` in **list context**
→ the FULL list of related objects arrives as a flat list, NOT an iterator. A
helper doing `my $x = shift` keeps only the **first** element and silently drops
the rest.
- `_list` / `_first` must consume all of `@_` and branch: single iterator
  (`can('next')`) → drain it; single arrayref → deref; else return `@_` as-is
  (flat list, possibly empty).
- Symptom: a relation with >1 element returned only the first (an IP with two A
  records returned one RR). Scalar context (`my $it = $obj->rel`) yields a CDBI
   iterator instead — both forms are valid, so the helper must accept both.

### 2e. `Permissions::can` is a function called in a **method-call shape**
`Netdot::Mojo::Permissions::can($class, $person, $action, $resource)` is a plain
function, but the codebase calls it **as a method**: `Permissions->can($person,
'action', $obj)` — the invocant fills the `$class` slot, so the real args line up as
`($person, $action, $resource)`. Passing the class name as an **extra** first arg
(`Permissions->can("Zone", $p, "edit", $z)`) shifts everything by one, so `$person`
becomes a **string** → `return 0` (a silent deny). Same shape for `user_type`,
`has_action`, `viewable_predicate`. When debugging a `can` result, call the internal
`_denies_object($type, $username, $action, $obj, $access)` directly to isolate the rule
from the arg-shifting.

### 3. Models
- `Registry::link_for($obj)` returns an **arrayref** `[text, href]` →
  dereference with `@{ }`. Generates `/management/<type>/<id>` for any type
  registered in `lib/Netdot/Mojo/Registry.pm` (`%TYPES`, `@ORDER`).
- FK objects stringify to their **id** → use `->name`, `->get_label`,
  `->format_address`, or `Registry::link_for`.
- **Registry (`lib/Netdot/Mojo/Registry.pm`)**: `%TYPES` minimal =
  `{ class, [nav=>0], [label] }`. `label` (meta name), `desc` (meta description)
  and `cols` (brief view) are **derived** from the meta via `spec()` (memoized) →
  `netdot.meta` = single source of truth. `display_columns($class)` = the
  `all` view + tags (generic detail). `nav=>0` = a linksto object (routable +
  generic detail, hidden from the nav). The FK "object" targets (Product,
  Availability, Circuit, ArpCache, SiteLink, FWTable, STPInstance,
  HorizontalCable, BackboneCable, DhcpScope) are registered so `link_for`
  links them.
- **`get_column_order(view=>…)` / `get_column_order_brief()`** return a
  **hash** column→position → call in list context:
  `eval { %o = $m->get_column_order_brief(); 1 }` then
  `sort { $o{$a}<=>$o{$b} } keys %o` (else `wantarray` is degraded).
- **Generic detail title**: `$obj->get_label` (built from
  `label => [...]` in `netdot.meta`), fallback `Type #id`.
- FK of the "domain name → RR" type: resolve with `RR->search({name=>...})`
  (helper `_name_link`).
- Dates: hide null/empty values (`_dt_ok`).

### 4. Container grid (port of Mason `container.mhtml`)
- Unit base = **/32** (not /28), otherwise finer children (e.g. /29)
  get a fractional width (0.5) that breaks the grid.
- `cellsperrow = (rowsize>=22) ? 1024 : 2**(32-rowsize)`; cell width =
  `(2**(32-prefix)) * (2**(rowsize-22))` px. 1 row = 1 /rowsize block.
- v6 not supported (message). Links `/management/ipblock/<id>`.

## Mason → Mojolicious reference
- Generic view of a record: `htdocs/generic/view.html?table=X&id=Y`.
- Port a type: take the Mason page (`htdocs/management/*.mhtml`) and its
  helpers, adapt to a dedicated controller + `.ep`.
- Field-link mechanics: `lib/Netdot/UI.pm` (`form_field`/
  `add_to_fields`, `linkPage`/`linkpages`). NS/MX/TXT/NAPTR → `view.html`
  (record view); PTR → `host.html` (host view).
- Styles: `htdocs/css/style.css` (`.ipaddr_*`, `.ipcontainertable`,
  `.tablescroll`, `.container*`, `.progress_bar`).
- **Permission / rights-inheritance (original, still in the tree)**: the logic lives in
  `lib/Netdot/ObjectAccessRule.pm` (`denies()` — per-object rule + inheritance), composed by
  `lib/Netdot/NetdotPermissionFactory.pm` (`GrantAllRule` default-allow + `SectionAccessRule`
  + `ObjectAccessRule`), with base rights from `lib/Netdot/Model/Person.pm`
  `get_allowed_objects` (tables `accessright`/`groupright`/`userright` via contact lists).
  `lib/Netdot/Mojo/Permissions.pm` is a direct port of this.

## Key files
- `lib/Netdot/Mojo/Controller/Ipblock.pm` — block detail (show + helpers
  `_block_attributes`, grid, sites/zones/dhcp/attrs/arp/audit) + search.
- `lib/Netdot/Mojo/Controller/Rr.pm` — host detail (show + `_rr_attributes`,
  `_rr_sections`, `_search_all`, `_name_link`, `_obj_link`) + search.
 - `lib/Netdot/Mojo/Controller/Show.pm` — generic detail (most types): attrs
   (all view) + **has_many tables** (from `meta_data->get_links_from`, like
   Mason `view.html`): one table per non-empty relation, brief columns (label
   columns excluded from the brief set), 1st column = object label linked to its
   detail page, rows capped at config `DEFAULT_PERPAGE` (50). NOTE: `get_links_from`
   returns a **hash** and `get_labels` a **list** → use `my %h; eval { %h = ... }` /
   `my @l; eval { @l = ... }` (the `eval {...} || ()` wantarray trap breaks both).
    `Browse#list` page size also comes from `DEFAULT_PERPAGE`.
 - `lib/Netdot/Mojo/Detail.pm` — shared builders used by Show + the dedicated
   detail controllers: `build_attrs` (all-view attrs, FK→link), `build_relations`
   (has_many tables, paginated), `rel_columns`, `obj_text`.
 - `lib/Netdot/Mojo/Controller/Zone.pm` — Zone detail (port of
   `management/zone.html`): record count (per type), apex record (A/NS/MX with
   links), generic has_many (subnets/records/aliases), recent changes (HostAudit).
 - `lib/Netdot/Mojo/Controller/Contactlist.pm` — ContactList detail (port of
   `generic/contactlist.html`): **contacts** rendered as a dedicated table (role
   sorted by person label: Person link + contacttype + notify_email/pager/voice
   + escalation_level), other has_many as generic tables (`contacts` excluded).
 - `lib/Netdot/Mojo/Controller/Closet.pm` — Closet detail (port of
   `cable_plant/closet.html`): curated two-column info + `info`, Device List
   (room→floor→site), Backbone Cable (start+end merged), Horizontal Cable
   (read-only; cable names plain text, no deep link to deprecated pages).
- `lib/Netdot/Mojo/Controller/Browse.pm` — generic list (all types): `%FILTERS`
  per-type filter whitelist, `search_like()` re-application, FK links via
  `Registry::column_link_key`/`esc`, CSV export, batch delete.
- `lib/Netdot/Mojo/Controller/Reports.pm` — all 10 reports: `_obj_html`,
  `_normalize_rows`, `_skey`, per-report row builders, CSV export.
- `lib/Netdot/Mojo/Controller/Export.pm` — Export form (GET) + run (POST):
  type-gating (Admin→12, write-rights→4), `generate_configs`, String appender
  log capture, per-type error list.
- `lib/Netdot/Mojo/Controller/Advanced.pm` — Changelog: raw SQL on `audit`
  (`SELECT COUNT(*)` + `SELECT … ORDER BY tstamp DESC LIMIT ? OFFSET ?`), `search`
  (LIKE on `label`) + `operation` filter + `offset` pagination, and a **permission
  filter** (Admin/Operator see all; otherwise `username = <self>`).
- `lib/Netdot/Mojo/Controller/Search.pm` — Global search: IPv4/IPv6 → redirect
  ipblock search; MAC → redirect physaddr search; text → `RR->search_like(name)`.
- `lib/Netdot/Mojo/Registry.pm` — type catalogue, `link_for`, `format_value`,
  `spec`, `display_columns`, `is_sensitive`, `csv_field`, `column_link_key`,
  `esc`, `%MENU` + `@MENU_ORDER` (5 sections incl. Export).
- `lib/Netdot/Mojo/Permissions.pm` — `user_type`, `can`, `allowed_objects`,
  `viewable_predicate` (SQL `WHERE` fragment for list filtering), `has_action_on`,
  `has_action`, `can_export` (write rights on RR). **Faithful port of the original
  Apache2::SiteControl permission system**:
  `can()` = the rule composition of `lib/Netdot/NetdotPermissionFactory.pm`
  (`GrantAllRule` default-allow → `SectionAccessRule` → `ObjectAccessRule`);
  `allowed_objects()` = `Person->get_allowed_objects` (LOCAL: `groupright`/`userright`/
  `accessright` via contact lists); `_denies_object()` = `ObjectAccessRule::denies` —
  the full **inheritance**: **Zone→RR** (sub-types via parent `rr`), **Device→Interface**,
  **ContactList→Contact/Person (roles)**, **parent Ipblock→IpblockAttr**, **Ipblock
  ancestor chain** (`_deny_ip_access` via `get_ancestors`), RR→IP fallback, plus the special
  denials (zone apex delete, NS records, device-linked RRs).
- `lib/Netdot/Mojo.pm` — app, routes (mounted under the `WEB_BASE_URL` prefix via
  `->under($base)`), `before_dispatch` auth hook (redirects HTML to `/login`, exempts
  `/api`, and **sets `$ENV{REMOTE_USER}` from the session user** so `Model::_audit`
  records web/API writes — the old Apache layer provided this), `before_render` nav hook,
  `web_prefix` helper, `deny_unless` helper, `api_json_err` + path-aware
  `reply.{html,json}_{not_found,method_not_allowed,exception}` (JSON errors under
  `/api`, branded HTML elsewhere).
- `lib/Netdot/Mojo/Api.pm` — JSON API serializer (port of `Netdot::REST::get`):
  `get($obj,$user,$manager,%opts)` (FK→label + `_xlink`, `depth`, `linked_from`),
  `Netdot::Mojo::Api::Error` (code+msg). No Apache dependency.
- `lib/Netdot/Mojo/Controller/Api.pm` — JSON API controller: `generic` (GET list +
  object, POST/PATCH/PUT, DELETE per table) with **per-verb permission checks** —
  GET `can('view')`, update `can('edit')`, DELETE `can('delete')`, create `_can_create`
  (per-parent: `zone`/`rr`/`device`/`contactlist` FK; see `_create_parent`) — and
  **Netbox pagination** (`limit`/`offset` → `{count,next,previous,results}` via
  `Model::search_count`/`search_page`); purpose-built `devinfo`/`host_contacts`/`ipattr`/
  `host`/`host_like`/`updatedev`. `_host_post`: create on a **new** IP = subnet
  `can('edit'/'choose_ip')` + `RR->add_host`; create on an **existing** IP = insert an
  **RRADDR** (no allocation) allowed iff `can('edit',$zone)` AND `can('edit',$ip)`.
  Also `root` (GET `/api` Netbox-style flat index), `spec` (`/api/openapi.yaml`),
  `docs` (Swagger UI, standalone).
- `lib/Netdot/Mojo/OpenAPI.pm` — `build_spec()`: OpenAPI 3.0.3 from `Netdot->meta`
  (88 typed schemas + per-table paths + dedicated endpoints); `servers` from the
  `WEB_BASE_URL` prefix.
- `api/gen_openapi.pl` — regenerator → `api/openapi.yaml` (re-run after model/spec changes).
- `htdocs/management/{ipblock,rr,ipaddress,detail,search_results}.html.ep` — templates.
- `htdocs/export.html.ep` — Export form (types, zones, scopes, force, HINFO/TXT).
- `htdocs/advanced/changelog.html.ep` — Changelog (audit log) table.
- `htdocs/search/results.html.ep` — Global search results (RR name + zone).
- `htdocs/error_{403,404,500}.html.ep` — branded error pages (layout `default`).
- `htdocs/management/host.html` (1136 l.), `container.mhtml`,
  `htdocs/generic/view.html` — Mason references.
- `etc/netdot.meta` — FK/relations schema (`linksto`, `views`, `label`).
- `etc/Default.conf` — `REMOTE_EXEC`, `CHECKBOX_CHECKED_EXCLUDE_*`, export dirs.

## Status (to be updated)
- Done: responsive/htmx, Bootstrap, Auth, generic nav, design,
  pagination/CSV/delete, ipblock (nav, subnets, container grid, tree, tabs,
  IP address, block attrs), **RR table (host)**, **search (RR + Ipblock)**,
  **Asset**, meta-driven Registry (labels/views/cols + titles from
  `netdot.meta`), **linksto objects registered + linked** (Product,
  Availability, Circuit, ArpCache, SiteLink, FWTable, STPInstance,
  HorizontalCable, BackboneCable, DhcpScope).
- Done: **Interface** (`Controller/Interface.pm`: detail + FDB + ARP sub-views;
  the raw FWT/ARP timestamp queries from the Mason `interface.html` moved into
  the model as `Interface->fdb_tstamps` / `Interface->arp_tstamps`).
 - Done: **Device — all read-only tabs** (`Controller/Device.pm`, `device.html.ep`,
   `?view=` tabs: Basics, Interfaces, IP, BGP, Hosted, Circuits, STP, Modules,
   Audit). Basics = attributes (netdot.meta "all" view) + custom attributes
   (`Device->attributes`); Interfaces = the `interfaces.mhtml` table (read-only):
   number/name (linked), speed, VLAN (linked; a `<select>` dropdown when an
   interface has >1 VLAN, first option preselected, onchange → vlan page),
   status, jack/descr (conditional), connected-devices (neighbor /
   `get_connected_devices`), sort by `ifsort`, VLAN filter by `showvlan`, row
   color by `doc_status`.
   - IP = `get_ips` (sort_by address/interface, `ipsort`): Address,
     Subnet (parent), Interface, DNS names (multi-link), Monitored?, Services.
   - BGP = `get_bgp_peers` (internal→external→all, `peersort`): Remote IP, ID,
     Entity, AS Name, AS Number (IANA link), State, Contact List; info = BGP ID
     + Local AS. Hosted = `hosted_devices`. Circuits = `get_circuits` (cid/type/
     vendor/status/speed). STP = stp_enabled/stp_type + `stp_instances`.
     Modules = `modules` (flat). Audit = `get_audit_records`.
   - Model return types: `get_ips`/`get_bgp_peers` → arrayref; `stp_instances`,
     `modules`, `get_circuits`, `get_audit_records`, `hosted_devices` → list
     (`my @l; eval { @l = $o->m };`).
 - Deferred (Device): Topology (graph), Access Rights, and all write/edit actions.
- Done: **Reports — 10/10** (`Controller/Reports.pm`): device, asset, ip, macs,
  topology, pollstats, database, custom (hinfo/usedby), ipbat, security.
  Gated by `access_section` (Admin+Operator). Generic FK-cell linking
  (`_obj_html` + `_normalize_rows`). Filter re-application via `search_like()`.
- Done: **Export** (`Controller/Export.pm`, `/export`): 12 types via
  `Netdot::Exporter->generate_configs`. Permission: `Permissions::can_export`
  (write rights on RR). Admin sees all 12; write-rights users see 4 (BIND,
  NAMED, RFC952, DHCPD). Log captured via Log4perl String appender.
  Config: `REMOTE_EXEC => 0` + `CHECKBOX_CHECKED_EXCLUDE_*` in `etc/Default.conf`.
  Playbook fix: `yaml_str` helper (YAML single-quote escaping) + `str2time // 0`
  sort fix.
- Done: **Error pages** (`error_403.html.ep`, `error_404.html.ep`,
  `error_500.html.ep`): branded Netdot (layout `default`). Helpers
  `reply.html_not_found` / `reply.html_exception` in `Netdot::Mojo.pm`
  override Mojolicious default debug pages.
- Done: **Changelog** (`Controller/Advanced.pm`, `/changelog`): 200 most recent
  audit records (`Audit->search_where`, `limit_dialect => 'LimitOffset'`).
  Nav "Advanced" section shows only "Changelog" (interface/physaddr/service
  set to `nav => 0` — routable but hidden from nav).
- Done: **Global search** (`Controller/Search.pm`, `/search`): search box on
  home page. Detects IPv4/IPv6 → redirect to ipblock search; MAC → redirect to
  physaddr search; text → `RR->search_like(name)` (redirect if 1 match, else
   results table with Name + Zone).
 - Done: **Zone / ContactList / Closet — dedicated detail pages** (ports of the
   original per-type Mason `view` pages). Only 3 of the 11 generic-detail types
   had a real dedicated Mason page (`%VIEWPAGE` in `lib/Netdot/UI.pm`); the other
   8 use the generic `view.html`, already handled by `Show.pm`.
   - Zone (`Controller/Zone.pm`, `management/zone.html.ep`): per-type record count,
     apex record (A/NS/MX), generic has_many, recent changes.
   - ContactList (`Controller/Contactlist.pm`, `management/contactlist.html.ep`):
     contacts table (sorted by person) + generic has_many.
   - Closet (`Controller/Closet.pm`, `management/closet.html.ep`): two-column
     physical info, device list, backbone + horizontal cable (read-only).
   Registered in the `%show_ctrl` dispatch map in `Netdot::Mojo.pm`.
 - Done: **Help section** (`Controller/Help.pm`, `/help*`): manual
   (`reply->file` on `doc/manual/netdot-manual.html`), database schema
   (`SQLT->html_schema`), GraphViz schema graph (`SQLT->graphviz_schema` → PNG).
    Gated Admin+Operator; uses `NETDOT_PATH` for file paths.
  - Done: **JSON API writes + full permission model** (`Controller/Api.pm`): per-verb
    checks (GET `view`, POST/PATCH/PUT `edit`, DELETE `delete`, create per-parent
    `_can_create`), Netbox pagination (`limit`/`offset` → envelope), host creation on
    existing IPs (insert an RRADDR, `can('edit',$zone)` + `can('edit',$ip)`). Changelog
    permission filter (own entries for non-admins) + `REMOTE_USER` from session so
    web/API writes are audited. Verified: smobile (zones 114/115/116) adds hostnames
    to 127.0.0.1 and creates TXT/CNAME in zone 114; guest / non-editable zone → 403.
  - Deferred: Access Rights tab; HTML write/edit pages (the **API** now covers
    authorized writes); minor read-only omissions
   (ASN link, v4/v6 selector, utilization toggle; Closet picture display —
   binary serving not migrated); search for the remaining
   types (VLAN, Zone, DHCP, Devices, Assets); NS/MX/TXT/NAPTR related-record
   navigation (register RRNS/RRMX/RRTXT/RRNAPTR, point host-page links at their
   detail pages).
