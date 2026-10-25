# Docker — build & test

Build and run the Netdot 2.0 application image.

The image contains **the application only** (the Hypnotoad pre-fork server),
listening on `0.0.0.0:3000` by default. There is **no reverse proxy** inside
the image — put your load balancer / ingress in front. The **database is
external**: the image never runs one; it connects to a MySQL/MariaDB you
provide.

The `Dockerfile` builds from the directory that contains it (the working
tree) via `make install`. Every dependency comes from a Debian distribution
package — there is no compiler in the image.

## Build the image

Tag the image after the commit you build from, so each test build is
traceable (no git tag needed per commit):

```bash
V=v2.0.0-dev-$(git rev-parse --short HEAD)
docker build --build-arg NETDOT_VERSION=$V -t netdot:$V .
```

`NETDOT_VERSION` is embedded in the image as a `netdot.version` label (it is
optional — omit `--build-arg` if you only care about the image tag).

> The image is built from the working tree, so uncommitted changes are
> included too. That is the intended behaviour for iterating on the
> in-progress 2.0 work. For a public release, build from the sanitized
> public repository instead.

## Run / test the image

There are two deployment modes, depending on who provides the database:

* **Internal database** — the database runs with the application (the
  docker compose test stack). The stack creates and provisions the database
  itself; no external database is involved.
* **External database** — the database is provided by someone else: the
  DBA on the Docker host, or a separate server. In this mode the database
  and the application account must already exist (pre-provisioned by the
  DBA, with the privileges to apply and upgrade the schema — full
  privileges on the database). The image never creates them; it connects
  as the application account and, depending on the schema version stored in
  the database, applies the schema + seed data (first boot), runs the
  upgrade (outdated version), or does nothing (up to date).

The **Helm chart supports the external mode only** (it deploys the
application only).

### Networking primer — where is the database?

A container's `localhost` / `127.0.0.1` refers to **the container
itself**, not the Docker host. With the default bridge network, a database
listening on the host's `127.0.0.1` is therefore **not reachable** from the
container. How you reach it depends on where the database listens:

| Database listens on     | How the container reaches it |
|-------------------------|------------------------------|
| Host loopback (`127.0.0.1`) | `--network host` — the container shares the host's network namespace, so `127.0.0.1` inside the container *is* the host loopback. (Or republish the database on a non-loopback interface.) |
| Host non-loopback IP    | Default bridge + `DB_HOST=<host-IP>`. On Linux, the bridge gateway (typically `172.17.0.1`) reaches the host. |
| Another machine         | Default bridge + `DB_HOST=<db-host>`. |

### Mode 1 — internal database (docker compose, test stack)

The simplest isolated test: `docker compose` starts a companion MariaDB and
the application on the same Docker network (the app uses `DB_HOST=db`):

```bash
docker compose up -d        # → http://localhost:3000/
```

On first boot MariaDB creates the database and the application account
(built-in behaviour of the image), then the app container waits for the
database and applies the schema + seed data as the application account;
subsequent boots are no-ops.

* Overridable variables (defaults shown): `NETDOT_DB_PASSWORD`
  (application account password, default `netdot_pass`), `DB_ROOT_PASSWORD`
  (MariaDB root password, default `netdot_root`), `NETDOT_VERSION`
  (optional image tag, for traceability). Override them in the environment
  or a `.env` file.
* The credentials default to local-trial values — override them for
  anything longer-lived.
* To wipe the test database and start from scratch: `docker compose down
  -v` (removes the `dbdata` volume).

### Mode 2 — external database

**Database on the Docker host** — use `--network host` so the container
shares the host's network namespace; `127.0.0.1` inside the container then
resolves to the host (where your database listens):

```bash
docker run -d --name netdot --network host \
  -e DB_HOST=127.0.0.1 -e DB_PORT=3306 \
  -e DB_DATABASE=netdot \
  -e DB_NETDOT_USER=netdot_user -e DB_NETDOT_PASS=<app-password> \
  -e NETDOT_LISTEN=http://0.0.0.0:3001 \
  netdot:$V
# → http://localhost:3001/
```

With `--network host` the container binds **directly to host ports**, so
choose a `NETDOT_LISTEN` port that is free on the host (here `3001`, to
avoid a dev daemon already on `3000`).

**Database on another machine** — no `--network host`; publish the app
port and point `DB_HOST` at the database host:

