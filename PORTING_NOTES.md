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
- Template per type: `htdocs/management/<type>.html.ep`.
- Root/breadcrumb pages are rendered by `Browse#list`; they do NOT expose the
  detail-page variables (e.g. `$block_attrs`) → hence the preamble rule below.

## Pitfalls (critical)

### 1. CDBI + `wantarray`
`eval { $class->search(...) } // ()` degrades `wantarray`: the **CDBI
iterators** (returned by `->children` AND by `->search()`) are then stringified
at the first `@{ }` / `->first` → `[eval ...] is not an ARRAY reference`.
- Never wrap a CDBI call that iterates in `// ()`.
- Iterate the iterator explicitly (`$it = $obj->children; while ($c = $it->next)`)
  ; local helper `_search_all($class, ...)` = `my $r=$c->search(...); my @out;
  while (my $o=$r->next){push @out,$o} @out` when an array is expected.

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

## Key files
- `lib/Netdot/Mojo/Controller/Ipblock.pm` — block detail (show + helpers
  `_block_attributes`, grid, sites/zones/dhcp/attrs/arp/audit) + search.
- `lib/Netdot/Mojo/Controller/Rr.pm` — host detail (show + `_rr_attributes`,
  `_rr_sections`, `_search_all`, `_name_link`, `_obj_link`) + search.
- `lib/Netdot/Mojo/Controller/Show.pm` — generic detail (most types).
- `lib/Netdot/Mojo/Registry.pm` — type catalogue, `link_for`, `format_value`,
  `spec`, `display_columns`, `is_sensitive`, `csv_field`.
- `lib/Netdot/Mojo.pm` — app, routes per type, auth hook.
- `htdocs/management/{ipblock,rr,ipaddress,detail,search_results}.html.ep` — templates.
- `htdocs/management/host.html` (1136 l.), `container.mhtml`,
  `htdocs/generic/view.html` — Mason references.
- `etc/netdot.meta` — FK/relations schema (`linksto`, `views`, `label`).

## Status (to be updated)
- Done: responsive/htmx, Bootstrap, Auth, generic nav, design,
  pagination/CSV/delete, ipblock (nav, subnets, container grid, tree, tabs,
  IP address, block attrs), **RR table (host)**, **search (RR + Ipblock)**,
  **Asset**, meta-driven Registry (labels/views/cols + titles from
  `netdot.meta`), **linksto objects registered + linked** (Product,
  Availability, Circuit, ArpCache, SiteLink, FWTable, STPInstance,
  HorizontalCable, BackboneCable, DhcpScope).
- In progress: **Device** port via dedicated controller, order
  **Asset (done) → Interface → Device**.
- Deferred: Access Rights tab; all write functions; minor read-only omissions
  (ASN link, v4/v6 selector, utilization toggle); search for the remaining
  types (VLAN, Zone, DHCP, Devices, Assets); NS/MX/TXT/NAPTR related-record
  navigation (register RRNS/RRMX/RRTXT/RRNAPTR, point host-page links at their
  detail pages).
