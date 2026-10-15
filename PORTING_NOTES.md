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
- E2E test daemon — use the non-hanging launcher **`bin/dev-daemon`** (double-fork: it
  returns as soon as the port actually listens, ~15s max, and does NOT hold the shell's
  stdout — the old inline `setsid perl bin/mojo daemon … &` pattern held stdout via the
  intermediate `bash` and made the tool look frozen). Default port **3000** (do NOT use
  **12345**, the user's own port):
    bin/dev-daemon start|stop|status|log|restart [--port=3000]
  Log: `/tmp/netdot-dev.log`; pid: `/tmp/netdot-dev-<port>.pid`.
  Login: `curl -c ck.txt -d "username=<user>&password=<pass>" http://127.0.0.1:3000/netdot/login`
  (note the **`/netdot`** prefix).
- Bare-`-e`: `use Netdot::Model` loads config+DB; but the RR* classes
  (RRMX, RRNS, …) only load via the RR relations.
- **DBIx::ContextualFetch quirk**: `db_Main()` returns a DBIx::ContextualFetch handle.
  `->prepare` / `->execute` / `->fetchrow_array` are **broken here** (silently return 0/
  undef). Use `->selectrow_array($sql, undef, @bind)` and `->selectall_arrayref($sql,
  undef, @bind)` instead. `selectall_arrayref` rows may come back double-nested
  (`$row->[0]` itself an arrayref) for some queries — dereference defensively.
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
   prefix up automatically (routes are under it) — but **hand-built links in controller
   Perl** (e.g. `sprintf '<a href="/management/…">'`, `href => "/…"` in row hashes,
   `redirect_to`, `sort_base`) do NOT, so they go through **`set_uri`** (`Registry::set_uri`,
    alias `$c->set_uri`) which prepends the base (reads `WEB_BASE_URL`, no-op at root,
    single source with `web_prefix`). `link_for` (Registry) uses it internally; templates
    build a `$base` var via `$c->set_uri`. The legacy **`Netdot::UI`** graph builders
    (ipblock tree, RRD graphs) build asset/link URLs as `$web_path . 'img/graphs/…'` /
    `$web_path . 'management/…'` (no leading slash), so they take **`web_root`**
    (`$c->web_root`) — the base **with a trailing slash** (`/netdot/` or `/`) — as
    `web_path`; a hardcoded `web_path => '/'` drops the prefix on both the `<img src>`
    and the image-map (`usemap`) links. ⚠️ `url_for('/abs/path', k=>v)` **drops the query**
   (absolute path ⇒ static URL) — build the query string by hand for such links. The reverse
   proxy must **preserve** the prefix:
  `ProxyPass /netdot → http://127.0.0.1:3000/netdot` (nginx: `location /netdot/
  { proxy_pass http://127.0.0.1:3000; }` **without a trailing slash**). Dev =
   `http://127.0.0.1:3000/netdot/`. The JSON API lives under the same prefix (`/netdot/api`).
   **Deployment files**: `etc/netdot_apache.conf` is a **version-agnostic** (Apache 2.2/2.4,
   `mod_proxy`) reverse proxy — it replaced the six per-version/per-auth mod_perl configs
   (`netdot_apache2{,4}_{local,ldap,krb5,radius}.conf`, now deleted; auth lives in the app).
     `etc/netdot.service` is the **systemd** unit running **Hypnotoad** (the pre-fork
     production server): `perl /usr/bin/hypnotoad -f <<Make:PREFIX>>/bin/mojo` with
     `NETDOT_LISTEN=http://127.0.0.1:3000`, `NETDOT_WORKERS=10`,
     `NETDOT_PID_FILE=<<Make:PREFIX>>/tmp/hypnotoad.pid`. A manager spawns N workers so a
     **slow request (e.g. a device delete cascading interfaces/ARP/FDB) blocks only its
     worker, not the others** — the same isolation the old Apache ~10-fork mod_perl gave.
     `-f` keeps the manager in the **foreground** (systemd must track it; hypnotoad
     daemonizes otherwise); stop with `hypnotoad -s`. The workers come from
     `Netdot::Mojo` `startup` `config(hypnotoad => {listen, workers, pid_file})`
     (env-overridable). `bin/mojo` is loadable by a server: a server `do`s it
     (`Mojo::Server::load_app`) and the last expression returns the app when there is a
     caller, else `->start` runs the command from `@ARGV` (so `bin/mojo daemon -l …` still
     works for dev). **DB under fork**: Ima::DBI (`db_Main`) is fork-aware — it re-opens a
     per-worker connection on PID change (no manual reconnect); `Model.pm` sets
     `dbi_options->{InactiveDestroy}=1` so a recycled worker only detaches (not
     disconnects) the inherited socket, protecting the manager's connection.
     `User=<<Make:APACHEUSER>>`/`Group=<<Make:APACHEGROUP>>` (default
     `apache`) plus `<<Make:PREFIX>>`/`<<Make:PERL>>` are substituted by the Makefile at install
    (`APACHEUSER`/`APACHEGROUP` were added to `etc/utility-Makefile` `REPLACEABLES`; the top-level
    `export` propagates them to sub-makes). `lib/Makefile` `NDIR` now includes `Netdot/Mojo` and
    `Netdot/Mojo/Controller` so the 25 new modules install. `htdocs/Makefile` deploys the `.ep`
    templates + `layouts/` (`FILES` pattern += `\.ep`, `NDIR` += `layouts`); its `dir:` target
    dropped the Mason `masondata`/`obj`/`chcon` steps. `bin/perldeps.pl` adds **Mojolicious,
      JSON, Net::LDAP, YAML::XS, Crypt::URandom** (checked by `make testdeps`) and **prunes** the legacy web
     modules (`mod_perl`, `Apache2::Request`, `HTML::Mason`, `Apache::Session`, `Apache2::AuthCookie`,
     `Apache2::SiteControl`, `Authen::Radius`) — verified via `%INC` that the new app loads none of
      them (permissions re-implemented in `Netdot::Mojo::Permissions`; sessions = server-side
      flat-file via `Netdot::Mojo::Sessions` — opaque random id cookie, see "Server-side sessions").
     Top-level `Makefile`: `DIR` no longer creates `tmp/sessions`/`locks` and `dir:` dropped the
     SELinux `chcon`; `export/Makefile` dropped its `chcon` too (the `httpd_sys_rw_content_t`
     context is obsolete for the systemd daemon — on RHEL+SELinux the daemon's context is handled
      by a dedicated policy, not `chcon` httpd).
   **Access log**: an `after_dispatch` hook in `Netdot::Mojo` logs one line per request
   (`ACCESS <ip> <user> <method> <controller>#<action> <path> <status>`, static assets skipped);
    `Auth#login_submit` logs `LOGIN <ip> user=<u> success|FAILED`. The `<ip>` is the **real client
    IP**: the `client_ip` helper reads the leftmost `X-Forwarded-For` value **only** when the
    direct peer is a trusted proxy (config `TRUSTED_PROXY_IPS`, an **array ref of IPs**, loopback
    default; add an external front-end proxy IP there), else it logs the direct peer address
    (anti-spoofing: a direct client can't forge `X-Forwarded-For`). Both go through the app logger
   (-> journald under systemd). Log level defaults to `info` (`$self->log->level($ENV{MOJO_LOG_LEVEL}
   // 'info')`; the `.service` sets `MOJO_LOG_LEVEL=info`) so ACCESS/LOGIN are kept and the verbose
   trace/debug per-request noise is dropped. Read with `journalctl -u netdot | grep ACCESS`. This
   complements the write-only audit in the `audit` table (page Changelog), which captures neither IP
   nor reads.

### Server-side sessions (`Netdot::Mojo::Sessions`)
Sessions are **server-side flat-file** instead of signed/encrypted cookies:
- The cookie holds only an **opaque 128-bit random id** (`Crypt::URandom::urandom(16)`),
  a plain (unsigned, `HttpOnly`, `SameSite=Lax`) cookie — no symmetric key, so it can't
  be "cracked". `SESSION_SECURE=1` sets the `Secure` flag (prod, behind TLS).
- Session data is stored on disk as one JSON file per session under `SESSION_DIR`
  (default `<<Make:PREFIX>>/tmp/sessions` = `$NETDOT_PATH/tmp/sessions`): `0600` files in a
  `0700` dir, written atomically (temp + `rename`).
- `Netdot::Mojo::Sessions` subclasses `Mojolicious::Sessions` and overrides `load`/`store`:
  the id is validated against `^[0-9a-f]{32}$` **before any file access** (a forged cookie
  with `/`/`$`/`..` is rejected → treated as unauthenticated; no path traversal), the file
  is removed on logout, and expired files are opportunistically pruned.
- `SESSION_IDLE` (seconds, default 3600) is the **idle timeout** (sliding — refreshed on
  every request; not a fixed lifetime from login).
- Multi-worker safe (Hypnotoad): all workers read/write the same files, so a session
  survives being served by a different worker.

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
- **Same trap on ANY list-returning method + `|| ()`** (returns the list COUNT):
  `my @l = $obj->get_labels() || ();` calls `get_labels()` in **scalar** context → it
  returns the label COUNT (`1`), not the list → `@l = (1)` → `get_column(1)` →
  `croak "column 1 does not exist in table Zone"`. Applies to plain list-returning
  methods too (not just CDBI iterators): `Meta/Table.pm::get_labels` returns
  `@labels ? @labels : undef`. Fix: plain list assignment `my @l = $obj->get_labels();`
  (+ filter `undef`), exactly as `Model::get_label` does. Bitten by this in
  `Model::get_ref_field_spec`.
- **CDBI read semantics (verified 2026-10-14)**:
  - `Class->retrieve_all` / `_ids_to_objects`: **list context → objects, scalar
    context → Iterator**. `my @a = $class->retrieve_all;` is fine; an iterator assigned
    to a list later does NOT drain it — collect the list in the context you created it.
  - `->search(...)` in **scalar/boolean context** returns the iterator, which
    **overloads boolean** (true iff rows exist): `if ( eval { $class->search(...) } )`
    is a valid duplicate check. List context expands to the objects.
  - `->search()` with **no conditions fails on MariaDB** (empty WHERE clause) —
    always pass conditions.
  - `IpService` has **no `name` method** (the label is on the FK target) →
    `$s->service->name`.
  - Many model classes (`IpService`, `BGPPeering`, `UserRight`, …) are
    **autogenerated at runtime** from the meta (`Model.pm`); the class name comes from
    the meta (`BGPPeering`, table `bgppeering`) — the generic API URL uses the
    **table name** (`/api/bgppeering/<id>`), not the class name. CDBI's
    `find_or_create` is available on all of them.
  - **Model `insert` overloads take a hashref**: `AccessRight->insert({…})` (its
    plain-insert fallback forwards `$argv` to `Netdot::Model::insert`, which does
    `keys %{$argv}` — CDBI's own `insert` also takes a hashref). Calling it with a
    key/value list makes `$argv` the first key string →
    `Can't use string ("object_class") as a HASH ref`. (Bitten by this in
    `Api#accessright`, 2026-10-14.)

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
 - **`<% … %>` is a STATEMENT block, `<%= … %>` is the output block**: a bare
   expression in `<% … %>` without a trailing `;` is concatenated with the next
   template chunk (the compiled text placeholder) → `Scalar found where operator
   expected … near "…" $_O`. Every printed expression must use `<%= … %>`; the
   same typo with a missing `%` (e.g. `'' ?>>` instead of `'' %>`) gives
   `syntax error … near "?>>"`.
 - **Hash constructors flatten list derefs**: `key => @{ $arrayref }` inside a
   hash / `render()` argument list puts the **flattened list** into the hash → the
   value becomes a plain scalar (last/only element), NOT an arrayref. Wrap it:
   `key => [ @{ $arrayref } ]`. (`@{ eval { list } // [] }` does not work either
   — `eval BLOCK` in the scalar context of `@{ … }` returns one value, not a
   listref.)
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
- **Read a request cookie with `$c->cookie($name)`, NOT `$c->req->cookie($name)`**:
  `$c->req->cookie($name)` returns a **`Mojo::Cookie` object** (the controller's
  `$c->cookie($name)` is what calls `->value` on it). Stringifying the object gives
  `"name=value"`, so matching the raw value (e.g. a session-id regex `^[0-9a-f]{32}$`)
  silently fails — in `Netdot::Mojo::Sessions` this regenerated the id (and wrote a new
  file) on every request.

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

 ### 2f. Serving **binary** data (images/BLOBs)
 - **`rendered($data)` does NOT exist here.** In this env
   `Mojolicious::Controller::rendered` is `sub rendered($self, $status)` — it takes
   ONLY a status code and finishes the transaction; it does **not** render data. Calling
   `rendered($binary, status=>200, …)` passes `$binary` as `$status` →
   `$self->res->code($binary)` → `->code` returns the binary → `is_empty`/`_status_class`
   do a numeric compare on it → "isn't numeric" + broken/aborted response. **Serve raw
   bytes with `render(data => $bytes)`** (same pattern as the CSV export in `Show.pm`).
 - Set headers via `$c->res->headers->content_type(…)` / `->content_disposition(…)`
   (NOT `$c->res->header(…)` — `Mojo::Message::Response->header` is not available here;
   `->headers->header(…)` / `->content_type(…)` work).
  - The **Closet picture** feature uses this: `Closet.pm#picture` serves
    `ClosetPicture->bindata` (a `longblob`) with its stored `filetype`. Route
    `/management/closetpicture/:id`.
  - **Site / Floor pictures** (2026-10-05): `Show.pm#picture` (one action, `type` in
    the route) serves `SitePicture`/`FloorPicture->bindata` the same way. Routes
    `/management/sitepicture/:id` and `/management/floorpicture/:id`. `Registry::link_for`
    **special-cases Picture subclasses** (`SitePicture`/`ClosetPicture`/`FloorPicture`,
    which have no detail page): their label links to the binary route (image inline)
    instead of a detail page.
 - **CDBI `has_many` relationship methods can return 0 rows** even when the FK rows
   exist (`Closet->pictures` returned `()` while `closetpicture` had rows). Workaround:
   query the related table directly — `ClosetPicture->search(closet => $id)` — and slurp
   the iterator (see pitfall #1).
 - `Registry::link_html($obj)` returns a ready-to-emit, escaped `<a href>` string (empty
   when no route) for raw `<%== %>` output in templates.

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
 - **`search_like()` is NOT a uniform `LIKE` primitive — it is overridden per class**
   (Device, Zone, RR, Asset, PhysAddr, Ipblock each redefine it). E.g.
   `Device::search_like(name=>$q)` matches **RR names / device aliases**, not
   `device.name`. A generic free-text box therefore must NOT call `search_like`
   on the primary column — `Browse#list`'s `?search` uses a **raw parameterised
   `LIKE %q%`** on `cols[0]` instead (see Pitfalls / search). The per-column
   `Browse#list` filters (`%FILTERS`: device site/product/os, physaddr address)
   still use `search_like` because those are exact column filters.
  - **`Device->name` is a FK to RR** (the device's host record): `ref($d->name)` =
    `Netdot::Model::RR`; the raw `device.name` column is the **RR id** (numeric, e.g.
    `272885`). The device's **displayed name** (the FQDN shown as its label / 1st list
    column) is the related **`rr.name`** (the DNS name). Note `->sysname` is a DIFFERENT
    value (the SNMP-reported name, may differ from the DNS `rr.name`). So both the list
    **ordering** and the free-text **`?search`** must target the related `rr.name`, NOT the
    numeric FK and NOT `sysname`. Both do: ordering via `Model::_order_clause` (LEFT JOIN
    rr) and search via `Model::_list_add_like` (relationship-aware, below). Expect the same
    stored-vs-displayed split on other FK label columns.
  - **Relationship-aware free-text search** (`Model::_list_add_like`, 2026-10-05): the
    generic list `?search` (and API `?col=` free-text path) applies `LIKE %q%` to the
    primary column, but **if that column is a relationship (FK)** it instead matches the
    **related object's first label** via `col IN (SELECT id FROM <reltab> WHERE <reltab>.<labelcol>
    LIKE ?)` (e.g. `device.name` → `rr.name`). The pattern is `%q%` (**contains**) — an earlier
    bug used `%q` (suffix-only), so `?search=voip` returned nothing.

### 4. Container grid (port of Mason `container.mhtml`)
- Unit base = **/32** (not /28), otherwise finer children (e.g. /29)
  get a fractional width (0.5) that breaks the grid.
- `cellsperrow = (rowsize>=22) ? 1024 : 2**(32-rowsize)`; cell width =
  `(2**(32-prefix)) * (2**(rowsize-22))` px. 1 row = 1 /rowsize block.
- v6 not supported (message). Links `/management/ipblock/<id>`.

### 5. Class::DBI object index (`%Live_Objects`) → stale reads after API writes
 - Class::DBI 3.x caches one object per primary key: `construct` → `_init`
   does `return $Live_Objects{$key} || _fresh_init(...)`, i.e. a still-live
   object for that id is returned and the **freshly fetched DB row is
   discarded**.
 - Symptom in a long-running single process (this daemon): after
   `PATCH /api/...`, the `/management` page shows the old value until a
   restart, while `GET /api/...` and the DB show the new one. It only
   manifests when the object stays referenced across requests (observed:
   only for interfaces that HAVE a neighbor — the neighbor link keeps the
   object graph alive). mod_perl never showed it: worker recycling +
   per-request teardown collect the objects, so the weak index entries die.
 - Fix (in `Netdot::Model` BEGIN): `$Class::DBI::Weaken_Is_Available = 0;`
   — objects are then never registered in the index and every read builds
   a fresh object from the fresh row. Safe here: Netdot relies on ids
   (no `same_object`/object-identity usage anywhere).
 - Note: `perl -c lib/Netdot/Model.pm` fails (pre-existing, unrelated) —
   Model.pm must be compiled through its normal load path; verify with the
   daemon instead.
 - **Retention hunt (2026-10-13) — conclusion**: a liveness probe (weakref
   captured per rendered interface/device object, checked at request end and
   again +2s via an IOLoop timer) proves there is **no cross-request object
   retention** in the Mojolicious port: objects are freed once the request
   state goes away. Consequences:
   - The stale read was purely the object index (the fix above); no extra
     holder (session, template cache, log, `$_`, timers) was found.
   - Flag OFF is production-safe on memory: nothing accumulates per request.
     It is strictly lighter than flag ON, where the index keeps one weakref
     per object ever created per worker process.
   - The first "retention" signals were a **probe artifact**: copying a
     weakref (`$h{k} = $weakref`) produces a **strong** reference — the hash
     then kept every captured object alive. To store a live weakref, assign
     the object first and weaken the slot in place:
     `$h{k} = $obj; weaken( $h{k} );`.
   - Fixed two bare `for ( @ifs )` loops in `Model/Device.pm`
     (`ints_by_number`, the `get_ips` loop) → `for my`: the package `$_`
     transiently held the last looped object.

 ### 6. JSON booleans from the API are **blessed scalars** (2026-10-14)
 Mojolicious `req->json` decodes `true`/`false` to **blessed scalar objects**
 (`JSON::PP::Boolean`; `Mojo::JSON::Boolean` on some versions) — truthy,
 `ref` = the class name. Legacy `Netdot::Model` assumes **blessed ⇒ Netdot
 object**: `Model::_audit` (the `after_insert`/`after_update` trigger) calls
 `->get_label()` on any blessed field value → a JSON boolean dies
 (`Can't call method "get_label" … JSON::PP::Boolean`) → 400 on any
 POST/PATCH whose body carries a JSON boolean (e.g. the Device Basics
 checkboxes: `collect_stp`, `snmp_polling`, `ipforwarding`, `auto_dns`).
 - **Fix layer 1 — API boundary** (`Api.pm::_args`): normalize every blessed
   non-HASH/ARRAY value (including array items) to plain `0 + $v` before it
   reaches the models. All JSON write handlers route through `_args`, so the
   models see plain 0/1 exactly like the non-API callers (SNMP poller,
   wizards).
 - **Fix layer 2 — model guard** (`Model::_audit`, insert AND update branch):
   call `get_label` only on values that actually have it —
   `blessed($v) && $v->can('get_label')` (every Netdot object has it, a JSON
   boolean does not). Otherwise push the raw value — a boolean stringifies to
   `1`/`0` in the audit `join`. `can('get_label')` covers both JSON boolean
   classes (the class name is version-dependent) and any future blessed
   scalar; an `isa('JSON::PP::Boolean')` check would not.
 - **Silent no-op bug (cost hours)**: the first `_args` normalization loop
   wrote `ref $a->{$k}` / `$a->{$k} = …` while the local hash is `%a`. `$a`
   is the **global sort variable** — a leftover hashref from the last `sort`
   of hashrefs in the process. Syntactically valid, no warning, `perl -c`
   passes; at runtime `ref undef` = `''` so the normalization `if` never
   fired and the blessed booleans sailed through untouched. Element access of
   a local `%a` is `$a{$k}`; `$a->{k}` dereferences the *global* `$a`. Same
   hazard for `$b` next to a local `%b`.
 - **Diagnosing it**: the model's Log4perl logger is ERROR-level
   (`log4perl.category.Netdot = ERROR, Syslog` in `etc/Default.conf`), so
   `->info` diagnostics in `Model.pm` never reach the daemon log — use the
   app logger (level `info`) or file-based canaries in the API layer instead.
 - **Observation — a failed PATCH still commits the SQL**: the audit crash
   happens in the `after_update` trigger, which runs AFTER the UPDATE
   statement → the 400 response leaves the changed values committed in the
   DB. Re-sending the same payload is then a no-op (only `last_updated`
   changes) → 200. That is the "1st post fails, 2nd passes" symptom. With
   both fixes in place every post 200s.

## Mason → Mojolicious reference
- Generic view of a record: `htdocs/generic/view.html?table=X&id=Y`.
- Port a type: take the Mason page (`htdocs/management/*.mhtml`) and its
  helpers, adapt to a dedicated controller + `.ep`.
- Field-link mechanics: `lib/Netdot/UI.pm` (`form_field`/
  `add_to_fields`, `linkPage`/`linkpages`). NS/MX/TXT/NAPTR → `view.html`
  (record view); PTR → `host.html` (host view).
- Styles: `htdocs/css/style.css` (`.ipaddr_*`, `.ipcontainertable`,
  `.tablescroll`, `.container*`, `.progress_bar`).
- **Tabbed detail pages (`.tabcard`)** flatten inner `.container`s (`.tabcard .container`
  — no card-in-card); a section opts back into the boxed look with `.container.boxed`
  (Device Basics: General / Location / Management).
- **Permission / rights-inheritance (original, still in the tree)**: the logic lives in
  `lib/Netdot/ObjectAccessRule.pm` (`denies()` — per-object rule + inheritance), composed by
  `lib/Netdot/NetdotPermissionFactory.pm` (`GrantAllRule` default-allow + `SectionAccessRule`
  + `ObjectAccessRule`), with base rights from `lib/Netdot/Model/Person.pm`
  `get_allowed_objects` (tables `accessright`/`groupright`/`userright` via contact lists).
  `lib/Netdot/Mojo/Permissions.pm` is a direct port of this.

## Key files
- `lib/Netdot/Mojo/Controller/Ipblock.pm` — block detail (show + helpers
  `_block_attributes`, grid, sites/zones/dhcp/attrs/arp/audit) + search. Now also
  renders the shared edit form (both the subnet view `ipblock.html.ep` and the
  individual-address view `ipaddress.html.ep`): scalar + FK "soft" fields → JSON API
  PATCH; only `version`/`parent` are excluded — `address` (dotted-quad text input) and
  `prefix` are editable: a network/prefix change is a **reblock**, handled end-to-end
  by the model (`Ipblock->update` normalizes the dotted address and rebuilds the tree).
  The
  `status` field is also restricted to the values valid for the block type
  (`Model::Ipblock::_validate`): an address → Static/Dynamic(only under a DHCP-enabled
  Subnet parent)/Discovered/Reserved; a subnet/container → Subnet/Container/Reserved
   ("Available" is a free-space/deletion indication, kept only if it is the current value).
   The API `PATCH` re-checks via the model `update()` (invalid status → 400).
   **Page-level delete** (2026-10-09): the block view renders a "Delete" button (when
   `can('delete',$o)`) that threads a default-off choice — **delete the children too**.
   The controller stashes `can_delete`/`del_path`/`del_goto` (→ the parent's page, or the
   roots list when parentless) + `nd_children` (direct-children count, so the UI shows the
   choice only when there are children — like legacy Mason `ip.html`). The JS appends
   `?recursive=1` only when checked; the API threads it to `Ipblock->delete(recursive=>1)`.
     The model already handled the non-recursive case via `_tree_delete` (children re-attach
     to the block's parent / become roots). (2026-10-11) The individual-address view
     (`ipaddress.html.ep`) renders the same Delete button (`nd_children=0` → no children
     choice; `del_goto` → the parent's page) and **hides its empty data sections** (DNS
     A/PTR, Services, Custom Attributes, DHCP Host are rendered only when they have rows).
    **Creation** (2026-10-10): two entry points, both posting to `POST /api/ipblock`
    (`{address, status, parent}` → `Ipblock->insert`; a duplicate `address`+`prefix` is a
    DB unique violation → 400, shown as a status box — no pre-check in the UI):
    (a) a "New Ipblock" box on the roots list (`Browse#list`, shown when `can('edit')`) —
    `address` (CIDR) + `status`; (b) **click-to-create** (Mason `ADD_BLOCK`): on the
    container **block view** every free partition is clickable, and on a Subnet **block
    view** every unassigned address is. A free cell carries `data-nd-create` (the partition
    CIDR or the `/32`/`/128` address) + `data-nd-parent` (this block's id) and, for an
    address, `data-nd-dhcp` when the Subnet parent has DHCP scopes. Clicking it opens a
    confirm modal — *"The IP address or block X does not yet exist. Are you sure that you
    want to create it?"* — with a status `<select>`: a **block** (prefix < 32/128) offers
    Container/Reserved/Subnet (default Container); an **address** offers Static/Reserved
    (+ Dynamic only when `data-nd-dhcp`). OK POSTs the chosen status (no `parent` — the API
    auto-attaches) and redirects to the new block's detail page so the user can add info
     (description, a DNS A/AAAA record for a hostname, owner, …). Discovered (discovery tools)
     and, for a *new* block, a Static/Container status, are not offered.
     **IP address — adding related objects** (2026-10-10): the individual-address view
     (`ipaddress.html.ep`) has a single "Add a record" box (RR-page style: a type
     `<select>` reveals one pre-rendered form; reuses `initAddForm`/`initForms`), placed
     before the read-only ARP section. It is meta-built in the controller as an `add_types`
     list (the `_rel_add_fields` shape: `{type, label, add:{hidden, fields}}`) and offers,
     each `POST`-ing to the JSON API: A Record (`/api/rr` `{type:A, name, zone, ipblock}`),
     PTR (`/api/rrptr` `{ptrdname, zone, ipblock}` — the model creates the owner RR),
     Service (`/api/ipservice` `{service, contactlist, ip}`), Custom Attribute
     (`/api/ipblockattr` `{name, value, ipblock}`), and DHCP Host (`/api/dhcpscope`
     `{type:host, name, ipblock, container, physaddr|duid}`, only when the Subnet parent has
     DHCP scopes). Zone handling: the **A-record** zone `<select>` offers the forward
     (non-arpa) zones the user may edit (a User only their own — `allowed_objects`
     `{Zone}{id}` with an `edit` action, mirroring `Browse#list`'s "New name" box; an Admin
     sees all), pre-selecting this IP's forward zone (`forward_zone()`/`dns_zones()` walks up
     to the nearest ancestor holding a zone) and falling back to the first. The **PTR** zone
     is **fixed** to this IP's reverse zone (`reverse_zone()`, the only one matching its
     address) — rendered read-only and sent as a hidden field, and the type is omitted when
     there is no reverse zone. The selects/hidden id fields carry `data-nd-int`; `netdot.js
     collect()` coerces a purely-numeric value to an integer so FK ids go out numeric
     (names/addresses stay strings). This replaced an earlier per-section "Add" modal approach.
     Its hidden id fields are rendered **outside** the `<table>` (inside `<tr><td>` they showed
     up as empty rows).
    **List view — DNS "Name" column** (2026-10-11): `view_format=list` shows each IP's A records
     (FQDNs, comma-separated, **each name a link to its RR object**), filled by ONE query
     `LEFT JOIN rraddr JOIN rr JOIN zone` (like legacy `subnet.mhtml`) — not the per-row
     `$o->a_records` (was N+1, and `eval { ... } // ()` tripped Class::DBI's scalar-context
     **iterator** trap so the column came out empty). See the wantarray pitfall below.
    **Block section-tab write forms** (2026-10-11, same `collect()`/`initForms` pattern, gated on
     `can('edit')`): **Sites** → `POST /api/sitesubnet`; **Zones** → `POST /api/subnetzone`
     (link an existing forward zone, active non-arpa not already linked) and `POST /api/zone`
     (create a reverse/`.arpa` zone from `get_dot_arpa_names` candidates); **DHCP** (Subnets with
     no scope yet) → `POST /api/dhcpscope` type=subnet under a chosen global scope — `initDhcpEnable()`
     nests the flat `option_routers` field into the `attributes` object (the model stores it as a
     `dhcpattr`; there is no dhcp flag on ipblock); **Attributes** → `POST /api/ipblockattr`.
      Zones **inherited** from an ancestor render *italic* + "(inherited)" (only a direct
      `SubnetZone` link / a zone matching the block's own arpa name counts as "configured");
      for the reverse column the effective `reverse_zone()` is shown when the block has no own
      arpa zone, tagged "(inherited)" when it is an ancestor's (e.g. a /16 under a /8 owning
      `10.in-addr.arpa`). All the add-form `<select>`s open with a `--SELECT--` placeholder option.
    **Class::DBI wantarray pitfall** (recurring): a Class::DBI relation method returns a LIST in
     list context but a single **Iterator** in scalar context. `eval { $obj->rel } // ()` forces
     scalar context → you get one Iterator, not the objects (the `//` degrades wantarray). Always
     `my @r; eval { @r = $obj->rel }; @r = () if $@;` (assign **inside** the eval), or
     `my @r = eval { $obj->rel };` (no `// ()`). This bit the list "Name" column and
     `get_dot_arpa_names` this session.
    - `lib/Netdot/Mojo/Controller/Rr.pm` — host detail (show + `_rr_attributes`,
   `_rr_sections`, `_rel_record`, `_search_all`, `_name_link`, `_obj_link`) + search.
   Now also renders the shared edit form (name, zone, active, auto_update, expiration,
   info → JSON API PATCH); the system timestamps `created`/`modified` are excluded (not
   user-editable). `_rel_record` builds each associated record's fields **from
   netdot.meta** ("all" view, in meta order) — a column added to the meta becomes editable
   automatically; kind from the meta type (integer→number, varchar>255→textarea), FKs
   hidden unless `show_fk`, `readonly`/`hidden`/`selects`/`links`/`link_on` options handle
   the per-view cases. **Search results** (`search`, `search_results.html.ep`): paginated
   at `DEFAULT_PERPAGE` (50/page, `?offset=`; a single match still redirects to the detail
   page); the first column is `rr.name` (the relative name), NOT `get_label` (the full
   FQDN) — the zone has its own column. The results table also offers the row checkboxes +
   Delete button + select-all (see the batch-delete note below).
  - `lib/Netdot/Mojo/Controller/Show.pm` — generic detail (most types): attrs
    (all view) + **has_many tables** (from `meta_data->get_links_from`, like
    Mason `view.html`): one table per non-empty relation, brief columns (label
    columns excluded from the brief set), 1st column = object label linked to its
    detail page, rows capped at config `DEFAULT_PERPAGE` (50). Relations are
    **ordered + paginated in SQL** (see `Detail.pm` below). Also a `picture` action
    (2026-10-05) serving SitePicture/FloorPicture BLOBs (see pitfall 2f). NOTE: `get_links_from`
   returns a **hash** and `get_labels` a **list** → use `my %h; eval { %h = ... }` /
    `my @l; eval { @l = ... }` (the `eval {...} || ()` wantarray trap breaks both).
     `Browse#list` page size also comes from `DEFAULT_PERPAGE`.
     **Generic delete (detail page)** (2026-10-08): a "Delete" button next to "Edit",
     rendered when `can('delete',$o)`; reuses the `.nd-rec-delete` + `data-nd-del` /
     `data-nd-goto` mechanism (same as the RR detail page) → `DELETE /api/<table>/<id>`
     (the model's `delete()`), then redirects to the list. The API table is the DB table
     name (`$class->table`), NOT `lc($type)` (they differ for DhcpScope: "dhcscope" vs
     "dhcpscope") — the edit `api_path` was fixed to use `$class->table` too.
  - `lib/Netdot/Mojo/Detail.pm` — shared builders used by Show + the dedicated
    detail controllers: `build_attrs` (all-view attrs, FK→link), `build_relations`
    (has_many tables, paginated), `rel_columns`, `obj_text`. **Relation data access**
    (2026-10-05): `relation_objects($obj,$rel,$per,$off)` → `_relation_fetch` fetch a
    relation **ordered + paginated in SQL** (`ORDER BY` + `LIMIT/OFFSET`, `COUNT(*)`
    for the total; hydrates via `->retrieve`). `_rel_label_sort($class,$alias)` picks the
    ORDER BY for the 1st displayed column: **Ipblock → integer `address`** (natural IP
    order, IPv4 before IPv6, exact at 128 bits); a **relationship label column**
    (device.name→RR) → `JOIN` the related table and order by its label (`rr.name`);
    otherwise the first label column. Connector/join tables order by the referenced
    object's label via the connector's FK. The CSV export (`Show#show ?csv=`) uses the
    same `relation_objects` (all rows) so it matches the on-screen order.
     **Edit form** (phase 2): `build_edit_fields($obj,$class,$person)` → one spec per
      non-sensitive all-view column. Scalars → `text|number|textarea|checkbox|date`.
      ⚠️ **`timestamp`-type columns are excluded** (system-managed — Last ARP / Last
      FWT / Last Updated / First Discovered / …; the Mason Basics view renders them
      `edit=>0`); they stay read-only in the attributes table. **`date`-type columns**
      (Down From / Until) are editable, rendered as a native `<input type="date">`
      (`YYYY-MM-DD`; the `0000-00-00` zero-date → empty input; clearing → `NULL`). **FK →
     `kind=>'fk'`**: target ≤ `DEFAULT_SELECTMAX` (100) → `options` = all `{id,label}`
     (renders a plain `<select>`); large target (RR/Ipblock/…) → `options` undef + the
     current value only (renders a keyword box; the JS fills the `<select>` via the API
     `?kw=` FK search). Multi-valued relations (non-scalar `$obj->$col`) are skipped and
      stay read-only. `cur_id` = the FK id; `cur_label` via the related object's
       `get_label`. ⚠️ **A FK is only editable if its target type is registered in
       `Registry %TYPES`** (`spec($target)` defined); otherwise `build_edit_fields`
       silently drops the field (`next unless $tclass`). 4 lookup types were missing and
       got registered (`usertype`, `contacttype`, `dhcpscopetype`, `entitytype` →
       `%TYPES`+`@ORDER`); a scan over every table's all-view confirmed that was the
       complete set. The form is a **shared partial** `htdocs/management/_edit_form.html.ep`
      (included via `$c->render_to_string(..., layout=>0)` from any detail page) +
      `htdocs/java_script/netdot.js` (`ND.api` fetch PATCH, transient `ND.status` box,
      FK `?kw=` fill, `#nd-edit`/`#nd-readonly` toggle). A page opts in by stashing
      `can_edit`/`fields`/`api_path` (Show.pm, Zone.pm, …) and adding the Edit button +
       `id="nd-readonly"` on its attrs table + the partial include. Writes go through the
       JSON API only (no server-side form handler). **Zone**, **Contactlist**, **Closet**,
       **Device**, **Ipblock** and **RR** (dedicated controllers) now have their edit form
       too; every dedicated detail model reuses the same partial. ⚠️ **Ipblock**: only the
       `version` and `parent` fields are EXCLUDED from the form (the parent is recomputed
       by the model; the version follows the address). `address` (dotted-quad text input)
       and `prefix` are editable — a network/prefix change is a **reblock**, handled
       end-to-end by the model (`Ipblock->update` normalizes the dotted address to its
       integer form, rejects a v4<->v6 version change and collisions, then rebuilds the
       tree via `_update_tree`; a moved /32 also triggers a full rebuild so the saved
       tree loses the stale entry). ⚠️ **RR associated records (RR\*) inline
        edit** (`Rr.pm` + `rr.html.ep` + `netdot.js` `initRecToggles`): each related record
        (A/AAAA, TXT, MX, NS, CNAME, PTR, NAPTR, DS, LOC, SRV, HINFO) gets its own inline
        form (per-record Edit button → `PATCH /api/<type>/<id>`, runs the model `update()`).
         Editable: **TTL** (all types) + the record's own value(s) — TXT `txtdata`, MX
         `exchange`/`preference`, NS `nsdname`, CNAME `cname` (only in the "is an alias
         of" view — the target equals $o in the "Aliases of" view, so it is hidden there),
          NAPTR fields, DS `key_tag`/`algorithm`/`digest_type`/`digest` (all), HINFO
          `cpu`/`os` (as `<select>`s driven by the config `DEFAULT_HINFO_CPU/OS_VALUES`,
          key=DB value / value=label), SRV `priority`/`weight`/`port`/`target` (all),
          LOC `latitude`/`longitude`/`altitude`/`size`/`horiz_pre`/`vert_pre` (all),
          PTR `ptrdname` (only in the "Pointer Records" view = the PTR's own page; the
          "Reverse DNS (PTR)" view on an A record's page is read-only/informational).
         The record's detail link is merged onto the **first value field** (TXT `TXT`,
         MX `Preference`, NS `Name Server`, NAPTR `Order`); the redundant "Record" row
         is dropped. The form shows **all** fields (editable as inputs, the rest
          read-only) so context (IP, owner, …) stays visible while editing. TTL/value are
          validated by the model (`ttl_from_text` / `_sanitize_ptrdname`) → 400 if bad.
          **RRAttr** ("Other Record Types (CAA, HTTPS, …)"): modern types stored as a raw
          value (`RRAttr`/`rrattrname`: CAA/HTTPS/SSHFP/SVCP/TLSA/URI/SMIMEA), same
          `_rel_record` (meta-driven) routine: Type (FK `name`, read-only) + `value` (raw,
          may contain spaces/quotes → `&quot;` escaping) + `ttl`, editable,
          `PATCH /api/rrattr/<id>`. `RRAttr::as_text` emits the line with the **raw zone
          name** (`rr->name`, apex = `@`) like the other record types, and the value verbatim
          (Net::DNS has no `rdata_format` validation for these types and expects typed
           fields, not the raw rdata — so it is not used). `RRAttr::_validate_value` guards
           the raw value (run by `insert`/`update` → 400 if bad): no line breaks (zone is
           line-oriented), only printable ASCII + tab (`^[\x09\x20-\x7E]+$`), and an even
           number of `"` (balanced quotes). Editing is **reserved to Admins**: the section
          renders read-only for non-Admins (controller passes `is_admin` → `_rel_record
          readonly`), the UI shows a disclaimer (section `warn` key), and the API gates
          create/update/delete of `RRAttr` to Admins (`Api::_admin_only_write` → 403).
          **RR — adding / deleting records** (`Rr.pm` + `rr.html.ep` + `netdot.js`
          `initAddForm`/`initRecDeletes`): every record row has a Delete button
          (`DELETE /api/<type>/<id>` behind a `confirm()`), and an "Add a record" section
          offers the addable types (A/AAAA, MX, TXT, NS, HINFO, SRV, DS, NAPTR, LOC,
          RRAttr admin-only; **PTR only in reverse zones** — `zone->is_dot_arpa`). Add
          forms are meta-driven (`_rel_add_fields`): the parent FK (owner `rr`) is
          auto-filled and hidden, small-table FKs (<100 rows, counted via
          `search_count()`) render as `<select>`, TTL is pre-filled with the zone's
          `default_ttl`, and A/AAAA/PTR address fields take a plain IP string
          (`ipblock`). **Everything goes through the model's `insert`**
          (`POST /api/<type>` → `Api::_post` → `$class->insert`): `RRADDR`/`RRPTR`
          convert the address string to an Ipblock themselves
          (`_convert_ipblock`: `Ipblock->search`, else `Ipblock->insert(status Static)`),
          `RRPTR` validates the reverse zone, creates the owner RR and checks conflicting
          types, `RRCNAME` enforces mutual exclusivity, and TTL falls back to the zone
          default. The API adds only permission checks (`_can_create` per parent) — no
          redundant conversion code. **CNAME/alias**: a dedicated "Add an alias (CNAME)"
          box (`POST /api/rr/<id>/alias` → `Api::alias` → `_create_alias` →
          `RR->insert({type=>'CNAME'})`). The new name's zone is resolved from the entered
          name: a short name stays in the current zone; a long name whose domain part
          matches an editable zone maps to that zone (zone part stripped); any other long
          name lands in the current zone as a label (e.g. `www.google.com` →
          `www.google.com.localdomain`). Conflicts are handled by `RRCNAME->insert` (a name
          that already has other records → 400).
          **RR — new name (list page /management/rr)**: a "New name" box (name + zone
          `<select>`) sits side by side with the search box (`.cardrow` = flex row, equal
          widths, 16px gap, wraps on narrow screens). Default zone = config
          `DEFAULT_DNSDOMAIN` (pre-selected when present). **A User only sees the zones
          they hold `edit` on** (from `allowed_objects->{Zone}`; the box is not rendered
          if they have none). `POST /api/rr {name, zone}` → `RR->insert` (the model
          validates the name; the API's `_can_create` re-checks `can('edit',$zone)`), then
          a JS redirect to the new name's detail page (`/management/rr/<new id>` via the
          `data-nd-redirect` attribute, handled in `netdot.js` `initForms`). The name is
          created **without records**; its records are added afterwards on its own page.
          **RR — deleting the name itself (detail page)**: a "Delete" button sits next to
          "Edit", rendered when `can('delete',$o)` (model rules apply: a User cannot
          delete the zone apex or an RR linked to a device, …). Same generic mechanism as
           the per-record delete buttons: `DELETE /api/rr/<id>` (the model's `delete()`),
           with an adapted `confirm()` ("this object and all its records") then a redirect
           to the list (`data-nd-goto`, supported by `netdot.js` `initRecDeletes`, which
           now handles both reload and goto).
           **Batch delete (generic list pages)**: the row checkboxes on every `browse#list`
           page now go through the JSON API in a SINGLE call: `DELETE /api/<type>?id=1,2,3`
           (`Api::generic` accepts a comma-separated id list in the query string, matching
           the search model). `Api::_batch_delete` checks `can('delete')` **per object**
           (one bad id does not abort the rest) and answers
           `{deleted:[...], skipped:{id:reason}}` (200 if ≥1 deleted, else 400). The list's
            "Delete" button is driven by `netdot.js` `initBatchDelete` (live "N selected"
            counter, reload after). **The old server-side route
            `POST /management/<type>/delete` (`browse#delete`) is removed** — no more
            server-side writes; everything goes through the JSON API.
            **Batch delete on the dedicated search results too** (2026-10-12): the
            `rr`/`ipblock`/`physaddr` searches render `search_results.html.ep`, which now
            offers the same row checkboxes + Delete button + a **select-all** header
            checkbox. Each search is homogeneous (one type per query: name→RR, IP→
            Ipblock, MAC→PhysAddr), so a single `data-nd-api` base (`/api/<type>`) works;
            the controllers stash `del => { type, api }` (gated on `has_action delete`)
            and add `id` to each row. **Fix**: `initBatchDelete()` was defined but never
            called in the `DOMContentLoaded` handler, so the Delete button was dead — it
            is now registered.
            **Delete UX — modal + busy overlay** (2026-10-09): all delete confirms use a
            `netdot.js` **`ndConfirm`** `<div>` modal (NOT a native `confirm()`, which
            triggers the browser's anti-dialog "don't ask again" permission prompt). A single
            dialog carries the optional default-off checkbox: Device = "also delete its IPs /
            DNS A/AAAA" (`delete_ips`), Ipblock = "also delete the N child blocks"
            (`recursive`, offered only when `data-nd-children` > 0). While the (possibly
            slow, recursive) `DELETE` is in flight a full-screen **`spinner`** "Deleting…"
            overlay blocks interaction; on success the `ND.status` box + reload/goto. CSS in
            `style.css` (`.nd-modal*`, `.nd-busy*`).
            **Bulk edit** (2026-10-12, port of `generic/edit-multiple.html`): on every
            generic list page (`browse#list`) and on the dedicated search results
            (`rr`/`physaddr`/`ipblock` searches, `search_results.html.ep`), a "Bulk edit"
            button (gated on `has_action edit`, next to the row-checkbox Delete button)
            opens a **field-picker POPUP** (`netdot.js` `initBulkEdit`; the stashed
            `window.ND_BULK = {type, url, fields:[{name,tag}]}` comes from the
            controllers, which only stash the field names — the values are read on the
            page) and then navigates to the **dedicated full-page**
            `GET /management/bulk_edit?table=<type>&object_id=1,2,3&fields=a,b`
            (`browse#bulk_edit`, route in `Mojo.pm`). The page renders the editable
            table server-side inside a `.container` box: one row per object (Name column
            = label + link to the detail page), one column per chosen field, each cell
            pre-filled with the current value and built by
            `Detail::bulk_edit_cell_html` — **FKs are `<select>`s** (small target: all
            options from `editable_field_specs`; large target: the `.nd-fk-search`
            keyword-search pattern of the detail edit form, the `<select>` pre-filled
            with the current label), plus checkbox / text / number (`data-nd-int`) /
            date / textarea. An **"Apply to all"** row (legacy `applytoall_<field>`
            semantics) holds a per-field value that wins for every row when its box is
            checked. Save = form submit intercepted by `netdot.js`
            `initBulkEditPage` → ONE `POST /api/<table>/batch` (`{updates:[{id, ...}]}`):
            the API re-checks `can('edit')` **per id** and writes only the sent fields —
            single source of truth `Detail::editable_field_specs` (picker fields = API
            accepted fields) — so the audit logs only the columns that actually changed.
            Per-id errors are reported with the object's label; success redirects back to
            the list. CSS: `.nd-bulk-*` in `style.css` (sticky Name column, min-width
            cells for ~20-column tables).
   - `lib/Netdot/Mojo/Controller/Zone.pm` — Zone detail (port of
    `management/zone.html`): record count (per type), apex record (A/NS/MX with
    links), generic has_many (subnets/records/aliases), recent changes (HostAudit).
    Now also renders the **shared edit form** (`_edit_form.html.ep` partial; SOA fields +
    contactlist FK + active/dnssec + include/info), PATCH `/api/zone/<id>`.
 - `lib/Netdot/Mojo/Controller/Contactlist.pm` — ContactList detail (port of
   `generic/contactlist.html`): **contacts** rendered as a dedicated table (role
   sorted by person label: Person link + contacttype + notify_email/pager/voice
    + escalation_level), other has_many as generic tables (`contacts` excluded).
    Now also renders the shared edit form (`_edit_form.html.ep`).
   - `lib/Netdot/Mojo/Controller/Closet.pm` — Closet detail (port of
    `cable_plant/closet.html`): curated two-column info + `info`, Device List
    (room→floor→site), Backbone Cable (start+end merged), Horizontal Cable
    (read-only; cable names plain text, no deep link to deprecated pages),
    **Pictures** section (`_pictures`, via `ClosetPicture->search`) + **binary
    route** `picture` action (`/management/closetpicture/:id`, serves the
     `bindata` BLOB — see pitfall 2f). Now also renders the shared edit form
     (`_edit_form.html.ep`; the `room` FK is large → `?kw=` search).
   - `lib/Netdot/Mojo/Controller/Browse.pm` — generic list (all types): `%FILTERS`
    per-type filter whitelist, `search_like()` re-application, FK links via
    `Registry::column_link_key`/`esc`, CSV export, batch delete. Also **generic
    per-type search** (`search` action → `list`, route `/management/<type>/search`):
    free-text `?search` = raw parameterised `LIKE %q%` on `cols[0]` + view predicate
    (NOT `search_like` — see Models pitfall); the list template's search box +
    query-preserving pagination live here.
    - **Ordering** (2026-10-03): list + CSV + the ipblock root filter are ordered by the
      **first display column** (id tie-break), not `id`. Client-side `tablesort.js` only
      sorts the current page, so a paginated list needs a server order. **All of this SQL
      lives in the Model** (`Model::search_page`/`search_count`, `order_by => $first`): a
      scalar first column → `ORDER BY <col> ASC, id` (DB collation, case/accent-insensitive);
      a **relationship first column** (only `device.name` → RR) → related label via a
      `LEFT JOIN` (predicate wrapped in a subquery, see `Model::_order_clause`). The
      controller only builds the `where` (per-user predicate) and calls the Model; `_kcmp`
      (numeric-aware text compare) remains here only to order the `search_like()` filter
      path in memory.
  - `lib/Netdot/Mojo/Controller/Reports.pm` — all 10 reports: `_obj_html`,
    `_link` (via `set_uri`), `_normalize_rows`, `_skey`, per-report row builders,
    CSV export. Every data report renders through the shared
    `htdocs/reports/data_table.html.ep`, which builds a modern **`datatable`** table
    (`<thead>` header row + `<tbody>` body rows, **no** legacy `formtabletitle` /
    `datatabler1` / `datatabler2` cell classes) so the 2026 design (header styling, zebra,
    rounded corners) applies; `_render` also wraps the report "Options" form in a
    `.container` card.
- `lib/Netdot/Mojo/Controller/Export.pm` — Export form (GET) + run (POST):
  type-gating (Admin→12, write-rights→4), `generate_configs`, String appender
  log capture, per-type error list.
- `lib/Netdot/Mojo/Controller/Advanced.pm` — Changelog: raw SQL on `audit`
  (`SELECT COUNT(*)` + `SELECT … ORDER BY tstamp DESC LIMIT ? OFFSET ?`), `search`
  (LIKE on `label`) + `operation` filter + `offset` pagination, and a **permission
  filter** (Admin/Operator see all; otherwise `username = <self>`).
- `lib/Netdot/Mojo/Controller/Search.pm` — Global search: IPv4/IPv6 → redirect
  ipblock search; MAC → redirect physaddr search; text → `RR->search_like(name)`.
- `lib/Netdot/Mojo/Registry.pm` — type catalogue, `link_for`, `set_uri` (base-prefix
   for hand-built internal paths; core behind the `$c->set_uri` helper), `format_value`,
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
   `web_prefix` + `set_uri` helpers (base-prefix for hand-built links), `deny_unless`
   helper, `api_json_err` + path-aware
  `reply.{html,json}_{not_found,method_not_allowed,exception}` (JSON errors under
  `/api`, branded HTML elsewhere).
- `lib/Netdot/Mojo/Api.pm` — JSON API serializer (port of `Netdot::REST::get`):
  `get($obj,$user,$manager,%opts)`. FK → **nested reference** `{id, url, ...label fields}`
  (via `_ref` = `{id,url}` + `Model::get_hashref`); FK null → `null`; `depth>0` → full
  nested object; `linked_from` → arrays of the same refs. **Sensitive columns are skipped**
  (`Registry::is_sensitive` — password, snmp_authkey/privkey, authkey) so secrets are never
  serialized (same guard the HTML views use). `Netdot::Mojo::Api::Error` (code+msg). No Apache
  dependency.
- `lib/Netdot/Mojo/Registry.pm` — `is_sensitive` / `%SENSITIVE` (never-display columns:
  `password`, `snmp_authkey`, `snmp_privkey`, `authkey`). Used by the HTML detail controllers
  AND the API serializer + OpenAPI generator so secrets stay hidden in all three. `community`
  (SNMP v1/v2c) is deliberately NOT listed (operational, shown in the HTML Device detail).
- `lib/Netdot/Model.pm` — `get_ref_field_spec` (class; the reference/label-field spec,
  single source of truth, base = `meta_data->get_labels` → `[{name,is_fk,sql_type}]`) +
  `get_hashref` (instance; `{field=>value}`, an FK field → the related object's `get_label`
  **one level** — mirroring `get_label`, so no unbounded recursion). Consumed by the API
   serializer (`_ref`) and the OpenAPI generator (per-class `FkReference_<Classe>`); a class
   overrides `get_ref_field_spec` to customise its reference fields and both stay in sync.
   Also the **list data-access layer**: `search_count` / `search_page` (bound column filters +
   trusted `where` permission fragment + optional free-text `like`) and their helpers
   `_pagination_where` / `_combine_where` / `_list_add_like` / `_order_clause`. `search_page`
   accepts `order_by` (a validated column; if it is a **relationship** it orders by the
   related object's first label via a `LEFT JOIN`, wrapping the `where` in a subquery so its
    bare columns stay unambiguous) and `limit => 0` (all rows, for CSV). `_list_add_like` is
    **relationship-aware** (2026-10-05): the free-text `like` on a FK column matches the related
    object's label (`col IN (SELECT id FROM <reltab> WHERE <reltab>.<label> LIKE ?)`) with a
    `%q%` (contains) pattern — so ordering and search both target the related label (e.g.
    `rr.name`) for `device.name`. This is the single
    place for list SQL — both the JSON API (`Api.pm`) and the HTML list (`Browse.pm`) call it,
    so no raw SQL lives in the controllers.
- `lib/Netdot/Mojo/Controller/Api.pm` — JSON API controller: `generic` (GET list +
  object, POST/PATCH/PUT, DELETE per table) with **per-verb permission checks** —
  GET `can('view')`, update `can('edit')`, DELETE `can('delete')`, create `_can_create`
  (per-parent: `zone`/`rr`/`device`/`contactlist` FK; see `_create_parent`) — and
  **Netbox pagination** (`limit`/`offset` → `{count,next,previous,results}` via
  `Model::search_count`/`search_page`); purpose-built `devinfo`/`host_contacts`/`ipattr`/
  `host`/`host_like`/`updatedev`/`prometheus`. `_host_post`: create on a **new** IP = subnet
  `can('edit'/'choose_ip')` + `RR->add_host`; create on an **existing** IP = insert an
  **RRADDR** (no allocation) allowed iff `can('edit',$zone)` AND `can('edit',$ip)`.
   Also `root` (GET `/api` Netbox-style flat index), `spec` (`/api/openapi.yaml`),
   `docs` (Swagger UI, standalone).
   - **`prometheus`** (GET `/api/prometheus`; raw-SQL first, then object-model
     rewrite — commit `4a2f3ca7`) — port of the legacy `prometheus-inventory.php`: all
     MONITORED devices — `Device->search({monitored => 1})` — walked through the
     object model (FK accessors `name`→RR→`zone`, `site`, `asset_id`→`product_id`
     →`type`/`manufacturer`, `used_by`→Entity — **no raw SQL**). A monitored
     device missing any link of the chain is skipped, as in the PHP inner
     joins. Grouped by (type, manufacturer, site, **env**) in the Prometheus
     **file-based service-discovery** shape: an array of
     `{labels: {__meta_netdot_type, __meta_netdot_manufacturer,
     __meta_netdot_site, __meta_netdot_env}, targets: ["<rr.name>.<zone.name>",
     …]}`. Differences vs the PHP script (intentional, requested): env is the
     device's `used_by->short_name` (Entity), not the constant `"CI"` (JSON
     null when the device has no used_by) — and env is **part of the group
     key**, because 27 of the 172 (type, manufacturer, site) groups mix
     several used_by values and a group's labels must stay consistent
     (Prometheus requirement). Gated on a session + `has_action('Device',
     $p, 'view')` (the PHP script was unauthenticated — direct DB access).
     Manufacturer transform ported 1:1 (`lc()` as in the PHP `LOWER()`, first
     `[A-Za-z0-9 ]+` run, trimmed, spaces → `_`), `Cache-Control: no-cache,
     must-revalidate, max-age=0` header kept. Cost of the object model: ~1300
     device fetches + per-FK PK SELECTs (CDBI in-memory cache deduplicates
     sites/products/entities) instead of one join — fine at file-SD scrape
     frequency. Verified on live data vs `php prometheus-inventory.php`:
     identical 1237-target multiset; 205 groups (vs 172 — the env split);
     every target's env label matches its device's used_by short_name (100%).
   - **FK keyword search `?kw=`** (edit-mode FK picker, `Api.pm` `generic` GET list):
     `GET /api/<table>?kw=<kw>&limit=N` → `{count, results:[{id,label}]}`. Default =
     `LIKE %kw%` on the label column (`search_page(like=>[labelcol,$kw])`). **Ipblock is
     special-cased**: its `address` is a `decimal(40,0)` (numeric), so a raw `LIKE` can't
     match the dotted form → use the model overrides (string→int) in **list context**
     (the `eval{ } // ()` scalarizes the CDBI iterator — see Pitfall §1): `search(address)`
     exact/CIDR first, then `search_like(address)` prefix-range for partial addresses,
      deduped by id (mirrors the legacy `keyword_search` hash).
    - **Write hardening** (`_post`): the request body is stripped of `validate` and
      `no_update_tree` (alongside `depth`/`linked_from`) so a client cannot disable the
      models' `update()` validation — e.g. an invalid Ipblock status via `{"validate":0}`
      or `{"no_update_tree":1}`. All API writes therefore go through the model `update()`
    → `_validate()`. (Note: `Ipblock->validate` is a *different* method — it only checks
    address format via `_prevalidate`.)
  - **DELETE per-class options** (`_delete`, 2026-10-09): the default-off flags the UI
    offers are threaded to the model `delete()` only for the classes that take them —
    Device (`delete_ips`, `no_delete_name`) and Ipblock (`recursive`). ⚠️ **`$class` is the
    SHORT package name** (`Ipblock`/`Device` — `_model_tables` uses the meta `->name`), so
    compare via `$class->short_class` (same pattern as `_admin_only_write`), **NOT**
    `Netdot::Model::*`. That earlier `Netdot::Model::Device`/`Netdot::Model::Ipblock`
    comparison never matched, so `recursive`/`delete_ips` were silently dropped (children
    got re-parented instead of deleted) — the fix normalizes with `short_class`.
   - **`POST /api/accessright`** (`Api#accessright`, route declared before `/api/:table`):
     grants rights on an object — the Mason generic `access_right_form.html` « Add rights »
     form, shared by the Ipblock and Device Rights sections (both post to this ONE
     endpoint). Body `{object_class, object_id, subject_type: user|group, subject_id,
     rights:[…]}`. Admin-only. The API keeps the shape validation (numeric ids,
     non-empty `rights`, object exists → 404) and **delegates all grant semantics to the
     model's `insert` overloads** (project pattern: the API only adds permission checks):
     `Model/AccessRight.pm#insert` (allowed classes via `get_classes` = Device, Ipblock,
     ContactList, Zone; find-or-create of the AccessRight row) +
     `Model/UserRight.pm` / `GroupRight.pm#insert` (join-row dedup and the `'none'`
     right semantics — legacy since `b912c1ed`). The model's `throw_user` is caught and
     mapped to a 400 (`$e->message`). Row removal goes through the generic
     `DELETE /api/userright/<id>` / `/api/groupright/<id>` (join row only — the shared
     AccessRight row stays). ⚠️ the overload takes a **hashref** (Pitfall §1).
   - **Device IP endpoints** (2026-10-14): `POST /api/device/:id/add_ip`
     (`Api#add_ip`), `POST /api/device/:id/auto_dns` (`Api#set_auto_dns`) and
     `POST /api/device/:id/regen_dns` (`Api#regen_dns`) — declared before the per-type
     routes so `add_ip`/`auto_dns`/`regen_dns` are not captured as `:id`.
 - `lib/Netdot/Mojo/OpenAPI.pm` — `build_spec()`: OpenAPI 3.0.3 from `Netdot->meta`
  (88 typed schemas + per-table paths + dedicated endpoints); `servers` from the
  `WEB_BASE_URL` prefix. Per-class **reference schemas** `FkReference_<Classe>` (`{id,url}`
  + the class's label fields from `Model::get_ref_field_spec`, built only for classes some
  FK points at) so the docs match the runtime nested reference; a FK property =
  `anyOf [integer, $ref FkReference_<Classe>]`.
- `api/gen_openapi.pl` — regenerator → `api/openapi.yaml` (re-run after model/spec changes).
 - **POD documentation (perldoc, 2026-10-14, commit `db43bcea`)** — every one of the
   26 `lib/Netdot/Mojo/**.pm` modules carries perldoc-readable POD, following the legacy
   `lib/Netdot/Model` convention (`Model.pm`, `Device.pm`, `Model/RRAttr.pm`): a
   `=head1 NAME` + `=head1 SYNOPSIS` + `=head1 CLASS METHODS` / `=head1 INSTANCE METHODS`
   header block (SYNOPSIS = real usage; for the controllers, the actual routes as wired
   in `Netdot::Mojo.pm`), then one `=head2 <name> — <one-line description>` block
   (`Arguments:` / `Returns:` / optional `Description:` + `=cut`) directly above every
   **public** sub — 117 subs documented, private `_` helpers excluded — plus
   `=encoding utf8` in the first POD region; the trailing `=head1 AUTHOR` /
   `=head1 COPYRIGHT & LICENSE` blocks untouched. Verified: `perl -c` clean on all 26;
   `podchecker` error-free (the lone remaining warning, "Verbatim paragraph in NAME
   section", is the same one the legacy `Model.pm` reference emits).
- `htdocs/management/{ipblock,rr,ipaddress,detail,search_results}.html.ep` — templates.
- **UI / design (2026)**: `htdocs/css/style.css` (the "MODERN DESIGN LAYER" at the bottom:
  sticky navbar, `datatable` look + rounded corners, **`table.datatable.detail` field tables**
  (multi-column via `c1`/`c2`/`c4` = 1/2/4 label|value pairs per row; `.attrgrid` is gone),
   **`.container` cards** (`.containerhead` title + `.containerbody`/`.containerbody.flat`
   for a flush field table), **`.cardrow`** (a responsive row of equal-width `.container`
   cards, side by side / wrapping; used by the Export page's 3 option cards, wrapped in an
   outer `.container` titled «Export third-party configurations…»), **`.tabcard`** (a single card framing the `.tabbar`
   + the active view's `.tabcard-body`; inner tables/section-cards are flattened so there's
   no card-in-card),
  `.tabbar`/`.tab-pane`, modern buttons, content links); `htdocs/login.html.ep` + `.loginbox`
  (stacked full-width fields, `.btn`, header "log in" button hidden on the login page via the
  `is_login` stash flag); `htdocs/java_script/tabs.js` (client-side tab switching, scoped to
  `.tabbar .tab[data-rel]` so `?view=` server-rendered tabs navigate normally, `?rel=` state);
  `htdocs/java_script/tablesort.js` (JS sort, `table.sortable` opt-in);
  `htdocs/management/{detail,device,ipblock,rr,ipaddress,zone,contactlist,closet}.html.ep`
  (details rendered as `datatable.detail cN` field cards + `.tabcard` tab sections +
  SQL-ordered relation tables); `htdocs/layouts/default.html.ep` (loads tabs.js, htmx).
  Convention: `class="datatable"` = modern look (every table), `class="sortable"` = JS-sort
  opt-in (list pages only), `class="datatable detail cN"` = a field table.
- `htdocs/export.html.ep` — Export form (types, zones, scopes, force, HINFO/TXT).
- `htdocs/advanced/changelog.html.ep` — Changelog (audit log) table.
- `htdocs/search/results.html.ep` — Global search results (RR name + zone).
- `htdocs/error_{403,404,500}.html.ep` — branded error pages (layout `default`).
- `htdocs/management/host.html` (1136 l.), `container.mhtml`,
  `htdocs/generic/view.html` — Mason references.
- `etc/netdot.meta` — FK/relations schema (`linksto`, `views`, `label`).
- `etc/Default.conf` — `REMOTE_PLUGIN`, `CHECKBOX_CHECKED_EXCLUDE_*`, export dirs.
  Auth section (top): `AUTHORIZATION_METHOD`, `DEFAULT_REMOTE_AUTHED_USER_TYPE`, and the
  `NetdotLDAP*` block (LDAP auth, re-used via `Netdot::Mojo::AuthShim` which emulates
  `$r->dir_config`). Dead keys `DB_NETDOT_HOST` + `INVENTORY_WARNING` removed (0 code refs;
  the code reads `DB_HOST`).
  Remote export: single `REMOTE_PLUGIN{PLUGIN}{DIR, SERVER, RELOAD, ENABLE}` (BIND, NAMED,
  RFC952, APACHE, UNILSTAT) replaces the old scattered keys + global `REMOTE_EXEC`;
  `ENABLE` per plugin gates the `scp SERVER:DIR` + `ssh SERVER 'RELOAD'`. Export dirs
   (`BIND_EXPORT_DIR`, `NAMED_DIR`, `RFC952_DIR`, `Apache_DIR`) are arrayrefs (primary +
   copies); `Git_*_DIR` removed (staging is just a list entry; `GIT.pm` uses `Git_DIR`).
   DNSSEC flag: NAMED's `DNSSEC: inline` hack in free-text `zone.info` replaced by a real
   `zone.dnssec` bool column (`NAMED.pm` reads it; set flag => `inline`-signing block, the
   only mode; `HIDDEN` stays in `info`). Files: `netdot.meta` (column + Zone `all` view),
   `Zone.pm` (insert/copy), `NAMED.pm`. Migration in `upg_107_200` (1.x→2.0.0):
   `ALTER TABLE zone ADD COLUMN dnssec ... DEFAULT 0` (strict mode rejects SQLT's
   `DEFAULT 'false'` on bools => fresh `initdb` still to fix in SQLT). Bool columns render
    `Yes`/`No` (HTML detail) / `true`/`false` (API JSON) via the shared `attr_display`
    helper (build_attrs, Device, Closet, Interface).
   `etc/Site.conf` (gitignored) is now a **full mirror of `Default.conf`** — same key order and
   same section comments, with only the site's divergent values (68 keys) overridden. So
   `diff -NaBbur Site.conf Default.conf` isolates the site customizations. Verified: effective
   config unchanged, no `<<Make:PREFIX>>` markers, all 5 `REMOTE_PLUGIN` plugins + `LOG_OPTIONS`
   (18 newlines) load via `Netdot->config`.
 
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
  - Done: **PhysAddr / MAC** (`Controller/Physaddr.pm`): detail (`management/mac.html.ep`,
    port of `mac.html`) — MAC attributes (address, vendor/OUI link, static, **First/Last
    Seen**), the devices + interfaces using the address, the edge port, the last-N
    forwarding-table and ARP entries, the DHCP scopes. **MAC search**
    (`/management/physaddr/search?search=…`, port of the `mac.html` search):
    `PhysAddr->search_like(address=>…)` (full MAC or OUI prefix); one match → redirect to the
    detail page, several → a results table with **MAC Address · First Seen · Last Seen**
    columns (sortable), none → not found.
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
     **Write (2026-10-14)**: edit mode (`editips`) — per-IP row delete
     (`DELETE /api/ipblock?id=…`), interface select + monitored per IP
     (`PATCH /api/ipblock/<id>`), per-DNS-name delete (device-name protected
     UI-only, as in Mason), per-service delete (`DELETE /api/ipservice/<id>`);
     add-IP mode (`add_ip` → `POST /api/device/<id>/add_ip`); inline add-service
     form (port of the `addservice.html` popup → `POST /api/ipservice`; Mason's
     side effect kept: adding a service sets the IP `monitored`); the DNS options
     box (`auto_dns` toggle + "Regenerate DNS" → `POST /api/device/<id>/auto_dns`
     / `/regen_dns`). [Edit]/[Add] buttons in the toolbar **above** the table
     (UI convention). `Registry`: `ipservice` registered link-only (`nav => 0`).
   - BGP = `get_bgp_peers` (internal→external→all, `peersort`): section header
     rows "External (eBGP)" / "Internal (iBGP)", Remote IP (linked to the /32), ID,
     Entity (linked), AS Name, AS Number (**whois link** from the config
     `BGP_AS_WHOIS_URL` with the `<ASNUMBER>` placeholder; eBGP skips the private
     ASN range 64512-65535, iBGP links all), State, **Monitored?**, Contact List;
     info = BGP ID + Local AS (linked to the ASN). **Write (2026-10-14)**: the info
     box is editable — BGP ID → `PATCH /api/device/<id>`, the **local AS number →
     `PATCH /api/asn/<id>`** (the linked ASN's `number` column, as in Mason;
     `netdot.js initBgpInfo` sends one PATCH per changed field, the ASN id comes
     from `data-nd-asn-id`); per-peer edit (`bgppeeraddr`/`monitored`/`contactlist`
     → `PATCH /api/bgppeering/<id>`, the table-aware `initIntEdit` via
     `data-nd-table="bgppeering"`), per-row delete (checkbox → ONE batch
     `DELETE /api/bgppeering?id=…`) and **peer add** (`POST /api/bgppeering
     {device, bgppeeraddr, bgppeerid, entity, state, monitored, contactlist}`,
     `initBgpAdd` — the NOT NULL columns left out of the form are defaulted by the
     model insert's `_adjust_vals`, same as the legacy SNMP insert). The [Edit]/[Add]
     toolbar sits above the table; [Add] is visible even when the peer list is empty.
     The peers class is `BGPPeering` (table `bgppeering` — the API URL uses the table
     name). Hosted = `hosted_devices`. Circuits = `get_circuits` (cid/type/
     vendor/status/speed). STP = stp_enabled/stp_type + `stp_instances`.
     Modules = `modules` (flat). Audit = `get_audit_records`.
   - Model return types: `get_ips`/`get_bgp_peers` → arrayref; `stp_instances`,
     `modules`, `get_circuits`, `get_audit_records`, `hosted_devices` → list
     (`my @l; eval { @l = $o->m };`).
  - **Basics edit form** now via the shared `_edit_form.html.ep` partial (scalar + FK
    fields → JSON API PATCH; fields computed only on the Basics view so the other tabs
    stay cheap). Deferred (Device): **Topology (graph) only** — the other
    write/edit actions are ported (Interfaces 2026-10-13, Neighbor/IP/BGP/Access
    Rights 2026-10-14, see below).
- Done: **Reports — 10/10** (`Controller/Reports.pm`): device, asset, ip, macs,
  topology, pollstats, database, custom (hinfo/usedby), ipbat, security.
  Gated by `access_section` (Admin+Operator). Generic FK-cell linking
  (`_obj_html` + `_normalize_rows`). Filter re-application via `search_like()`.
- Done: **Export** (`Controller/Export.pm`, `/export`): 12 types via
  `Netdot::Exporter->generate_configs`. Permission: `Permissions::can_export`
  (write rights on RR). Admin sees all 12; write-rights users see 4 (BIND,
  NAMED, RFC952, DHCPD). Log captured via Log4perl String appender.
   Config: `REMOTE_PLUGIN` (per-plugin `ENABLE`) + `CHECKBOX_CHECKED_EXCLUDE_*` in
   `etc/Default.conf`. Playbook fix: `yaml_str` helper (YAML single-quote escaping) +
   `str2time // 0` sort fix.
   Runtime fixes (Perl 5.40): `$#$ref` (arrayref last-index) was removed in 5.30+ and
   mis-parses to a non-array at runtime — replaced with `@c = @{…}; shift @c` in
   `NAMED`/`RFC952`/`Apache`/`BIND` exporters and `$last = @$list - 1` in
   `Controller/Device` `_chunk` (real-array `$#arr` still works). `Sysmon.pm` had a
   syntax error at the `unless … {target_version}` line (bad `}`) that blocked the whole
   module → now `unless ( … ) {`. `Git_BRANCH` was missing from the config (GIT.pm
   `get()`s it) → added `Git_BRANCH => 'master'` to `Default.conf`/`Site.conf`.
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
  - Done: **Nested FK reference format** (`Model::get_ref_field_spec` + `get_hashref`,
    `Api.pm::_ref`, `OpenAPI.pm` per-class `FkReference_<Classe>`): a foreign key renders on
    read as `{id, url, …label fields}` (zone `{id,url,name}`, ipblock `{id,url,address,prefix}`,
    rr `{id,url,name,zone}`) instead of `label` + `<col>_xlink`. `get_hashref` derives from
    `get_ref_field_spec` (one source, so docs and runtime can't drift); an FK label field →
    `get_label` one level (no infinite loop); FK null → `null`; `depth>0` → full object.
   - Done: **Read-only polish** (2026-10-03): Device **Access Rights** tab (`Device.pm`
     `Rights` view); NS/MX/TXT/NAPTR related-record navigation (types `rrns/rrmx/rrtxt/
     rrnaptr` registered, `nav=>0`, host-page "Record" link → each record's detail page);
     Ipblock **ASN link** + **v4/v6/all selector** + **utilization toggle**; **Closet picture
     display** (binary `bindata` serving); **generic per-type search** (all list types,
     `Browse#search`).
    - Done: **UI modernization (2026 design, 2026-10-04..06)**: client-side tabs
      (`java_script/tabs.js`, instant pane switching + `?rel=` URL state, htmx-safe event
      delegation; selector scoped to `.tabbar .tab[data-rel]` so `?view=` server tabs work),
      **`table.datatable.detail` field tables** (multi-column `c1`/`c2`/`c4` = 1/2/4 label|value
      pairs per row — replaces the old attribute `<table>` AND the now-removed `.attrgrid`),
      **`.container` field cards** (`.containerhead` title + `.containerbody.flat` flush field
      table), **`.cardrow`** (responsive row of equal-width `.container` cards — the Export
      page's 3 option cards wrapped in an outer card titled «Export third-party configurations…»), **`.tabcard`** (one card
      framing the tab bar + active content, inner content
      flattened), `datatable` (modern table look, all tables) / `sortable` (JS-sort opt-in,
      list pages only), sticky navbar, modern buttons, content links (underline on hover),
      **login page** (stacked full-width fields, `.btn`, header "log in" hidden via `is_login`),
      **CSS cleanup**: removed dead legacy classes — orphaned (`.attr*`, `.devgrid`, legacy
      `.container*` duplicates, `*outside`, `containerseparator`), legacy table/form
      (`formtable*`, `datatabler*`, `tabletitle`, `containertable*`), `empty000000`, old-login
      (`#loginform`/`logintable`). `.containerhead` = single selector; table zebra now from
      `datatable tbody tr:nth-child` (not `datatablerN`). **Kept** `ipcontainertable` and
      `ipaddr_*` (+`_2`) — the latter is built **dynamically** in `Ipblock.pm`
      (`'ipaddr_' . lc($status)` + `._2`), so a dead-class sweep must search all of `lib/` and
      check dynamic construction (the model also emits HTML).
      **Report data tables modernized** (`reports/data_table.html.ep`): shared by all 10
      reports, rebuilt to `<thead>`/`<tbody>` `datatable` (dropped the legacy
      `formtabletitle`/`datatablerN` cell classes) so the header/zebra/rounded corners
      match the rest of the design.
      **SQL relation ordering/pagination** (`Detail.pm`: Ipblock by integer
      `address`, relationship label columns via JOIN — a device orders by `rr.name`).
      **Site/Floor picture display** (`Show.pm#picture` + `link_for` Picture special-case).
   - Done: **Fixes (2026-10-05)**: device free-text search targets `rr.name`
     (relationship-aware `_list_add_like`, `%q%` contains); `/search` results table header
     dedup (was 3 headers / 2 columns → now 2 = 2); `/help/database` bool defaults rendered
     `true`/`false` (`Meta/SQLT.pm` dereferences the scalar-ref default, was `SCALAR(0x…)`).
    - Done: **Ipblock Access Rights tab (2026-10-11)**: `?view=Rights` on the block detail page
      (visible to Admin/Operator via `access_section` guard, editable by Admin only). Lists all
      (subject, access) pairs: `AccessRight->search(object_class='Ipblock', object_id=…)` →
      `->user_rights` / `->group_rights`. Adding rights POSTs JSON `{object_class, object_id,
      subject_type, subject_id, rights:[…]}` to `/api/accessright`; the model's `insert` overload
      (`AccessRight.pm`) finds-or-creates each AccessRight row then inserts the join row
      (userright/groupright) via their own `insert` overloads (dedup + `none` semantics). Removing
      a right does `DELETE /api/userright/<id>` or `/api/groupright/<id>` (the join row only —
      the shared AccessRight row stays). JS: `initRights()` in `netdot.js` handles the add form
       (`.nd-rights-add`) and delete buttons (`.nd-rights-del`).
    - Done: **Ipblock section deletes + range + batch edit (2026-10-12)**:
      - **Section deletes**: Sites (`/api/sitesubnet`), Forward Zones (`/api/subnetzone`,
        direct only), DHCP (`/api/dhcpscope`), Attributes (`/api/ipblockattr`) each have a
        per-row "Remove" button (`.nd-sec-del`, JS handler in `initRights`). The "Add attribute"
        select excludes names already present on the block.
      - **Add IP Range** (Subnets, Children view): "Range" button in the view toggle bar.
        Click → grid enters range mode (crosshair, mousedown/mouseup = start/end, blue
        highlight via `.ipaddr-range-selected`, auto-swap if start>end numerically). A
        draggable centered panel (`.nd-range-panel`) shows: start/end (editable, pre-filled
        with first/last usable IP via `NetAddr::IP->first/last`), status, owner, used_by,
        description, gen_dns checkbox, DNS prefix/suffix (defaults from config
        `IP_RANGE_DNS_DEFAULT_PREFIX/SUFFIX`), forward zone (pre-selected = block's
        `forward_zone()` which walks up ancestors, fallback `DEFAULT_DNSDOMAIN`).
        API: `POST /api/ipblock/:id/range` → `$o->add_range(start,end,status,…)`
        (model creates /32 or /128 blocks). Grid cells carry `data-nd-ip` for JS.
        JS: `initRange()` in `netdot.js`.
      - **Batch Edit + Edit** (Children, list mode): two buttons, both backed by ONE
        request, `POST /api/ipblock/batch` (`Api#batch`):
        `{updates:[{id, status?, owner?, used_by?, description?}], deletes:[id…]}`
        → `{updated, deleted, errors{per id}}`, 200 if at least one op applied. The
        route is registered BEFORE `/api/:table/:id` (else "batch" is captured as
        `$id`). Per-id existence + permission checks; deletes run first; only the
        whitelisted fields are written. "Batch" → row checkboxes (`.nd-batch-chk`) +
        draggable panel (status filtered by parent type: Subnet→Dynamic/Reserved/
        Static, Container→all; owner, used_by, description; delete checkbox).
        "Edit" → inline editable cells in the table: status select ("-- No change --"
        = keep), owner/used_by selects ("—" = clear), description input, per-row
        delete checkbox + "check all" header. JS sends ONLY dirty fields (compared
        against `data-nd-stid`/`data-nd-own`/`data-nd-ub`/`data-nd-desc`), so the
        audit trail records only real changes (`Netdot::Model` after_update trigger
        logs only columns whose value changed). JS: `initBatch()` +
        `initEditChildren()`. Data via `window.ND_BATCH_DATA` (statuses + entities).
      - **Fix `Registry::link_html`**: `my ($t,$h) = link_for($v)` did not dereference
        the returned arrayref → `$h` was always undef → every FK link (owner/used_by
        in the children list, etc.) rendered empty. Fixed to `@{ link_for($v) }`.
    - Deferred: Device **Topology (graph)** tab; HTML write/edit pages (the **API** now
      covers authorized writes). Not ported by design: Ipblock **REBUILD_TREE** (debug
      only) and **ADD_BLOCKS** (bulk create — one block at a time suffices; router
      discovery creates the blocks).
   - Done: **Device creation (2026-10-12)** — the two Mason creation modes, admin-only:
     - **Manual add** (`device_tasks.html` « Add Device manually »): the device list
       page shows **two distinct boxes** like Mason's `device_tasks.html?view=new` —
       « Discover Device » (name/IP + SNMP version + community → POSTs the wizard)
       and « Add Device manually » (name/IP only; `Browse::list` stashes
       `new_device_manual` when type=device and the user is Admin) →
       `POST /api/device/manual_add` `{host}` →
       `Device->manual_add($host)` (DNS resolve, insert monitored/`snmp_managed=0`,
       `add_interfaces(1)`, /32-/128 block + Static status, `snmp_target`, ARP neighbor).
       Route registered **before** `/api/:table` (else captured as table/id). UI:
       `initForms` + `data-nd-redirect` → device detail.
     - **SNMP discovery wizard** (`updatedevice.html` 2 steps): `GET|POST
       /management/device/discover` (route **before** the per-type `/management/$t/:id`
       loop), `Controller/Device.pm#discover` + `management/device_discover.html.ep`
       (3 modes: form / review / result). Step 1 runs `Device->get_snmp_info` (form host
       + v1/v2 community from `DEFAULT_SNMPCOMMUNITIES`/Other, or v3 sec fields; or
       `?device=<id>` re-poll with the device's stored credentials — « SNMP update »
       button on the device detail, admin-only). Review: sysdescription + guessed Owner
       (`DEFAULT_DEV_OWNER`), Used by (first IP's subnet `used_by`), Site (entity sites,
       fallback `Site->search_like(name=>"%$syslocation%")`), Contacts
       (`DEFAULT_CONTACTLIST`), `add_subnets`/`subs_inherit` when `ipforwarding`
       (defaults from `ADDSUBNETS`/`SUBNET_INHERIT_DEV_INFO`); existing device → only
       the `pretend` dry-run checkbox. **Stateless**: the SNMP info hash is too large
       for the signed-cookie session → step 2 re-runs the same query (hidden echoed
       args) and calls `Device->discover` (new device: reviewed owner/used_by/site/
       contacts arrayref; existing: `name=>fqdn, info, do_info, pretend`). Result: the
       model log captured with a `Log::Log4perl::Appender::String` appender on the
       `Netdot::Model::{Device,DNS,Ipblock}` loggers (the Mason trick), filtered to
       lines mentioning the host, + link to the device.
     - Fixes (2026-10-13): `Device->manual_add` throws a clear « already exists »
       error when the RR name is taken. (An earlier revision here tried to convert
       the IP to numeric before `find_or_create` via `NetAddr::IP->addr` — a
       no-op, `->addr` returns the dotted/hex string; the real fix is the
       `Ipblock->search` hashref normalization below. `manual_add` passes the
       resolved dotted/hex string again.) The
       Used-by guess reads `ips->{$ip}{subnet}` (« addr/len », what `get_snmp_info`
       actually stores from the device's ipNetToMedia table; `->{mask}` — what Mason
       read — is never set by the current `get_snmp_info`, so the Mason guess was
       silently dead). API/wizard error handling extracts `->message` from Netdot
       exceptions (a `throw_fatal` stringifies with its full stack trace).
     - SNMP MIBs: `get_snmp_info` passes the configured `SNMP_MIBS_PATH` /
       `SNMP_MIB_DIRS` dirs to SNMP::Info (`MibDirs`, → `SNMP::addMibDirs`); on this
       box that is `/var/lib/netdisco-mibs` (Site.conf). No `MIBDIRS`
       env var needed — the system `/usr/share/snmp/mibs` being empty is fine.
      - **Unified device API (2026-10-13)** — device create + SNMP update as REST;
        the generic `POST /api/device` insert is intentionally unreachable (the
        static routes win over `/api/:table`):
        - `POST /api/device` (admin-only): `{discover:false, host}` →
          `Device->manual_add`; `{discover:true, name, snmp_version, community |
          v3 sec_name/sec_level/auth_*/priv_*}` → `get_snmp_info` +
          `Device->discover` (optional owner/used_by/site/contacts/add_subnets/
          subs_inherit). Existing name → 409 pointing at the update endpoint.
          Returns 201 + full device JSON. Replaces `POST /api/device/manual_add`.
        - `POST /api/device/:id/update` (admin-only): SNMP update (re-poll) of an
          existing device with its **stored** credentials
          (`get_snmp_info()` + `Device->discover(name=>fqdn, info, do_info=>1,
          [pretend])`); optional `pretend` dry-run. Replaces the legacy
          `POST /api/updatedev` (removed) and the wizard's `?device=<id>` re-poll.
        - `Api.pm`: `_is_true` helper, `create_device`, `update_device`; routes
          declared before the generic `/api/:table` loop. Frontend « Add Device
          manually » box POSTs `/api/device` with hidden `discover=false`.
        - **List page UI (2026-10-13)**: the device list shows **only** the two
          dedicated boxes (no generic « New Device » insert form — `Browse.pm`
          skips `new_obj` for `device`; the container renders on
          `$new_obj || $ndm`). The « Discover Device » box has a version
          selector (1/2/3) and, as in Mason's `device_tasks.html`, the v3
          security fields (sec_name/sec_level/auth_proto/auth_pass/
          priv_proto/priv_pass) are shown **only when version=3** via the
          existing `showSnmpV3Args()` JS (`toggle.js`), pre-filled from the
          `DEFAULT_SNMP_*` config values; the v1/v2 community row is hidden in
          v3 mode (still posted, ignored by the wizard, as in Mason).
          `create_device` applies the same `DEFAULT_SNMP_*` fallback for
          missing v3 fields, so `{discover:true, name, snmp_version:3}` works
          with the configured default credentials.
        - **Fixes (2026-10-13)**: the initial show/hide of the v3/v2 divs is
          emitted with a `<% %>` code block, not `<%= %>` — the escaped
          `style=&quot;display:none&quot;` attribute is not applied, which left
          the v3 fields visible on load. `other_comstr` is now hidden until
          « Other » is selected (Mason behaviour: `otherOption()` /
          `backSelectOpt()` from `toggle.js`, hidden `<` back button). The
          re-poll hint line in the box was dropped (useless — see the
          per-device update route below).
        - **Re-poll route (2026-10-13)**: `GET /management/device/<id>/update`
          (`device#update`, admin-only, declared before the per-type
          `/management/$t/:id` route); the device detail « SNMP update »
          button points there instead of the wizard’s `?device=<id>` (whose
          GET now redirects to it). Superseded 2026-10-13 (see below): the
          page is display-only and the mutation is the API’s
          `POST /api/device/<id>/update`.
        - **All DB writes via the API (2026-10-13)** — architecture rule:
          `/management` is display / validation / info-request only; every
          mutation goes through the JSON API. Applied to the device
          discovery flow:
          - The wizard is display/validation only. The review confirm calls
            the API from the browser (`netdot.js initDiscRun`, forms with
            class `nd-disc-run`): new device → `POST /api/device
            {discover:true, name, snmp_version, community (resolved from
            comstr/other_comstr), v3 sec_* echoed as-is, owner/used_by/
            site/contacts, add_subnets/subs_inherit}`; existing device →
            `POST /api/device/<id>/update` (stored credentials, optional
            `pretend`). Multi-selects: `collect()` is single-value for
            `<select>`; `initDiscRun` maps `selectedOptions` to an array for
            `[multiple]` fields (Contacts).
          - `POST /api/device` (discover) and `POST /api/device/:id/update`
            now capture the model log (the Mason `Log::Log4perl` String
            appender trick on the `Netdot::Model::{Device,DNS,Ipblock}`
            loggers, filtered to lines mentioning the host —
            `Api.pm::_discover_captured`) and return it as a `log` array in
            the 201/200 JSON. The UI renders it client-side in the
            `.nd-disc-result` box next to the form (plus the « Go to device
            » link from the form’s `data-nd-dev-url` attribute + response
            `id`); a dry run keeps the form visible (re-runnable).
          - `GET /management/device/discover` is no longer a standalone
            page: bare GET → 302 to the device list (the « Discover Device
            » box is the entry point: POST `action=discover`, read-only
            `get_snmp_info` + review render); `?device=<id>` → 302 to
            `/management/device/<id>/update`.
          - `GET /management/device/<id>/update` no longer mutates: it is
            the display-only re-poll page (stored credentials, dry-run
            choice) whose button calls `POST /api/device/<id>/update`.
          - Removed from the /management layer: the `action=update` branch,
            `_disc_update` / `_disc_result`, the template `mode=result`
            (client-rendered now) and the dead repoll mini-form branch.
          - Fix (2026-10-13): the `nd-disc-run` forms also matched the generic
            `initForms` selector `form[data-nd-api]`, so submitting the review
            / re-poll form fired **two** API POSTs — the first created the
            device (201), the second hit the 409 « device already exists ».
            `initForms` now skips `nd-disc-run` forms (same pattern as
            `nd-dhcp-enable` / `nd-rights-add`).
          - The review form now sends **only API field names**: v1/v2 → the
            resolved `community` (the raw `comstr` / `other_comstr` /
            `version` query args are no longer echoed); v3 → only the
            non-empty `sec_*` / `auth_*` / `priv_*` fields (same names as
            the API; empty ones are omitted so the API's `DEFAULT_SNMP_*`
            config fallback applies).
         - **Fix (2026-10-13): `Ipblock->search` hashref path ignored the
           address normalization** — the root cause of the `manual_add`
           `Duplicate entry '…-32' for key 'ipblock1'` failure. `ipblock.address`
           is a numeric column (decimal integers, v4 AND v6); the `search`
           override normalizes a dotted/hex/CIDR `address` (via `ip2int`) **only
           in the list-args path** (`search(address=>…)`) — a single hashref
           (`search({address=>…})`, what Class::DBI's `find_or_create` uses)
           is popped into `$opts` by the `@args % 2` options trick and skips the
           conversion, so MySQL coerced `'10.50.24.12'` → `10` (leading digits
           on a decimal column), the search matched nothing, and
           `find_or_create` re-inserted the (already converted) address →
           duplicate key. Fix: a `_normalize_search_address` helper (CIDR →
           int+prefix; dotted/hex → `ip2int` for v4 and v6; invalid →
           `throw_user`; already-numeric unchanged) is now applied to **both**
           the list-args and the hashref path, so `find_or_create` finds the
           existing block (verified: `find_or_create({address=>'10.50.24.12',
           prefix=>32})` and `({address=>'2001:620::', prefix=>48})` both
           reuse the existing row; `manual_add` on an existing block reuses it
           and sets Static/interface/monitored). Note: Perl `return (A, B)` in
           scalar context yields the last element — the helper's call sites use
           list context. (Also observed while testing: a 37+ digit integer
           literal in Perl becomes a double and stringifies to scientific
           notation, failing the `^-?\d+$` check — all real callers pass
           strings, so no production impact.)
         - **Interfaces tab edit/delete (2026-10-13)** — port of Mason's
           `interfaces.mhtml` `?editints=1`, display/validation only: the
           `[edit]` link (can-edit) adds `&editints=1`; the table switches to
           Mason's edit layout ([del] checkbox + Number / Name / Jack / Descr.
           inputs, Speed/VLAN/Status/Connected hidden; Jack/Descr. columns
           always shown in edit mode, as in Mason) and the mutations go
           through the JSON API (architecture rule):
           - `Controller/Device.pm#_interfaces`: `editints` param; each row
             carries `id` + `edit` values (number/name/description/jack id +
             label); the Jack cell is a plain `<select>` fed by the device
             room's closet jacks (`room->closets` → `horizontalcables`,
             sorted by label) when that list is ≤ `DEFAULT_SELECTMAX`
             (Mason's `select_lookup` defaults), else the keyword-search
             picker (`nd-fk-search`, target `horizontalcable`).
           - `device.html.ep`: the edit table sits in a
             `form.nd-if-edit` (`data-nd-api-base`, no `data-nd-api` — it must
             NOT be picked up by `initForms`); per-row inputs carry
             `data-nd-f` + `data-nd-orig` (the rendered value). Save/Cancel
             row; Cancel goes back to the plain view.
           - `netdot.js initIntEdit`: on Save (or Enter — form submit is
             intercepted), only DIRTY fields per row are collected (current
             value ≠ `data-nd-orig`; number compared as int, selects '' =
             null); each dirty row → `PATCH /api/interface/<id>` (generic
             router, per-object edit right on the parent Device), checked
             rows → ONE `DELETE /api/interface?id=1,2,3` (batch delete,
             per-id permission + {deleted, skipped} report). Per-id error
             report; full success → reload.
           - Not ported yet (Mason's Options box): « Manually Add N
             interfaces » (`Device->add_interfaces`) and « SNMP Updates
             Overwrite Descriptions » (`set_overwrite_if_descr`) — both need
             dedicated API endpoints (model actions, not plain column
             writes).
         - **Device IP tab write (2026-10-14, commit `f0c1285a`)** — port of
           Mason's `ip.mhtml` `?editips=1` + `add_ip`, display/validation only:
           edit mode reuses the **table-aware `initIntEdit`**
           (`form.nd-if-edit` with `data-nd-table="ipblock"` + `data-nd-api-base`):
           per-IP row delete (`.nd-if-del` checkbox → ONE batch
           `DELETE /api/ipblock?id=…`), interface select + monitored per IP
           (`PATCH /api/ipblock/<id>`), per-DNS-name delete (`.nd-cell-del`; the
           device-name protection is UI-only, as in Mason — the API would allow
           it), per-service delete (`.nd-cell-del` → `DELETE /api/ipservice/<id>`).
           Add-IP mode: `POST /api/device/<id>/add_ip` (`Api#add_ip`). The inline
           **Add service** form ports the `addservice.html` popup
           (`POST /api/ipservice`); Mason's side effect is kept (adding a service
           sets the IP `monitored`). The **DNS options** box: `auto_dns` toggle +
           "Regenerate DNS" → `POST /api/device/<id>/auto_dns` (`Api#set_auto_dns`)
           / `POST /api/device/<id>/regen_dns` (`Api#regen_dns`) — declared before
           the per-type routes so the words are not captured as `:id`. `Registry`:
           `ipservice` registered link-only (`nav => 0`). [Edit]/[Add] buttons in
           the toolbar **above** the table (UI convention); the sort links no
           longer duplicate the `view` param.
         - **Device BGP tab (2026-10-14, commits `bb62e9d1` + `0c666a6b`)** —
           display parity with Mason's `device.html` BGP section: the "Device BGP
           Info" box (BGP ID + Local AS, the ASN linked via `bgplocalas`) and the
           BGP Peers table (section header rows "External (eBGP)" / "Internal
           (iBGP)" + spacer; Remote IP linked to the /32 ipblock; ID; Entity
           linked; AS Name; AS Number with the **whois link** from the config
           `BGP_AS_WHOIS_URL` (`<ASNUMBER>` placeholder; eBGP skips the private
           ASN range 64512-65535, iBGP links all); State; **Monitored?** — the
           initial port missed this column; Contact List). Writes: the info box
           is editable — BGP ID → `PATCH /api/device/<id>`, the **local AS number
           → `PATCH /api/asn/<id>`** (the linked ASN's `number` column, as in
           Mason; `netdot.js initBgpInfo` sends one PATCH per changed field, the
           ASN id comes from `data-nd-asn-id`, empty id = no local AS = no ASN
           PATCH); per-peer edit (`bgppeeraddr`/`monitored`/`contactlist` →
           `PATCH /api/bgppeering/<id>`, the table-aware `initIntEdit` via
           `data-nd-table="bgppeering"` — section rows carry no `data-nd-if` so the
           JS skips them); per-row delete (checkbox → ONE batch
           `DELETE /api/bgppeering?id=…`); **peer add** (`POST /api/bgppeering
           {device, bgppeeraddr, bgppeerid, entity, state, monitored,
           contactlist}`, `initBgpAdd` — Mason has no manual add (peers come from
           the SNMP poll); the NOT NULL columns left out of the form
           (`max_v4/v6_prefixes`, …) are defaulted by the model insert's
           `_adjust_vals`, same as the legacy SNMP insert). The [Edit]/[Add]
           toolbar sits above the table; [Add] is visible even when the peer list
           is empty (the "if a peer is missing, it must be addable" requirement).
           The peers class is `BGPPeering` (table `bgppeering` — the API URL uses
           the table name). Functional Node DOM-stub tests
           (`/tmp/js_bgp_test.js`): edit (dirty-fields PATCH + batch
           DELETE), info (device + asn PATCHes), add (POST body) — all PASS.
         - **Device Access Rights (2026-10-14, commit `bb62e9d1`)** — port of
           Mason's Rights section: same mechanism as the Ipblock Rights —
           User/Group rows (subject linked + right name), per-row Remove
           (`DELETE /api/userright|groupright/<id>`, generic) and the "Add rights"
           form (Admin) → `POST /api/accessright`. The handler was **missing**
           before (the Ipblock add form pointed at a nonexistent endpoint); both
           the Ipblock and the Device forms post to the SAME endpoint. The tab is
           gated by `access_section 'device.html:edit_rights'` (Admin/Operator
           view, Admin write) via the stashed `show_rights`. **Refactor
           (`23a9e013`)**: the first cut of `Api#accessright` duplicated the grant
           logic (CDBI `find_or_create` of the AccessRight + join rows, its own
           `{Device, Ipblock}` whitelist) — violating the project pattern (the API
           only adds permission checks; domain logic lives in the model). It now
           **delegates to the model's `insert` overloads**: `Model/AccessRight.pm`
           (allowed classes via `get_classes`, find-or-create of the AccessRight
           row) + `Model/UserRight.pm` / `GroupRight.pm` (join-row dedup and the
           `'none'` right semantics, legacy since `b912c1ed`). The API keeps:
           Admin-only, shape validation (numeric ids, non-empty `rights`), object
           existence (404), and maps the model's `throw_user` to a 400
           (`$e->message`). ⚠️ the overload takes a **hashref** — the first cut
           called it with a key/value list (`Can't use string ("object_class") as
           a HASH ref`); the fix (commit `76e6d26c`) wraps the arguments in
           `{…}`.
          - **Fix JSON boolean writes (2026-10-14, Pitfall §6)** — `PATCH /api/…`
            with a JSON `true`/`false` body (e.g. the Device Basics checkboxes)
            400'd: `req->json` decodes booleans to blessed `JSON::PP::Boolean`
            scalars and `Model::_audit` (the `after_insert`/`after_update`
            trigger) assumed blessed ⇒ Netdot object → `->get_label()` crash.
            Two fixes: (1) `Api.pm::_args` normalizes every blessed non-HASH/
            ARRAY value to plain `0 + $v` at the JSON boundary (all write
            handlers route through it); (2) `Model::_audit` (insert + update
            branch) only calls `get_label` on `blessed && $v->can('get_label')`.
            The original normalization loop was a **silent no-op** — it read
            `$a->{$k}` (the *global* sort variable `$a`, a leftover hashref
            from the last `sort`) instead of the local hash element `$a{$k}`;
            `perl -c` passed and nothing warned. Also observed: the audit crash
            happens in the `after_update` trigger AFTER the UPDATE, so a 400
            PATCH still leaves the changed values committed — re-sending the
            same payload is a no-op → 200 ("1st post fails, 2nd passes").
            Verified: `collect_stp` 0→1 / repeat / 1→0 all 200, audit `vals`
            records `1`/`0` correctly, device state restored. Commit `76e6d26c`
            (« Fix boolean issue »).
 - Done: **POD documentation (perldoc)** (2026-10-14, `db43bcea`) — all 26
   `lib/Netdot/Mojo/**.pm` modules documented per the legacy `lib/Netdot/Model`
   convention (NAME / SYNOPSIS / CLASS|INSTANCE METHODS + one head2 block per public
   sub; see the Key files entry above).