```bash
docker run -d --name netdot -p 3000:3000 \
  -e DB_HOST=<db-host> -e DB_PORT=3306 \
  -e DB_DATABASE=netdot \
  -e DB_NETDOT_USER=netdot_user -e DB_NETDOT_PASS=<app-password> \
  netdot:$V
# → http://localhost:3000/
```

### Helm chart (Kubernetes, external database only)

A chart for Kubernetes lives in [helm/netdot](helm/netdot). It deploys the
**application only**, against any reachable MySQL/MariaDB; the DBA
pre-provisions the database and the application account. Same image, same
entrypoint, same first-boot behaviour as the `docker run` path:

```bash
helm install netdot helm/netdot \
    --set image.repository=<your-registry>/netdot \
    --set image.tag=v2.0.0-dev-<shortsha> \
    --set database.host=<db-host> \
    --set database.password=<app-password>
```

`values.yaml` is the complete, commented reference; the configuration
surface:

| Values key(s) | Purpose |
|---------------|---------|
| `image.*` | Image repository / tag / pull policy. |
| `netdotname`, `adminEmail`, `nocEmail`, `defaultContactList` | The commonly-configured Netdot settings, rendered into the generated Site.conf (defaults mirror `etc/Default.conf`). |
| `database.*` (`host`, `port`, `database`, `user`, `password`) | External database + application account (pre-provisioned by the DBA). |
| `ldap.*` | LDAP authentication (empty `server` = local authentication only). |
| `oauth.*` | OAuth2 / OpenID Connect (disabled by default). |
| `extraConfig` | Any other `etc/Default.conf` variable, verbatim Perl (e.g. `WEB_BASE_URL: "'https://netdot.example.org'"`). |
| `exportPersistence.*` (`enabled`, `size`, `accessModes`, `storageClass`) | Persist the export dir on a PVC; the session dir (`tmp/`) is always an ephemeral `emptyDir`. |
| `ingress.*` | Optional ingress (disabled by default). |

Notes:

* Netdot's yes/no switches are YAML `true`/`false` in the values and are
  rendered as `'yes'`/`'no'` in the Site.conf.
* The generated Site.conf lives in a Kubernetes Secret. The deployment
  carries a checksum annotation over the Site.conf-affecting values
  (`database`, `netdotname`, `adminEmail`, `nocEmail`,
  `defaultContactList`, `ldap`, `oauth`, `extraConfig`), so changing any of
  them rolls the pods.

## Environment variables

The entrypoint reads these (defaults shown). Anything not set falls back to
the default; a mounted `/usr/local/netdot/etc/Site.conf` always wins over
the generated one.

| Variable           | Default             | Purpose                                   |
|--------------------|---------------------|-------------------------------------------|
| `DB_HOST`          | `localhost`         | Database host.                            |
| `DB_PORT`          | `3306`              | Database port.                            |
| `DB_DATABASE`      | `netdot`            | Database name.                            |
| `DB_NETDOT_USER`   | `netdot_user`       | Application account (pre-provisioned).    |
| `DB_NETDOT_PASS`   | `netdot_pass`       | Application account password.             |
| `NETDOT_LISTEN`    | `http://0.0.0.0:3000` | Listen address(es), comma-separated.    |
| `NETDOT_WORKERS`   | `4`                 | Hypnotoad worker count.                   |
| `MOJO_LOG_LEVEL`   | `info`              | Log level (`info`, `debug`, `trace`).     |

## What the entrypoint does

`docker/entrypoint.sh` runs as `root` to bootstrap, then drops to the
unprivileged `netdot` user for the server:

1. Generates `/usr/local/netdot/etc/Site.conf` from the environment **only
   when no Site.conf is already present** (mount one to override anything).
2. Waits for the database to accept TCP connections (a port probe — no
   authentication — so it is environment-agnostic).
3. Reads the schema version stored in the `schemainfo` table (as the
   application account) and compares it to the application's own version
   (`$Netdot::VERSION`). **On first boot** (no version yet) it runs
   `bin/initdb initschema` to apply the schema + seed data; **if the stored
   version is outdated** it runs the upgrade (`upgrade/updatedb`, the same
   script as `make upgrade`); **if it matches** it does nothing.
   Non-interactive.
4. `exec`s the Hypnotoad pre-fork server in the foreground (the container
   main process).

## Verify it is up

```bash
docker logs netdot                       # "Listening at ..." + "Web application available"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3001/login   # → 200
```

Stop / remove the test container when done:

```bash
docker rm -f netdot
```
