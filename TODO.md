# Netdot — Portage Mojolicious : TODO & progression

Migration de la couche web **Apache/mod_perl + Mason** vers **Mojolicious**, en
réutilisant `Netdot::Model`. Périmètre : vues **lecture seule** (listes + détails +
export CSV + reports) portées type par type via des controllers dédiés, avec gestion
des 3 types d'utilisateurs (Admin / Operator / User) via permissions.

**Légende** : ✅ terminé (dédié) · 🔶 terminé (générique, basique) · ⬜ à faire · ⛔ hors périmètre

---

## 1. Socle (cross-cutting)

- [x] Auth : login / logout, session, redirect non-authentifié
- [x] Permissions : 3 user types, `access_section` (Admin+Operator), `access_admin_section` (Admin)
- [x] Navigation 5 sections (Registry `%MENU`), filtres par permission, sous-menus
- [x] Layout (`layouts/default.html.ep`), nav 2 niveaux, htmx boost
- [x] Tri de colonnes : `tablesort.js` (délégation d'événements → sûr htmx ; IPv4/CIDR, nombres, case-insensitive)
- [x] Pagination des listes
- [x] Export CSV par type (Browse#csv) + reports
- [x] Pages d'erreur brandées : `error_403.html.ep`, `error_404.html.ep`, `error_500.html.ep`
      (+ helpers `reply.html_not_found` / `reply.html_exception` dans Mojo.pm —
      remplacement des pages debug Mojolicious par défaut, layout `default`)

## 2. Management

Tous les types ont : **liste + CSV + détail + delete** = ✅ (Browse.pm générique + Show.pm).
Le détail est soit **dédié** (✅) soit **générique** (🔶).

| Type (route)        | Sous-section originale | Détail   | Dans le nav |
|---------------------|------------------------|----------|-------------|
| device              | Devices (DEVICE)       | ✅ dédié  | ✅          |
| asset               | Assets (ASSETS)        | 🔶 gén.  | ✅          |
| vlan                | VLANs (VLANS)          | 🔶 gén.  | ✅          |
| ipblock             | Address Space (ADDRESS)| ✅ dédié  | ✅          |
| rr                  | DNS Records (HOSTS)    | ✅ dédié  | ✅          |
| zone                | DNS Zones (ZONES)      | ✅ dédié  | ✅          |
| dhcscope            | DHCP (DHCP)            | 🔶 gén. (cols dédiées) | ✅          |

> `dhcscope` : dans le nav (Management → DHCP), liste avec colonnes dédiées
> (name, type, container, version, ipblock, physaddr, active), détail générique
> avec drill-down via `contained_scopes`, CSV liste + CSV relation.
> Fix : `link_for`/`format_value` résolvent la clé par classe (DhcpScope → `dhcscope`),
> la stringification `lc(ref)` donnant `dhcpscope` (inexistant).

## 3. Contacts

| Type (route) | Sous-section originale | Détail | Dans le nav |
|--------------|------------------------|--------|-------------|
| person       | People (PEOPLE)        | 🔶 gén.| ✅          |
| entity       | Entities (ENTITIES)    | 🔶 gén.| ✅          |
| contactlist  | Contact Lists (CLISTS) | ✅ dédié| ✅          |

## 4. Cable Plant — ✅ tranché : Sites, Closets, Rooms, Floors

Seuls **Sites**, **Closets**, **Rooms** et **Floors** sont utiles (portés). Le câblage
(backbone/horizontal) et les **Circuits** sont **dépréciés**.

| Type (route)        | État                          |
|---------------------|-------------------------------|
| site                | 🔶 gén. (utile)               |
| closet              | ✅ dédié (utile)             |
| room                | 🔶 gén. (utile)               |
| floor               | 🔶 gén. (utile)               |
| ~~backbonecable~~   | ⛔ **déprécié** — non migré    |
| ~~horizontalcable~~ | ⛔ **déprécié** — non migré    |
| ~~circuit~~         | ⛔ **déprécié** — non migré    |

> **Décision (2026-10-01)** : `backbonecable`, `horizontalcable`, `circuit` sont **dépréciés** —
> à **ne pas migrer / ne pas maintenir** (routables (200) aujourd'hui mais non listés). Un produit
> dédié comme **Netbox** est mieux adapté à la gestion du câblage / des circuits ; il ne sert à
> rien de maintenir cette partie dans Netdot.

> **Détail dédié Closet** (`Controller/Closet.pm`, port de `cable_plant/closet.html`) :
> info physique en 2 colonnes (name/room/dimensions/racks/… + ru_avail/patch_panels/…) +
> `info`, **Device List** (devices du room via room→floor→site), **Backbone Cable**
> (start+end fusionnés) et **Horizontal Cable** (read-only). Les noms de câbles sont en
> texte brut (pas de lien vers les pages dépréciées). Upload de photos non migré.

## 5. Advanced / Generic — ✅ Changelog (Audit)

La section « Advanced » ne montre plus que le **Changelog** (table `audit`).
Interface, physaddr, service sont **masqués du nav** (`nav => 0`) mais restent
accessibles via URL (`/management/physaddr/…`, etc.).

- [x] ✅ **Changelog** (`/changelog`, `Controller/Advanced.pm`) : table `audit` (tstamp DESC),
  colonnes Timestamp / User / Table / Label / Operation / Fields / Values ; recherche `search`
  (LIKE sur `label`) + filtre `operation` (insert/update/delete) + pagination `offset`.
- [x] ✅ **Filtre de permission** : feature Admin — Admin/Operator voient **tout** ; un autre
  user ne voit que **ses propres** entrées (`audit.username = <user>`).
- [x] ✅ **Enregistrement audit des écritures web/API** : `before_dispatch` (`Netdot::Mojo.pm`)
  fixe `$ENV{REMOTE_USER}` = user de session (comme l'ancienne couche Apache) ; `Model::_audit`
  l'utilise pour écrire dans `audit`. Sans ça, **aucune** entrée d'audit n'était créée pour les
  écritures web. (Un host génère 2 entrées : le RR + l'association IP/host.)
- [x] ✅ **Nav** : section « Advanced » = un seul item « Changelog » (hook `before_render`,
  cas spécial `generic` comme reports/export).
- [x] ✅ **Recherche globale** (`/search`, `Controller/Search.pm`) : champ de recherche
  sur la page d'accueil. Détection : IPv4/IPv6 → redirect `/management/ipblock/search`,
  MAC → redirect `/management/physaddr/search`, texte → `RR->search_like(name)` →
  redirect si 1 résultat, sinon table de résultats (Name + Zone).
- [x] ✅ `interface`, `physaddr`, `service` : `nav => 0` dans Registry (routable, hors nav).

## 6. Reports — ✅ 10/10 terminés

device · asset · ip · macs · topology · pollstats · database · custom (hinfo/usedby) ·
ipbat · security — + sous-vues (`poll`) + export CSV. Gating `access_section` (Admin+Operator).

- [x] **Lien générique des cellules-objets** : `_obj_html($obj)` + `_normalize_rows`
      (Reports.pm) branchés dans `_render`/`_csv` → n'importe quel objet Netdot passé comme
      cellule devient un lien détail (type résolu par `link_for`/`class_key`) ou son libellé si
      non navigable. Rapport **asset** (récap + détaillée) : *Model* (→product) + *Vendor*
      (→entity) cliquables. Rapport **device** Site/Type/Model (+OS) : fidèle à Mason →
      *Site* et *Model* pointent vers la **liste Device filtrée** (`/management/device?site=&product=`),
      *Vendor* →entity. Filtre de liste réutilisant le Model : `Browse#list` honore des
      colonnes blanches par type via `search_like()` (`%FILTERS` : num/str), réapplication de
      la règle 'view' par-user. Filtre 3 keys + string : `os` (string) ajouté ; `Device->search_like`
      étendu (site + product + os combinés). Rapport device : cellule *OS* cliquable (`siteos`
      → site+product+os ; `os` → product+os), `_devlink` encode l'URL (string-safe). Rapport
      device **SNMP Down**/**Downtime** : colonnes corrigées = vue `row` Mason (Name, Asset,
      Site, SNMP Target Address) avec liens FK (`_device_rows`). Rapport device **OS Mismatches** :
      Manufacturer/Model en **nom** (pas l'ID) + cellule **OS** cliquable (→ device?product+os).
      Rapport **macs** : colonne **OUI** cliquable → `/management/physaddr?address=<OUI>*`
      (filtre `physaddr.address` string via `search_like`/`format_address_db`, LIKE préfixe). CSV reste en texte brut.
- [x] **Listes génériques (Browse#list)** : en-têtes = `tag` meta, cellules FK (via
      `links_to` meta) rendues en **lien** vers l'objet lié (`/management/<classe>/<id>` ;
      ex. device : Asset/Site/Ipblock) ; colonnes scalaires en texte brut. Helpers Registry
      `column_link_key` + `esc` ; template `list.html.ep` rend les cellules via `b()`.

## 7. Export (réservé aux droits d'écriture ; le reste aux Admins) — ✅ porté (12 types)

- [x] ✅ **Configurations** (`/export`, `Controller/Export.pm`) : export de configs tierces
  via `Netdot::Exporter->generate_configs`. Formulaire (types, zones, scopes, force, options
  HINFO/TXT privées) ; log de l'exporteur capturé (String appender) et affiché ; erreurs par type listées.
- **Types & permission** : les **12 types** de l'original sont tous câblés.
  - **DNS (BIND, NAMED, RFC952) + DHCP (DHCPD)** : accessibles à qui a les droits d'écriture
    sur les RR — `Permissions::can_export` = `has_action('RR', edit) || has_action('RR', delete)`
    (grant Zone→RR). Un User à droits écriture (ex. smobile) n'en voit que ces 4.
  - **Le reste** (GIT, PLAYBOOK, UNILSTAT, Nagios, Sysmon, Rancid, Smokeping, Apache) :
    réservés aux **Admin** (le compte de test voit et exécute les 12).
  - (Original : `access_admin_section` / Admin only pour tout.)
- **Fix Playbook (YAML)** : les scalaires étaient écrits en guillemets simples sans échapper les
  `'` internes → YAML invalide (ex. `Unit: 'Institut des Systèmes d'Information'`). Ajout du helper
  `yaml_str` (échappement YAML : `'` → `''`) appliqué aux valeurs des 4 fichiers (CNAME, Host,
  liste_verte, vlan_list) ; les 4 passent `YAML::XS::LoadFile`.
- **Fix sort (warning)** : `str2time` renvoyait `undef` si `rr.modified` vide → warning
  « uninitialized » dans les 2 blocs `sort` d'`ansible_form` (Host/CNAME). Corrigé : `str2time(...) // 0`.
- **Config/env** : `REMOTE_EXEC => 0` + `CHECKBOX_CHECKED_EXCLUDE_{HINFO,TXT}_PRIVATE_DATA => 1`
  dans `etc/Default.conf` (SCP distant off ; cases HINFO/TXT cochées par défaut, comme en prod).
  Dirs locaux `export/{bind,dhcpd,named,rfc952,pb}` créés.
- Vérifié : Admin + smobile (User, zones 114/115/116) voient Export et exportent (fichiers écrits) ;
  guest (sans droits) = 403 + nav masquée. 12 types exécutés avec succès par l'Admin.
- [x] ✅ **Refactor export distant homogène (`REMOTE_PLUGIN`)** : les clés éparses
  (`REMOTE_EXEC`, `BIND_REMOTE_DIR`/`BIND_SSH_SERVER`/`BIND_RELOAD_CMD`, `NAMED_REMOTE_DIR`,
  `RFC952_SCP_TARGET`, `Apache_SCP_TARGET`) → structure unique
  `REMOTE_PLUGIN{PLUGIN}{DIR, SERVER, RELOAD, ENABLE}` (BIND, NAMED, RFC952, APACHE, UNILSTAT) ;
  `ENABLE` **par plugin** remplace le flag global `REMOTE_EXEC`. Découplage git : `BIND_EXPORT_DIR`/
  `NAMED_DIR`/`RFC952_DIR`/`Apache_DIR` deviennent des **ARRAYREF** de dirs de sortie (primaire +
  copies) ; suppression de `Git_BIND_DIR`/`Git_NAMED_DIR`/`Git_RFC952_DIR` (le staging git est juste
  une entrée de la liste ; `GIT.pm` inchangé, utilise `Git_DIR`). Nettoyage : RFC952 perd ses 2
  commandes **hardcodées** (`scp …user@scphost:scripts/` + `ssh user@dnsmaster update_named`) ; Apache
  (scp commenté) et Unilstat (target hardcodé `user@scphost:/var/www/html/stat/`) câblés proprement
   sur `REMOTE_PLUGIN`. Le scp = `SERVER:DIR`, le reload = `ssh SERVER 'RELOAD'` (**section par
   exporteur** ; `RELOAD` vide = pas de reload — NAMED en manquait, ajouté), le tout gating sur
    `ENABLE` ; code : le hashref du plugin est stockée dans `$self->{REMOTE}` (ou `$cfg` dans BIND)
    et indexée `{DIR|SERVER|RELOAD|ENABLE}`.
- [x] ✅ **Fixs export (runtime, Perl 5.40)** : 3 classes de bugs qui bloquaient l'export :
  1. **`$#$ref` (dernier index d'une arrayref) supprimé en Perl 5.30+** → parse mal à runtime
     (« Not an ARRAY reference »). Remplacé par l'idiome `@copies = @{…}; shift @copies;` dans
     `NAMED.pm` (×2), `RFC952.pm`, `Apache.pm`, `BIND.pm`, et `$last = @$list - 1` dans
     `Mojo/Controller/Device.pm` (`_chunk`). (`$#tab_vrai` sur un vrai tableau reste OK.)
  2. **`Sysmon.pm`** : erreur de syntaxe line 96 (`$devh->{target_version}{` → le `}` de déréférencement
     mal tapé) empêchait le chargement du module → `generate_configs` introuvable. Corrigé en
     `unless ( $devh->{target_addr} && $devh->{target_version} ) {`.
  3. **`Git_BRANCH` manquante dans la config** : `GIT.pm` fait `get('Git_BRANCH')` (croak si absente)
     mais la clé n'existait ni dans `Default.conf` ni dans `Default.conf.orig` → ajoutée
     (`Git_BRANCH => 'master'`) aux deux. Dir `export/sysmon/` manquante (créée par `make dir`) → créée.
   - Vérifié : `perl -c` OK sur les 6 exporters + Device.pm ; NAMED/RFC952/Apache/Sysmon tournent.
 - **Flag DNSSEC** (`zone.dnssec`, bool) : remplace le hack `DNSSEC: inline` du champ
   `zone.info` (export NAMED ⇒ bloc inline-signing ; `HIDDEN` reste dans `info`).
   - Fichiers : `netdot.meta` (colonne + vue `all` `Zone`), `Zone.pm` (insert/copy),
     `NAMED.pm` (lit la colonne), `upg_107_200` (migration upgrade 1.x→2.0.0).
    - ✅ strict mode : `sql_schema('MySQL')` convertit les `DEFAULT 'false'`/`'true'`
      (colonnes bool, 41) en `DEFAULT 0`/`1` (même pattern que le fix `bigserial` pour
      PostgreSQL) → un `initdb` neuf passe sous `STRICT_TRANS_TABLES`.
   - Bool : `Yes`/`No` dans l'UI (helper `Registry::attr_display` : pages détail
     Device/Closet/Interface/Zone/ContactList) et `true`/`false` en JSON (API).
   - Vérifié : 53 zones `dnssec=1` ⇒ 53 blocs inline-signing ; page + API OK.

## 8. Help — ✅ terminé

- [x] ✅ **User Manual** (`/help/manual`, `Controller/Help.pm`) : sert le fichier
  pandoc `doc/manual/netdot-manual.html` via `reply->file()` (HTML brut, sans layout).
- [x] ✅ **Database Schema HTML** (`/help/database`) : `Netdot::Meta::SQLT->html_schema()`
  (table HTML des relations DB, 323 tables).
- [x] ✅ **Database Graph** (`/help/database/graph`) : `Netdot::Meta::SQLT->graphviz_schema()`
  → PNG dans `htdocs/img/graphs/schema.png` (GraphViz 2.24).
- [x] ✅ **Nav** : section "Help" (Admin+Operator) — 3 items : User Manual, Database Schema,
  Database Graph. Guest/User : masquée.
- [x] ✅ **Landing** (`/help`) : page d'index avec liens vers les 3 sous-pages.

---

## 9. JSON API (`/api`) + déploiement sous `/netdot` — ✅ porté

**API JSON** (port de l'ancien `/rest` + `Netdot::REST`) — auth = session web, JSON uniquement :
- [x] ✅ **Routeur générique** `/api/{table}` (88 tables) : GET liste (`?col=valeur`, `?depth=`,
  `?linked_from=1`, `?limit=`, `?offset=`), GET `/api/{table}/{id}`, `meta_data`,
  POST/PATCH/PUT créer + mettre à jour, DELETE.
- [x] ✅ **Pagination Netbox** : `limit` (défaut 50, max 1000) / `offset` (défaut 0) → enveloppe
  `{count, next, previous, results}` (`next`/`previous` préservent la recherche). Backend
  `Netdot::Model::search_count` / `search_page` (SQL `LIMIT ? OFFSET ?`, colonnes validées,
  valeurs liées). Champ `url` (absolu : `<préfixe>/api/<table>/<id>/`) sur chaque objet.
- [x] ✅ **Permissions sur TOUS les verbes** (port de l'héritage `ObjectAccessRule`) :
  GET liste = `viewable_predicate` (pré-filtre SQL FK) + `can('view')` par objet (safety net) ;
  GET objet = `can('view')` ; POST/PATCH/PUT update = `can('edit')` ; DELETE = `can('delete')`.
  **Création** = `_can_create` (l'objet cible n'existe pas → pas de `can()` direct) :
  `can('edit', $parent)` avec `zone` (pour `rr`), `rr` (pour `rrtxt`/`rrcname`/… → leur RR),
  `device` (interface), `contactlist` (contact) ; sinon `has_action(class, 'edit')`. Admin illimité.
- [x] ✅ **Création de host sur IP existante** (`_host_post`) : `address` déjà présente =
  ajout d'un **RRADDR** (aucune allocation d'IP, pas de `choose_ip`) → autorisé si
  `can('edit', $zone)` ET `can('edit', $ip)`. IP neuve / sous-réseau = allouement
  (`can('edit'/'choose_ip', $subnet)` + `RR->add_host`).
- [x] ✅ **Endpoints dédiés** : `devinfo`, `host_contacts`, `ipattr`, `host`, `host_like`,
  `updatedev`.
- [x] ✅ **Index** (`GET /api`) : flat-map Netbox-style `{resource: url-absolute}` (tables +
  endpoints dédiés + `docs` + `openapi.yaml`).
- [x] ✅ **Erreurs JSON-aware** : tout `/api/…` répond en JSON (404/405/500), quel que soit
  l'`Accept` (handlers `reply.*` path-aware) ; hors `/api` → pages HTML Netdot.
- [x] ✅ **Format des FK = référence imbriquée** : en lecture, une FK = `{id, url, …champs
  de label}` (ex. `zone → {id,url,name}`, `ipblock → {id,url,address,prefix}`, `rr → {id,url,
  name,zone}`) au lieu de `label` + `<col>_xlink`. Source unique `Netdot::Model::get_ref_field_spec`
  (= `meta_data->get_labels`) ; `get_hashref` (valeurs ; champ FK → `get_label` **1 niveau**, pas
  de boucle infinie) ; FK nulle → `null` ; `depth>0` = objet complet imbriqué ; `linked_from` =
  mêmes références.
- [x] ✅ **Champs sensibles masqués** : le serializer saute les colonnes
  `Registry::is_sensitive` (`password`, `snmp_authkey`, `snmp_privkey`, `authkey`) → **jamais**
  exposées en JSON (ni documentées dans le spec OpenAPI) — même garde que la couche HTML.
  `authkey` (clé de session BGP, `BGPPeering`) **ajouté** à la liste ; `community` (SNMP v1/v2c,
  `Device`) volontairement **visible** (config opérationnelle, montrée dans le détail Device HTML).
- [x] ✅ **OpenAPI 3** généré depuis `netdot.meta` : `lib/Netdot/Mojo/OpenAPI.pm` +
  `api/gen_openapi.pl` → `api/openapi.yaml` ; Swagger UI en `/api/docs` (page standalone).
  Schémas de référence **par classe** `FkReference_<Classe>` (id/url + champs de label, depuis
  `get_ref_field_spec`) ; une FK = `anyOf [integer, $ref FkReference_<Classe>]` (id en écriture,
  référence imbriquée en lecture).

**Déploiement sous préfixe `/netdot`** (Apache/nginx en front) :
- [x] ✅ **`WEB_BASE_URL` = préfixe de chemin** (`/netdot`) dans la config (pas une URL
  absolue) → identique en dev et en prod. L'app est montée sous ce préfixe **des deux côtés** :
  routes (`->under($base)`), static (`css|img|java_script` sous le préfixe), `before_dispatch`
   et nav path-aware, helper `web_prefix()` pour les liens durs restants.
 - [x] ✅ **Helper `set_uri`** (`Registry::set_uri` + alias `$c->set_uri`) : préfixe **tout**
   chemin interne root-absolu (`/management/…`, `/reports/…`) construit à la main. `url_for()`
   (templates) porte déjà le préfixe ; c'est le **code Perl** des controllers/templates qui en
   omettait (`link_for` + ~56 liens inline sur 10 controllers + 6 templates `device/contactlist/
   zone/detail/ipblock/ipaddress`). Un hook `after_render` regex avait d'abord été envisagé mais
   remplacé par `set_uri` (explicite, maintenable, no-op à la racine).
 - [x] ✅ **Proxy (préservation du préfixe)** : `ProxyPass /netdot → http://127.0.0.1:3000/netdot`
  (nginx : `location /netdot/ { proxy_pass http://127.0.0.1:3000; }` **sans slash final**).
- [x] ✅ **Dev** : `http://127.0.0.1:3000/netdot/` ; **Prod** : `https://netdot.localdomain/netdot/`.
   URLs absolues de l'API = `<origin de la requête><préfixe>` (ex. `…/netdot/api/device`).
 - [x] ✅ **Fichiers de déploiement** : `etc/netdot_apache.conf` = reverse-proxy
   **indépendant de la version** (Apache 2.2 **et** 2.4, `mod_proxy`) :
   `ProxyPass /netdot → http://127.0.0.1:3000/netdot` + `ProxyPassReverse` + `ProxyPreserveHost`.
   Remplace les **6** anciennes configs mod_perl par version/méthode d'auth
   (`netdot_apache2{,4}_{local,ldap,krb5,radius}.conf`, **supprimées** — l'auth est désormais
   dans l'app, plus de mod_perl). `etc/netdot.service` (**systemd**) lance
   **Hypnotoad** (`perl /usr/bin/hypnotoad -f bin/mojo`) : un manager **préfork** spawn
   `NETDOT_WORKERS=10` workers → une requête lente (ex. suppression d'un device qui cascade
   interfaces/ARP/FDB) bloque **son** worker seulement, pas les autres (comme l'ancien
   mod_perl ~10 forks). `-f` = foreground (systemd suit le process) ; arrêt via `hypnotoad -s`.
   Config dans `Netdot::Mojo` `startup` `config(hypnotoad=>{listen,workers,pid_file})`
   (overridable par `NETDOT_LISTEN`/`NETDOT_WORKERS`/`NETDOT_PID_FILE`). `bin/mojo` chargeable
   par un serveur (retourne l'app en `do` si caller, sinon `->start`). **BDD sous fork** :
   Ima::DBI rouvre une connexion **par worker** (fork-aware) ; `dbi_options->{InactiveDestroy}
   =1` (Model.pm) pour qu'un worker recyclé ne casse pas le socket du manager. Marqueurs
   `<<Make:PREFIX>>`/`<<Make:PERL>>` substitués par le Makefile à l'install. **Makefiles** : `htdocs/Makefile` déploie maintenant
     les templates `.ep` (pattern `FILES` `\.ep`) + **tout sous-dir de templates** dans `NDIR`
     (`layouts`, `advanced`, `search`, … — le `NDIR` crée les dirs, `install` échoue silencieusement
     pour un `.ep` dont le dir parent n'est pas listé), `etc/Makefile`
     FILES = `netdot_apache.conf` + `netdot.service`.
    **Autres** : `lib/Makefile` NDIR += `Netdot/Mojo` + `Netdot/Mojo/Controller` (les 25 modules
    de la nouvelle couche s'installent) ; `etc/utility-Makefile` REPLACEABLES += `APACHEUSER`/
    `APACHEGROUP` (le `.service` utilise `User=<<Make:APACHEUSER>>`/`Group=<<Make:APACHEGROUP>>`,
    défaut `apache`) ;     `bin/perldeps.pl` : ajout **Mojolicious, JSON, Net::LDAP, YAML::XS, Crypt::URandom** ET **purge** des modules
    web legacy (`mod_perl`, `Apache2::Request`, `HTML::Mason`, `Apache::Session`,
    `Apache2::AuthCookie`, `Apache2::SiteControl`, `Authen::Radius`) — la nouvelle app ne les
    charge pas (vérifié via `%INC` : permissions réimplémentées dans `Netdot::Mojo::Permissions`,
     sessions = **id aléatoire 128 bits** dans le cookie + données sur disque via
     `Netdot::Mojo::Sessions`) ; `htdocs/Makefile` `dir:` + `NDIR` : plus de
    `masondata`/`obj`/`chcon` ; Makefile principal : `DIR` sans `tmp/sessions`/`locks`, cible
    `dir:` sans `chcon` SELinux ; `export/Makefile` : plus de `chcon` (contexte
     `httpd_sys_rw_content_t` obsolète pour le daemon systemd — sur RHEL+SELinux, le contexte du
     daemon se gère par une politique dédiée).
  - [x] ✅ **Sessions serveur (flat-file, `Netdot::Mojo::Sessions`)** : le cookie ne porte qu'un
     **id opaque aléatoire 128 bits** (CSPRNG `Crypt::URandom::urandom`) — plus de clé symétrique
     (le cookie ne peut pas être « cassé ») ; les données de session vivent sur disque
     (`SESSION_DIR`, défaut `<<Make:PREFIX>>/tmp/sessions` = `$NETDOT_PATH/tmp/sessions`), 1 fichier
     JSON/session (0600 dans un dir 0700). Sous-classe de `Mojolicious::Sessions` qui surcharge
     `load`/`store` : la regex `^[0-9a-f]{32}$` est testée **avant** tout accès fichier (un cookie
     forgé avec `/`/`$`/`..` est ignoré — pas de path-traversal), écriture atomique (temp+rename),
     purge au logout, nettoyage opportuniste des fichiers expirés. Config : `SESSION_DIR`,
     `SESSION_SECURE` (flag `Secure`, prod derrière TLS), `SESSION_IDLE` (délai d'inactivité,
     **glissant** — la session est renouvelée à chaque requête ; défaut 3600s). Multi-worker
     (Hypnotoad) : tous les workers partagent les fichiers → la session survit au worker.
     **Gotcha** : lire l'id avec `$c->cookie('name')` (retourne la valeur), **pas**
     `$c->req->cookie('name')` (objet `Mojo::Cookie`, forme string `name=value` → ne matche pas la
     regex → un id/fichier neuf à chaque requête).
  - [x] ✅ **Access-log (journald)** : hook `after_dispatch` (`Netdot::Mojo`) loggue 1 ligne/requête
   `ACCESS <ip> <user> <méthode> <controller>#<action> <path> <statut>` (hors assets statiques) ;
   `Auth#login_submit` loggue `LOGIN <ip> user=<u> success|FAILED` (tentatives de login, IP incluse). Le `<ip>` = la **vraie IP client** : le helper `client_ip`
    lit la 1ʳᵉ valeur de `X-Forwarded-For` **uniquement** si le peer direct est un proxy de
    confiance (config `TRUSTED_PROXY_IPS`, **liste d'IPs**, défaut loopback — y ajouter son
    proxy externe) ; sinon l'IP du peer direct est logguée (anti-spoofing : un client direct ne
    peut pas forger `X-Forwarded-For`). Via le logger app → **journald** (systemd). Niveau `info` par défaut (`$self->log->level(
   $ENV{MOJO_LOG_LEVEL} // 'info')`, le `.service` fixe `MOJO_LOG_LEVEL=info`) — garde ACCESS/LOGIN,
   supprime le bruit trace/debug. Lecture : `journalctl -u netdot` / `journalctl -u netdot | grep
    ACCESS`. **Complète** l'audit des écritures (table `audit`, page Changelog) qui ne capture ni IP
    ni lectures.
 - [x] ✅ **Images des graphes legacy (`Netdot::UI`) sous préfixe** : les builders de graphes
    legacy (arbre ipblock `build_ip_tree_graph_html`, graphes RRD `rrd_graph`) construisent le
    `<img src>` et les liens image-map `usemap` comme `$web_path . 'img/graphs/…'` /
    `$web_path . 'management/…'` (sans slash menant) → on leur passe désormais **`web_root`**
    (`$c->web_root`) = base **avec slash final** (`/netdot/` ou `/`) au lieu de `web_path => '/'`
     en dur, qui privait l'image ET ses liens du préfixe `/netdot` (en dev comme en prod).
     Fix : `Controller/Ipblock.pm` (arbre) + `Controller/Reports.pm` (rrd, latent).
  - [x] ✅ **Hygiène de la config (`Default.conf`/`Site.conf`)** : retrait de 2 clés mortes (0 référence
    dans le code) — `DB_NETDOT_HOST` (le code lit `DB_HOST` : `Model.pm`/`DBUTIL.pm`) et `INVENTORY_WARNING`
    (aucune référence) — supprimées de `Default.conf` **et** `Site.conf`. Commentaire périmé au-dessus
    d'`AUTHORIZATION_METHOD` corrigé (« Authentication is configured in Apache » → l'auth passe par
    Mojolicious `Netdot::Mojo::Controller::Auth` via LDAP/local). Section `NetdotLDAP*` remontée de la fin
    du fichier vers la section auth (après `DEFAULT_REMOTE_AUTHED_USER_TYPE`) : l'auth LDAP est réutilisée
     via le shim `Netdot::Mojo::AuthShim` (émule l'ancien `$r->dir_config`), donc ces clés sont **vivantes**.
     Note : `SYSMON_HTML_FILE` pointe encore vers `/var/www/html/` (racine Apache) — à revoir si l'export
     Sysmon est utilisé.
  - [x] ✅ **`Site.conf` = miroir complet de `Default.conf`** : régénéré dans le **même ordre de clés** et
     avec les **mêmes commentaires de section**, en ne gardant que les valeurs du site sur les clés qui
     divergent (68 clés) et la valeur par défaut ailleurs. But : `diff -NaBbur Site.conf Default.conf`
     ne montre que les customisations du site (les commentaires de section s'alignent en contexte).
     Vérifié : `perl -c` OK, config effective **inchangée** (`do(Default)`+`do(Site)` = avant/après),
     aucun marqueur `<<Make:PREFIX>>` restant, `Netdot->config` charge bien les 5 plugins `REMOTE_PLUGIN`
      et `LOG_OPTIONS` (18 sauts de ligne intacts).
   - [x] ✅ **Footer (toutes pages)** : `<footer id="footer">` dans le layout `default.html.ep` —
     ligne `© GPL · <a>Netdot: NETwork DOcumentation Tool</a> v<version>` (version = statique
     `$Netdot::VERSION` ; repo git = config **`WEB_GIT_URL`**, défaut `https://github.com/vink78/Netdot`,
     configurable par déploiement/fork) + un **commentaire HTML** de copyright GPL standard.
     Helpers `nd_version`/`nd_git_url` (`Netdot::Mojo`). La ligne « Read-only » de l'accueil
     (`index.html.ep`) est remplacée par un texte qui reflète l'écriture via l'API.
 
 ## 10. UI moderne (design 2026) — ✅ porté

Modernisation visuelle « flat minimal » (cartes), sans framework : tout en CSS
(`style.css`, couche « MODERN DESIGN LAYER » en fin de fichier) + un peu de JS
vanilla. Portée type par type ; les vues listes/détails/reports/search partagent
les mêmes composants.

- [x] **Navbar sticky** + nav 2 niveaux (section / sous-menus), modernisée.
- [x] **Tableaux de données `datatable`** : look moderne (arrondi, zebra, en-tête),
  coins extérieurs arrondis (les cellules header/footer carrées ne débordent plus de
  la bordure arrondie). **Convention de classes** : `class="datatable"` = le **look**
  moderne (tous les tableaux) ; `class="sortable"` = opt-in du **tri JS**
  (`tablesort.js`, réservé aux grandes listes). Les tableaux de détail/champs ne sont
  **pas** `sortable`. Le look moderne requiert la structure **`<thead>` + `<tbody>`**
  (le CSS cible `datatable thead th` / `tbody td` / zebra `tbody tr:nth-child`).
- [x] **Tableaux de rapports** : les tables de données des rapports
  (`reports/data_table.html.ep`, partagée par device/asset/ip/macs/ipbat/security/
  hinfo/usedby/database) passent à la structure moderne `datatable` (`<thead>` +
  `<tbody>`, **sans** les classes legacy `formtabletitle` / `datatabler1` /
  `datatabler2`) → en-tête, zebra et coins arrondis du design 2026 s'appliquent.
- [x] **Tri** : serveur (SQL `ORDER BY` + `LIMIT/OFFSET`) pour listes, CSV et
  **relations** ; `tablesort.js` (délégation d'événements, sûr htmx) uniquement sur les
  tableaux `sortable` (tri de la page courante).
- [x] **Tabs côté client** (`java_script/tabs.js`) : bascule de pane instantanée (pas de
  rechargement), état préservé dans l'URL (`?rel=<rel>`), sûr htmx (délégation sur
  `<document>`). Le détail générique (`management/detail.html.ep`) est organisé en
  `.tabbar` + `.tab-pane` (un pane par relation non vide ; page mono-relation sans tabbar).
  Le sélecteur est **restreint à `.tabbar .tab[data-rel]`** : seul l'onglet de relation
  (côté client) est intercepté ; les onglets serveur `?view=` (Device, Ipblock) naviguent
  normalement.
- [x] **Tableaux de champs `datatable.detail`** : remplace l'ancien `<table>` de champs
  (20 ans) **et** l'ancienne grille `.attrgrid` (retirée du CSS) par un tableau
  `table.datatable.detail` en **colonnes label | valeur**, multi-colonnes via les classes
  **`c1`/`c2`/`c4`** (1/2/4 paires par ligne ; largeur du label `c1`=220px, `c2`=200px,
  `c4`=150px). Les templates découpent la liste plate d'attributs en lignes de N.
  Utilisé par **tous** les détails : générique, Device Basics, Ipaddress, Ipblock, RR,
  Zone, ContactList, Closet.
- [x] **Cartes `.container`** (bordure arrondie, ombre légère) pour les blocs de contenu.
  Affichage des champs = carte `.container` > `.containerhead` (titre) +
  `.containerbody.flat` (tableau `datatable.detail` biseauté bord-à-bord, sans chrome
  interne) — le titre de la carte = le nom de l'objet ou le nom de la section.
- [x] **Carte à onglets `.tabcard`** : une seule carte encadre la barre d'onglets
  (`.tabbar`) **et** le contenu affiché (`.tabcard-body`) ; le contenu intérieur
  (tables / cartes de section) est **aplati** (`.tabcard .datatable`, `.tabcard
   .container` sans bordure) → pas de carte-dans-carte. Appliqué aux pages à onglets :
   Device (`?view=`), détail générique (`?rel=`), Ipblock (sections Children/Sites/…).
  - [x] **`.container.boxed`** : une section réactive le cadre (bordure/ombre/arrondi)
    à l'intérieur d'une `.tabcard` (opt-in du card-in-card) — sections Device Basics
    (General / Location / Management).
  - [x] **`.cardrow`** : rangée responsive de cartes `.container` égales (côte à côte,
   wrapping sur écran étroit, hauteurs égales `align-items:stretch`). **Page Export**
   (`/export`) : un conteneur englobant `.container` (titre = «Export third-party configurations…») > `.cardrow` de 3 cartes
   (Export Classes / DNS (BIND) Options / DHCPD Options) ; erreurs + sortie de l'exporteur en
   cartes dédiées au-dessus. Contrairement à `.tabcard`, le card-in-card est **voulu** ici.
 - [x] **Page de login** : champs empilés (label au-dessus, input pleine largeur →
  alignés), bouton `.btn` pleine largeur, titre court + texte d'aide ; le bouton
  « log in » du header est **masqué** sur la page de login (flag `is_login` posé par
  `Auth.pm`, géré dans `layouts/default.html.ep`).
- [x] **Boutons + liens** modernisés (liens : soulignement au survol seulement).
 - [x] **CSS nettoyé** : classes orphelines/legacy mortes retirées (`.attr*`, `.devgrid`,
   doublons legacy `.container*`, `*outside`, `containerseparator`, `div.left/right/clear`,
   `formtable*`, `datatabler*`, `tabletitle`, `containertable*`, `empty000000`,
   `#loginform`/`logintable`) ; `.containerhead` = un seul sélecteur. Le zebra des tableaux
   vient du CSS `datatable` (`tbody tr:nth-child`), plus des classes `datatablerN`.
   **Conservé** : `ipcontainertable` et `ipaddr_*` (+`_2`) — ces derniers sont **construits
   dynamiquement** (`Ipblock.pm`) ; un balayage « classes mortes » doit donc chercher dans
   **tout** `lib/` et vérifier les constructions dynamiques (le modèle d'origine émet du HTML).

> Commits : `ee804e23 CSS`, `1fe21fbb CSS 2` (tabs.js + attrgrid + détail en tabs),
> `df5ba174 CSS 3` (tablesort `datatable`/`sortable`), `9ea7e8c5 CSS 4` (rename des classes
> sur 15 templates).

---

## Hors périmètre (écriture) — ⛔

Objectif = vues lecture seule. Pages de création/édition/suppression **non portées** :
`device_tasks`, `asset_tasks`, `dhcp_tasks`, `host_tasks`, `vlan_tasks`, `zone_tasks`,
`address_tasks`, `addneighbor`, `addservice`, `choose_ip`, `template_edit`,
`ip-rec`.
  > **État création device (2026-10-12)** : **`updatedevice` + création manuelle**
  > (`device_tasks` « Add Device manually ») **portés** — wizard SNMP 2 étapes
  > (`/management/device/discover`, admin only : form → review avec Owner/Used by/
  > Site/Contacts guessés → `Device->discover` + log capturé ; re-poll existant via
  > `?device=<id>` depuis la page détail, bouton « SNMP update ») + ajout manuel dans
  > la boîte « New Device » (`POST /api/device/manual_add` → `Device->manual_add`).
  > Le wizard est **stateless** : l'étape 2 relance `get_snmp_info` avec les mêmes
  > arguments cachés (hash SNMP trop gros pour la session cookie signée).

 > **État écriture (2026-10-09)** : l'écriture se fait **via l'API JSON** (plus de pages HTML
 > d'écriture legacy). Porté **in-situ** dans l'UI : **édition** (détail générique + dédié
  > device/zone/contactlist/closet/ipblock/ipaddress/rr + par-record + RRAttr admin), **création**
  > (boîte générique « New \<type\> » sur les listes + RR New name / Add a record / Add alias +
   > **ipblock** : boîte « New Ipblock » sur les racines + **clic-to-create** (Mason `ADD_BLOCK`)
   > : sur la vue container, clic sur une partition libre ; sur la vue subnet, clic sur une IP
    > non assignée → modale « does not yet exist, create it ? » + select statut (bloc :
    > Container/Reserved/Subnet, défaut Container ; IP : Static/Reserved/+Dynamic si DHCP),
    > POST `/api/ipblock` sans `parent` (l'API auto-attache) + **page IP** : boîte « Add a
    > record » (style page RR : select de type → formulaire pré-rendu, `initAddForm`/`initForms`),
    > avant la section ARP — A Record (`/api/rr`), PTR (`/api/rrptr`), Service (`/api/ipservice`),
    > Attribute (`/api/ipblockattr`), DHCP Host (`/api/dhcpscope`, si le parent subnet a du DHCP) ;
    > zone A = select (zones forward éditables par l'user, défaut = zone de l'IP / ancêtre le plus
    > proche), zone PTR = fixée à la zone inverse de l'IP (lecture seule, masquée si absente) ;
    > selects = FK, `collect()` coercit les champs `data-nd-int` numériques en entier,
    > **suppression** (batch sur les listes + détail, device `delete_ips`, **ipblock
   > « delete children »** : modale `<div>` `ndConfirm` + checkbox défaut off → sinon les
   > enfants sont re-rattachés au grand-père via `_tree_delete` ; overlay « Deleting… »
   > pendant l'écriture lente. Fix API : les options de delete sont comparées via
   > `short_class` — avant, `Netdot::Model::*` ne matchait jamais, donc `recursive`/`delete_ips`
    > étaient silencieusement ignorées). (2026-10-11) **Vue bloc (subnet/container) — onglets en
    > écriture** : **site** (Sites → `POST /api/sitesubnet`), **zone forward** (Zones →
    > `POST /api/subnetzone`, select des zones forward existantes non liées) et **zone inverse**
    > (Zones → `POST /api/zone`, select des noms `.arpa` du bloc via `get_dot_arpa_names`),
    > **activation DHCP** (DHCP, subnets sans scope → `POST /api/dhcpscope` type=subnet sous un
    > scope global ; `option routers` replacé dans `attributes` par `initDhcpEnable()`) et
     > **attribut** (Attributes → `POST /api/ipblockattr`) — tous via `collect()`/`initForms`.
     > **Access Rights** (`?view=Rights`, Admin/Operator lecture, Admin écriture) : table
     > (Type/Subject/Right) + boutons Remove (`DELETE /api/userright|groupright/<id>`) ;
     > formulaire d'ajout (`POST /api/accessright`, JSON `{object_class, object_id,
     > subject_type, subject_id, rights:[…]}`) → overload `AccessRight->insert` (find-or-create
     > l'accessright + insert de la ligne join userright/groupright, dedup). JS `initRights()`.
     > **Suppression sections** (Sites/Zones/DHCP/Attributes) : boutons Remove par ligne
     > (`DELETE /api/sitesubnet|subnetzone|dhcpscope|ipblockattr/<id>`), JS `initRights()`
     > gère `.nd-sec-del`. Le select « Add attribute » ne propose que les noms pas encore
     > utilisés sur le bloc. **Add IP Range** (Subnets, vue Children) : bouton « Range » dans
     > la barre de toggle → mode sélection grid (clic/drag, surbrillance bleue, auto-swap
     > si start>end) + panneau draggable centré (start/end éditables, status, owner, used_by,
     > description, gen_dns, prefix/suffix pré-remplis depuis config `IP_RANGE_DNS_DEFAULT_*`,
     > fzone pré-sélectionnée = zone du bloc/héritée/`DEFAULT_DNSDOMAIN`). API
     > `POST /api/ipblock/:id/range` → `$o->add_range(...)`. JS `initRange()`.
     > **Batch Edit + Edit** (Children, mode liste) : deux boutons. « Batch » → checkboxes
     > sur les lignes + panneau (status filtré par type parent : Subnet=Dynamic/Reserved/Static,
     > Container=tous, owner, used_by, description, delete). « Edit » → cellules éditables
     > inline dans le tableau (select status « -- No change -- » + selects owner/used_by
     > « — »=vider + input description + checkbox delete par ligne, « check all » en
     > en-tête). Les deux envoient UNE seule requête : `POST /api/ipblock/batch`
     > `{updates:[{id, status?, owner?, used_by?, description?}], deletes:[id…]}`
     > (`Api#batch`, route enregistrée AVANT `/api/:table/:id` sinon « batch » est capturé
     > comme `$id`) → vérif existence+permissions par id, deletes d'abord, réponse
     > `{updated, deleted, errors{par id}}`, 200 si au moins une op appliquée.
     > **Seuls les champs sales sont envoyés** (JS compare aux `data-nd-*` originaux,
     > `data-nd-stid` = id du status courant) → l'audit trail ne loggue que les vrais
     > changements (le trigger `after_update` de `Netdot::Model` ne retient que les
     > colonnes dont la valeur a changé ; `fields='modified'` est ignoré).
     > JS `initBatch()` + `initEditChildren()`. (2026-10-12) **Fix `Registry::link_html`** :
     > `my ($t,$h) = link_for($v)` ne déréférençait pas l'arrayref → `$h` toujours undef →
     > tous les liens FK (owner/used_by/…) rendus vides ; corrigé en `@{ link_for($v) }`.
     > Les zones forward **héritées** d'un ancêtre s'affichent en *italique* + « (inherited) »
     > (seules les `SubnetZone` directes sont « configurées »). **Suppression adresse** : la vue
     > individuelle a son bouton Delete (pattern du bloc, `nd_children=0` → pas de case children)
     > et ses sections de données vides (A/PTR/Services/Attr/DHCP) sont masquées ; la boîte
     > « Add a record » rend ses champs cachés en dehors du `<table>` (plus de ligne vide).
     > **Liste (`view_format=list`)** : colonne « Name » = tous les A records de l'IP (FQDN,
     > séparés par virgule), **chaque nom = lien vers l'objet RR**, rempli par UNE requête
     > `LEFT JOIN rraddr` (plus de N+1) — le vieux `eval { $o->a_records } // ()` retournait un
     > Iterator (piège wantarray Class::DBI) → colonnes vides. Les selects ont un 1er item
     > `--SELECT--`. **Reste à porter** : (1) **édition de relations has_many**
     > générique pour les AUTRES types (ex. contacts d'un contactlist) —
     > lecture seule aujourd'hui (les relations du **bloc** et du **device** sont désormais ajoutables, cf. ci-
     > dessus), (2) **créations complexes** multi-étapes — la partie **device** est
     > **portée** (2026-10-12 : ajout manuel + wizard SNMP 2 étapes, cf. « État création
     > device » ci-dessus) ; reste la **hiérarchie ipblock** si un jour,
     > (3) allocation IP interactive `choose_ip`. **Fermé / non applicable** (2026-10-12) :
     > **REBLOCK** (changement d'identité address/prefix) = **porté par la lib** et
     > **exposé dans le formulaire d'édition** (champs `address` pointillés + `prefix`,
     > uniquement `parent`/`version` exclus) — `Ipblock->update` normalise l'adresse et
     > recrée la hiérarchie (`_update_tree` rebuild complet, migration PTR, ré-reservation)
     > → passe par l'API `POST /api/ipblock/:id` ;
     > **REBUILD_TREE** (`Ipblock->build_tree`) = usage **debug** uniquement, non traité ;
     > **ADD_BLOCKS** (bulk create) = inutile, un bloc à la fois suffit (la découverte d'un
     > routeur crée les blocs). **Re-poll `updatedevice` = porté (2026-10-12)** : wizard
     > `/management/device/discover` (bouton « SNMP update » sur la page détail device,
     > `?device=<id>`), état 2026-10-12 ci-dessus.

   > **État vues device (2026-10-14)** : les vues device restantes sont portées en
   > écriture — **Interfaces** (`f046de76`, 2026-10-13), **Neighbor** (`e5b8d117`),
   > **IP** (`f0c1285a`), **Access Rights** (`bb62e9d1`) et **BGP** (`bb62e9d1` +
   > `0c666a6b`) :
   > - **Vue IP** (`?view=IP`, modes `editips`/`add_ip`) : édition en ligne — suppression
   >   d'IP (`DELETE /api/ipblock?id=…`), interface + Monitored par IP
   >   (`PATCH /api/ipblock/<id>`), suppression DNS nom à nom (protection device-name
   >   UI-only, comme Mason), suppression service par service
   >   (`DELETE /api/ipservice/<id>`) ; **ajout d'IP** (`POST /api/device/<id>/add_ip`),
   >   formulaire inline **Add service** (port du popup `addservice.html`,
   >   `POST /api/ipservice` ; effet legacy conservé : l'IP passe monitored), boîte
   >   **DNS Options** (`auto_dns` 0/1 via `POST /api/device/<id>/auto_dns`,
   >   `POST /api/device/<id>/regen_dns`). Boutons [Edit]/[Add] dans une **toolbar
   >   au-dessus** du tableau (convention UI).
   > - **Vue BGP** (`?view=BGP`, modes `editdevbgp`/`editbgp`/`addpeer`) : boîte
   >   **Device BGP Info** éditable — BGP ID → `PATCH /api/device/<id>` ; **Local AS
   >   éditable** (le `number` de l'ASN lié → `PATCH /api/asn/<id>`, comme Mason —
   >   1 PATCH par champ modifié, JS `initBgpInfo`) ; tableau **BGP Peers** avec
   >   sections External (eBGP) / Internal (iBGP), colonne **Monitored?** (manquante
   >   dans le portage initial), liens **whois** AS depuis la config `BGP_AS_WHOIS_URL`
   >   (`<ASNUMBER>` ; eBGP skippe les AS privés 64512-65535, iBGP tous) ; édition
   >   par peer (`bgppeeraddr`/`monitored`/`contactlist` → `PATCH /api/bgppeering/<id>`,
   >   réutilisation de `initIntEdit` via `data-nd-table`), **suppression par ligne**
   >   (checkbox → batch `DELETE /api/bgppeering?id=…`) et **ajout de peer**
   >   (`POST /api/bgppeering {device, …}`, JS `initBgpAdd` — les colonnes NOT NULL
   >   omises sont defaulted par l'`insert` du modèle `_adjust_vals`, comme l'insert
   >   SNMP legacy). ⚠️ le class s'appelle `BGPPeering` (table `bgppeering`) → l'URL
   >   d'API = le **nom de table**.
   > - **Vue Access Rights** (`?view=Rights`) : même mécanique que le Rights Ipblock —
   >   table User/Group (subject lié + right), **Remove par ligne**
   >   (`DELETE /api/userright|groupright/<id>`, générique), formulaire « Add rights »
   >   (Admin) → `POST /api/accessright`. Tab Rights visible selon
   >   `access_section 'device.html:edit_rights'` (Admin/Operator), écriture Admin.
   >   **Refactor (2026-10-14, `23a9e013`)** : le handler `Api#accessright` ne duplique
   >   plus la logique — il délègue à l'overload `AccessRight->insert` du modèle
   >   (sémantiques : classes autorisées via `get_classes`, find-or-create de
   >   l'accessright, dedup des lignes join + sémantique du right `none` dans
   >   `UserRight`/`GroupRight->insert`, legacy `b912c1ed`) ; l'API n'ajoute que le
   >   check Admin, la validation de forme (ids numériques, `rights` non vide) et
   >   l'existence de l'objet, et mappe les `throw_user` du modèle en 400. ⚠️ l'overload
   >   prend une **hashref** (`AccessRight->insert({...})`) — un appel en liste de
   >   paires donne « Can't use string ("object_class") as a HASH ref » — le
   >   fix (passage en hashref) commité dans `5eaa6e72` (Fix boolean issue).
   >   ⚠️ **Booléens JSON (2026-10-14)** : `req->json` décode `true`/`false` en
   >   scalaires **blessed** (`JSON::PP::Boolean`) ; le legacy `Model::_audit`
   >   suppose blessed = objet Netdot (`->get_label()`) → 400 sur tout PATCH
   >   avec un booléen JSON (checkboxes Device Basics). Fix double :
   >   (1) `Api.pm::_args` normalise toute valeur blessed non-HASH/ARRAY en
   >   `0 + $v` à la frontière JSON (tous les handlers d'écriture y passent) ;
   >   (2) guard `blessed && $v->can('get_label')` dans `_audit` (branches
   >   insert + update). ⚠️ la 1ʳᵉ version de la normalisation était un **no-op
   >   silencieux** : `$a->{$k}` (le `$a` global de tri = hashref résiduelle du
   >   dernier `sort`) au lieu de `$a{$k}` (élément du hash local `%a`) —
   >   `perl -c` OK, sans warning. À noter : le crash d'audit survient dans le
   >   trigger `after_update` **après** l'UPDATE → un PATCH en 400 laisse
   >   quand même les valeurs commitées (2ᵉ post identique = 200 no-op, « 1er
   >   post fails, 2ème passe »). Cf. `PORTING_NOTES.md` §6.

## Déprécié / non migré — ⛔

- **Câblage & Circuits** : `backbonecable`, `horizontalcable`, `circuit` — dépréciés,
  **non migrés / non maintenus**. Un produit dédié comme **Netbox** est mieux adapté ;
  inutile de maintenir cette partie dans Netdot (cf. §4 Cable Plant).

---

## Prochaines étapes suggérées (par priorité)

> Le portage **lecture seule est essentiellement complet**. Il ne reste que du polish.

1. [x] ✅ **Recherche par type** (2026-10-03) : boîte de recherche sur **toutes** les
   listes (`list.html.ep`) + route `/management/<type>/search`. RR/Ipblock/Physaddr gardent
   leur search dédié (multi-champs name/IP/MAC, hiérarchie IP) ; les autres types passent par
   `Browse#search` (→ `Browse#list`), qui applique un **`LIKE %q%` SQL brut et paramétré sur la
   colonne primaire** (`cols[0]`), combiné à la règle 'view' par-user et paginé. ⚠️ **pas**
    `search_like()` : cette méthode est **surchargée par classe** (ex. `Device::search_like(name)`
    matche les noms RR/alias, pas `device.name`) → la recherche générique utilise du SQL direct.
    La pagination préserve la requête (`?search=…&offset=…`).
    ⚠️ **Correction (2026-10-05)** : le LIKE est **`%q%` (contient)** — avant il n'avait que
    `%q` (suffixe seulement, bug : `?search=voip` ne trouvait rien). De plus il est
    **conscient des relations** (`Model::_list_add_like`) : si la colonne est une **FK**
    (ex. `device.name`→`rr`), la recherche porte sur le **label de l'objet lié**
     (`rr.name`, le nom DNS = le libellé affiché) via `IN (SELECT id FROM rr WHERE rr.name LIKE ?)`
     et non sur la valeur numérique de la FK.
     **Recherche MAC** (`/management/physaddr/search?search=…`, `Physaddr.pm#search`) :
     `PhysAddr->search_like(address=>…)` (MAC complet ou préfixe OUI) ; 1 résultat → redirect
     vers le détail, plusieurs → table de résultats **MAC Address · First Seen · Last Seen**
     (tableau `sortable`), aucun → not found.
  2. [x] ✅ **Polish lecture seule** (2026-10-03) — tout porté :
    - **Tab Access Rights** (device) : vue `Rights` dans `Device.pm` — section
      dédiée (table User/Group : subject lié + right), Remove par ligne + formulaire
      « Add rights » (Admin) → `POST /api/accessright` (même mécanique et même
      endpoint que le Rights Ipblock — cf. « État vues device » ci-dessus).
    - **Navigation NS/MX/TXT/NAPTR** (page host/RR) : types `rrns/rrmx/rrtxt/rrnaptr`
      enregistrés (`Registry %TYPES`+`@ORDER`, `nav=>0`) + lien « Record » → page détail
      de chaque record (`link_for`).
    - **Ipblock** : lien **ASN** (type `asn` enregistré → `/management/asn/<id>`) ;
      **sélecteur v4/v6/all** (`rootversion` → `get_roots`) + **toggle utilisation**
      (`show_ch_util`, checkbox + champ caché =0) sur la vue racines.
    - **Photos de closet** : route binaire `/management/closetpicture/:id`
      (`Closet.pm#picture`, sert le BLOB `bindata` via `render(data=>)`) + section
       « Pictures » sur le détail closet. ⚠️ `Closet->pictures` (has_many CDBI) est cassé
       → `ClosetPicture->search(closet=>id)`. ⚠️ **`rendered($data)` n'existe pas** dans cet
       env (`sub rendered($self,$status)` ne prend QUE le statut) → servir du binaire avec
       `render(data => $data)` (cf. export CSV).
     - **Photos de site / floor** (2026-10-05) : routes binaires `/management/sitepicture/:id`
       + `/management/floorpicture/:id` → `Show.pm#picture` (sert le BLOB `bindata` avec le
       `filetype`), et `Registry::link_for` **spécial-case les Picture** (`SitePicture` /
       `FloorPicture` / `ClosetPicture`, qui n'ont pas de page détail) → leur libellé pointe
       vers l'image (affichée en inline). Le lien vient de la relation « pictures » du détail
       générique (1re colonne = label cliquable).
     - **Liens cliquables** : BGP « Remote IP » → `/management/ipblock/<id>` ;
       « Local AS » → `asn` (corrigé `as/`→`asn/`) ; ipblock Owner/Used by → entité ;
       détail générique : colonnes-label scalaires liées à l'objet (cas `show_label=0`,
       `Detail.pm`).
      - **Tri par la 1ère colonne** : listes + CSV + racines ipblock triées par la **1ère
        colonne d'affichage** (tie-break `id`), plus par `id`. Le `tablesort.js` ne trie
        que la page courante → il faut un tri serveur. **Tout le SQL est dans le modèle**
        (`Model::search_page`/`search_count`, `order_by => $first`, helper `_order_clause`),
        appelé aussi bien par l'API que par la liste HTML (aucun SQL brut dans les
        contrôleurs) : colonne scalaire → `ORDER BY <col> ASC, id` (collation DB) ; colonne
         **FK** (seul `device.name`→RR) → `LEFT JOIN` + tri par le label lié, prédicat
         per-user mis en sous-requête pour éviter l'ambiguïté.
         **Relations du détail** (port 2026-10-05, `Detail.pm` `relation_objects` /
         `_relation_fetch` / `_rel_label_sort`) : les tables has_many de la page détail sont
         aussi **triées + paginées en SQL** (`ORDER BY` + `LIMIT/OFFSET`, total via
         `COUNT(*)`), plus le lien CSV. Règle de tri = 1re colonne affichée : **Ipblock** →
         `address` **entière** (ordre IP naturel, IPv4 avant IPv6, exact à 128 bits) ; colonne
         label qui est une **FK** (device.name→RR) → **`JOIN` + label lié** (`rr.name`, le nom
         DNS affiché — ni la FK numérique ni `sysname` SNMP) ; sinon 1re colonne label.
  3. [x] ✅ **Édition in-situ** (2026-10-07) — formulaire d'édition sur la page détail
     (`Show.pm` + `management/detail.html.ep` + `netdot.js`), **écriture via l'API JSON**
     seule (bouton Edit → formulaire caché → `PATCH` via `fetch` → statut transitoire →
     reload). Pas de handler de formulaire côté serveur. Champs scalaires (text/number/
     textarea/checkbox) + **FK** : cible ≤ `DEFAULT_SELECTMAX`(100) → `<select>` complet
     ; cible grande (RR/Ipblock/…) → recherche par mot-clé qui remplit le `<select>` via
     l'API **`?kw=`** (jamais 100k+ options en dropdown). ⚠️ **Ipblock** : `address` est
     un `decimal(40,0)` → le `LIKE` brut ne matche pas la forme pointée → l'API spécial-
     case Ipblock via les overrides du modèle (string→int) : `search(address)` exact/CIDR
     puis `search_like(address)` (range préfixe), dédoublonné par id (cf. `keyword_search`
     legacy). Relations multi-valeurs non scalaires → restées en lecture seule.
     Formulaire extrait en **partial partagé** `management/_edit_form.html.ep` (reutilisé
     par le détail générique **et** les pages dédiées) → **Zone** (`Zone.pm` + `zone.html.ep`)
     a aussi son formulaire (SOA name/mname/rname/serial/refresh/retry/expire/minimum +
     contactlist FK + active/dnssec + default_ttl + include/info), PATCH `/api/zone/<id>`.
       **Zone**, **Contactlist** (`Contactlist.pm`), **Closet** (`Closet.pm`), **Device**
       (`Device.pm`) et **Ipblock** (`Ipblock.pm`, vue détail subnet + adresse) ont leur
       formulaire (partial partagé ; Closet/Device portent un layout curaté mais `room`
       (FK, 114 > max) passe en recherche `?kw=` ; Device = vue Basics seule, 59 champs,
       champs FK calc. uniquement sur Basics). ⚠️ **Ipblock : identité** — seuls les champs
       `version` et `parent` sont exclus du `<form>` (le parent est recalculé par la lib,
       la version découle de l'adresse) ; les champs `address` (pointillés, input text) et
       `prefix` SONT éditables : le changement d'identité (REBLOCK) est **porté par la lib**
       (`Ipblock->update` normalise l'adresse en entier et recrée la hiérarchie via
       `_update_tree`) et passe par l'API `POST /api/ipblock/:id`. Les autres champs
       « soft » du formulaire (status, owner, used_by, rir,
       asn, description, monitored, first/last seen, interface, vlan, use_network_broadcast,
        info) sont éditables. ⚠️ **`status` filtré par type de bloc** (règles
        `Model::Ipblock::_validate`) : adresse (/32//128) → Static / Dynamic (si le subnet
        parent a DHCP) / Discovered / Reserved ; subnet/container → Subnet / Container /
        Reserved. « Available » = indication de libération/suppression, pas une option
        manuelle (conservée si c'est la valeur courante, pour ne pas vider le `<select>`).
        L'API `PATCH` re-vérifie via le `update` du modèle (status invalide → 400).
       **REBLOCK** (changement network/prefix) : **porté par la lib et exposé dans le
       formulaire** (2026-10-12) — `address` (pointillés) et `prefix` sont éditables ;
       `Ipblock->update` normalise l'adresse (entier/masklen, comme `insert`), rejette un
       changement de version v4<->v6 et un bloc existant (collision), puis recrée la
       hiérarchie (`_update_tree(changed=>1)` = rebuild complet, migration des PTR,
       ré-reservation si passage en Subnet) ; un /32 déplacé déclenche aussi un rebuild
       complet (sinon l'entrée ancienne resterait dans l'arbre sauvegardé). Le formulaire
       n'envoie que `address`/`prefix` (+ les autres champs, inchangés → pas d'audit).
       **REBUILD_TREE** = debug uniquement (non traité). **ADD_BLOCKS** = non requis
       (création unitaire + découverte).
         **RR** (`Rr.pm`) a aussi son formulaire (name, zone, active, auto_update,
         expiration, info) ; les timestamps système `created`/`modified` sont exclus
         (non éditables). Tous les modèles dédiés (zone, contactlist, closet, device,
         ipblock, rr) ont leur formulaire d'édition in-situ.
         **RR — enregistrements associés (RR\*) en édition in-situ** (`Rr.pm` +
         `rr.html.ep` + `netdot.js` `initRecToggles`) : chaque enregistrement lié
         (A/AAAA, TXT, MX, NS, CNAME, PTR, NAPTR, DS, LOC, SRV, HINFO) a son formulaire
         inline (bouton Edit **par enregistrement** → `PATCH /api/<type>/<id>`, qui
          exécute le `update` du modèle). Champs éditables : **TTL** (tous types) +
          **valeur propre** — TXT `txtdata`, MX `exchange`/`preference`, NS `nsdname`,
           CNAME `cname` (**seule la vue « is an alias of »**, sur l'alias lui-même ; pas
           dans « Aliases of $o » où la cible = $o, redondante), NAPTR
           `order_field`/`preference`/`flags`/`services`/`regexpr`/`replacement`,
            DS `key_tag`/`algorithm`/`digest_type`/`digest` (tous), HINFO
            `cpu`/`os` (**`<select>`** depuis la config `DEFAULT_HINFO_CPU/OS_VALUES`,
            key=valeur DB, value=libellé), SRV `priority`/`weight`/`port`/`target`
            (tous), LOC `latitude`/`longitude`/`altitude`/`size`/`horiz_pre`/`vert_pre`
            (tous), PTR `ptrdname` (**vue « Pointer Records »** = page du PTR ; la vue
            « Reverse DNS (PTR) » sur la page d'un A est en **lecture seule**, purement
            informative). Le lien du détail de l'enregistrement est collé sur le **1er
            champ valeur** (TXT `TXT`, MX `Preference`, NS `Name Server`, NAPTR `Order`)
             ; la ligne « Record » redondante est retirée. Le formulaire **affiche tous
             les champs** (éditables en input, non-éditables en lecture seule) pour
             conserver le contexte (IP, owner, etc.). TTL validé par le modèle
             (`ttl_from_text`) ; valeur/TTL non conforme → 400.
           **RRAttr (« Other Record Types (CAA, HTTPS, …) »** : types modernes stockés
           comme valeur brute (`RRAttr` : CAA/HTTPS/SSHFP/SVCP/TLSA/URI/SMIMEA, via
           `rrattrname`). Section pilotée par la même routine `_rel_record` (meta) :
           Type (FK `name`, lecture seule) + `value` (brute, peut contenir espaces/quotes
           → échappement `&quot;` correct) + `ttl`, éditables, `PATCH /api/rrattr/<id>`.
            Validation de la valeur brute (`RRAttr::_validate_value`, 400 si invalide) :
            pas de retour à la ligne (zone = 1 record/ligne), caractères imprimables + tab
            uniquement (`^[\x09\x20-\x7E]+$`), et nombre PAIR de `"` (guillemets équilibrés).
             **Réservé aux Admins** : un mauvais champ peut invalider la zone complète → la
             section est en lecture seule pour les non-admins (`is_admin` → `_rel_record
             readonly`) avec un disclaimer (clé `warn` de la section), et l'API restreint
             create/update/delete de `RRAttr` aux admins (`Api::_admin_only_write` → 403).
           **RR — AJOUT / SUPPRESSION d'enregistrements** (`Rr.pm` + `rr.html.ep` +
           `netdot.js` `initAddForm`/`initRecDeletes`) : chaque ligne d'enregistrement a un
            bouton Delete (`DELETE /api/<type>/<id>`, `confirm()`), et une section « Add a
            record » propose les types ajoutables (A/AAAA, MX, TXT, NS, HINFO, SRV, DS,
            NAPTR, LOC, RRAttr admin-only ; **PTR uniquement dans les zones inverses**,
            `zone->is_dot_arpa`). Les formulaires sont construits en meta (`_rel_add_fields`)
            : FK du parent (owner `rr`) auto-remplie et cachée, FK petites tables (<100
            lignes, comptées par `search_count()`) en `<select>`, TTL pré-rempli avec
            `zone->default_ttl`, champs A/AAAA/PTR (`ipblock` = adresse IP en texte).
            **Tout passe par le `insert` du modèle** (`POST /api/<type>` →
            `Api::_post` → `$class->insert`) : `RRADDR`/`RRPTR` convertissent l'adresse
            string en Ipblock eux-mêmes             (`_convert_ipblock` : `Ipblock->search`, sinon
            `Ipblock->insert(status Static)`), `RRPTR` valide la zone inverse + crée le RR
            owner + verifie les types conflictuels, `RRCNAME` verifie l'exclusivité,
            TTL par defaut = zone. L'API n'ajoute que les verifications de permission
            (`_can_create` par parent) — pas de code redondant de conversion.
            **CNAME/alias** : boîtier dédié « Add an alias (CNAME) »
            (`POST /api/rr/<id>/alias` → `Api::alias` → `_create_alias` →
            `RR->insert({type=>'CNAME'})`). La zone du nouveau nom est resolue depuis le
            nom saisi : nom court → zone courante ; nom long dont la partie domaine
            correspond à une zone éditée → cette zone (partie zone retirée) ; sinon nom
            long → zone courante (ex. `www.google.com` → `www.google.com.localdomain`).
            Conflits gérés par `RRCNAME->insert` (un nom qui a d'autres records → 400).
           **RR — Nouveau nom (liste `/management/rr`)** : boîte « New name » (name +
            `<select>` de zones) côte à côte avec la boîte de recherche (`.cardrow` =
            flex/gap/wrap, largeur égale). Zone par défaut = config `DEFAULT_DNSDOMAIN`
            (pré-sélectionnée si dans la liste). **Un User ne voit que les zones où il a
            le droit `edit`** (hash `allowed_objects->{Zone}` ; s'il n'en a aucune → la
            boîte n'est pas rendue). `POST /api/rr {name, zone}` → `RR->insert` (le modèle
            valide le nom ; l'API `_can_create` re-vérifie `can('edit',$zone)`), puis
            redirection JS sur `/management/rr/<nouveau id>` (attribut
            `data-nd-redirect`, géré dans `netdot.js` `initForms`). Le nom est créé
            **sans record** : ses records s'ajoutent ensuite sur sa page.
            **RR — Delete du nom lui-même (page détail)** : bouton « Delete » à côté de
             « Edit », rendu si `can('delete',$o)` (les règles du modèle s'appliquent : pas
             de delete de l'apex par un User, pas de RR lié à un device, …). Même mécanique
             générique que les boutons delete des records : `DELETE /api/rr/<id>` (le
             `delete` du modèle), avec `confirm()` adapté (« this object and all its
             records ») puis redirection sur la liste (`data-nd-goto`, géré dans
             `netdot.js` `initRecDeletes` qui supporte aussi bien reload que goto).
           **Suppression par lots (listes génériques)** : les cases à cocher des listes
            (`browse#list`, tous les types) passent désormais par l'API en **un seul appel**
            : `DELETE /api/<type>?id=1,2,3` (`Api::generic` accepte une liste d'ids en
            query string, modèle de recherche). `Api::_batch_delete` vérifie `can('delete')`
            **objet par objet** (pas d'abort au 1er id en erreur) et répond
            `{deleted:[...], skipped:{id:raison}}` (200 si ≥1 supprimé, 400 sinon).
            Le bouton « Delete » de la liste est piloté par `netdot.js`
            `initBatchDelete` (compteur « N selected », `confirm()`, reload après).
            **L'ancienne route serveur `POST /management/<type>/delete`
            (`browse#delete`) est supprimée** — plus d'écriture côté serveur, tout passe
            par l'API JSON.
        ⚠️ **Champs temps (édition in-situ, tous les objets)** : les colonnes de type
       `timestamp` (Last ARP / Last FWT / Last Updated / First Discovered / …) sont
       **exclues du formulaire d'édition** (lecture seule, info seulement) — c'est ce
       que fait la vue Mason Basics (`edit=>0`). Elles restent visibles dans la table
       d'attributs. Les colonnes de type `date` (Down From / Down Until) restent
       éditables, rendues en **date picker** `<input type="date">` (format `YYYY-MM-DD` ;
       la valeur zéro `0000-00-00` → champ vide ; vider le champ → `NULL`).
      ⚠️ **Une FK n'apparaît en édition que si sa cible est enregistrée** dans le Registry
      (`spec(target)`), sinon `build_edit_fields` la saute silencieusement. 4 types de
      recherche manquaient → ajoutés à `%TYPES`+`@ORDER` : `usertype` (Person.user_type),
      `contacttype` (Contact.contacttype), `dhcpscopetype` (DhcpScope.type), `entitytype`
      (EntityRole.type). (Scan exhaustif : c'était l'intégralité des cibles manquantes.)
4. ⛔ **Câblage/circuits** — dépréciés (Netbox).
5. 🔶 **Création — raffiner la permission par parent** : `_can_create` est une approximation
   (l'objet cible n'existe pas → `can('edit', $parent)` sur le parent FK) ; couvre zone→rr,
   rr→rrtxt/rrcname, device→interface, contactlist→contact. À évaluer : faut-il aussi couvrir
    le fallback « IP dans un bloc autorisé » (héritage complet `ObjectAccessRule`) pour la création ?
6. ⬜ **Perf affichage IP (gros sous-réseaux)** — discussion 2026-10-09, **non engagé** :
   - **Symptôme** : affichage d'une plage d'IP lent sur de très gros sous-réseaux.
   - **Cause** (`Ipblock::search_like`, `lib/Netdot/Model/Ipblock.pm:269-302`) : sur le range
     `address>=? AND address<=?`, **par ligne** `search(address=>$x)->first` (**N+1**, le vrai
     tueur) + `int2ip` (`Math::BigInt`) + `cidr()` ; puis **tri Perl** `address_numeric <=>`.
   - **Options discutées** :
     - `VARBINARY(16)` / PG `INET` : binaire natif → `INET6_NTOA` en SQL (zéro `Math::BigInt`)
       + `ORDER BY` byte-wise en SQL (indexable). **Coût** : refacto du modèle `Ipblock` (tout est
       en entier : `ip2int`/`int2ip`, maths first/last/mask/usage, `address_numeric`) → **pas un
       drop-in**. Ordre « v4 avant v6, 128 bits » : `ORDER BY version, address` (ou `family()` en PG).
     - Fonctions natives `inet_pton`/`inet_ntop` : `INET6_ATON`/`INET6_NTOA` (v4+v6, **binaire**)
       depuis **MySQL 5.6.24 / MariaDB 10.0** ; `INET_ATON`/`INET_NTOA` (v4, entier). **Serveur
       actuel = MariaDB 11.8.6 → déjà dispo** (vérifié `INET6_NTOA(INET6_ATON('::1'))` = `::1`).
   - **Plan recommandé (2 phases)** :
     1. **Sans changer le schéma** : réécrire `search_like` en **une seule requête** (supprimer le
        N+1) + `ORDER BY address` en SQL → plus gros gain, risque faible.
     2. **Optionnel** : colonne `VARBINARY(16)`/`INET` → affichage 100 % natif (`INET6_NTOA`).
   - **Décision (2026-10-09)** : non engagé pour l'instant.

> ✅ **Détails spécialisés tranchés (2026-10-01)** : seuls **3** des 11 types du
> détail générique avaient une vraie page Mason dédiée (`%VIEWPAGE` dans
> `lib/Netdot/UI.pm`) : **zone**, **contactlist**, **closet** — tous portés (✅ dédié).
> Les 8 autres (asset, vlan, person, entity, site, room, floor, service) utilisent la
> page générique `view.html`, déjà portée par `Show.pm`.
> ✅ **Help tranché (2026-10-01)** : Manual + Database Schema + Graph — cf. §8.

---

## État vérifié (2026-09-30, branch `dev`)

- **DHCP** : nav (Management → DHCP), liste 455 scopes (colonnes dédiées, pagination),
  détail + drill-down `contained_scopes` (liens vers enfants, 409 sous le scope global),
  CSV liste + CSV relation. Régression vérifiée (Device/Ipblock, liens FK intacts).
- 20 routes de liste = **200** (Admin) : device, asset, vlan, ipblock, rr, zone, person,
  entity, contactlist, site, closet, room, floor, interface, physaddr, service,
  dhcscope, circuit, backbonecable, horizontalcable.
- Détail générique OK (ex. `/management/zone/2` = 200).
- Reports = **200** (Admin) / **403** (User sans droits).
- **Export** (`/export`) = **200** (Admin, User avec droits écriture RR) / **403** (User sans droits) ;
  **12 types** exécutés avec succès par l'Admin (BIND, NAMED, RFC952, GIT, PLAYBOOK, UNILSTAT,
  DHCPD, Nagios, Sysmon, Rancid, Smokeping, Apache) — fichiers écrits dans `export/` ;
  un User à droits écriture n'accède qu'aux 4 types DNS/DHCP.
- `tablesort.js` : 15/15 tests unitaires, servi en 200, référencé par le layout.
- **Pages d'erreur** : 403 (Access denied) / 404 (Page Not Found) / 500 (Internal Server Error)
  brandées Netdot (layout default : header, navbar, CSS) — helpers `reply.html_not_found`
  et `reply.html_exception` dans `Netdot::Mojo.pm` remplacent les pages debug Mojolicious.
- **Changelog** (`/changelog`) = **200** (Admin + User) : 200 dernières entrées d'audit,
  nav « Advanced » → « Changelog » (interface/physaddr/service masqués du nav, routes intactes).
- **Recherche globale** (`/search`) = détection IPv4/IPv6 → redirect ipblock search,
  MAC → redirect physaddr search, texte → `RR->search_like(name)` (redirect si 1 résultat,
  sinon table Name+Zone).

### Vérifié le 2026-10-05 (UI moderne + corrections)

- **UI moderne** : tabs client (bascule instantanée + `?rel=`), tableaux de champs
  `datatable.detail` (colonnes `c1`/`c2`/`c4`), cartes `.container` (champs en carte +
  `.containerhead`), carte à onglets `.tabcard`, tableaux `datatable` (look) / `sortable`
  (tri JS), navbar sticky, boutons — servis en 200, cohérents sur listes/détails/reports/search.
- **Tri des relations** (page détail) : subnets d'un site triés par **adresse IP entière**
  (IPv4 avant IPv6) ; devices triés par **`rr.name`** (nom DNS, via `JOIN rr`) et non par la
  FK numérique ni `sysname`. Pagination cohérente (pas de doublon entre pages).
- **Recherche device** (`/management/device/search?search=…`) : trouve par **nom DNS**
  (`rr.name`, `LIKE %q%` contient) — ex. `voip` → 1395 (dont `voip-am-181`), `max` → 116.
- **Photos site/floor** : `/management/sitepicture/:id` sert le JPEG en inline (200,
  `image/jpeg`) ; le libellé de la relation « pictures » du détail site est cliquable.
- **Recherche globale** (`/search?q=…`) : tableau **2 en-têtes = 2 colonnes** (avant :
  « Name » dupliqué, 3 en-têtes / 2 colonnes).
- **Help Database Schema** (`/help/database`) : les valeurs par défaut **bool** s'affichent
  `true`/`false` (avant : `SCALAR(0x…)` — ref dé-référencée dans `Meta/SQLT.pm`).
- **Champs en cartes** : Device Basics, Ipaddress, Ipblock, RR, Zone, ContactList,
  Closet, détail générique → champs en `datatable.detail cN` (2 paires/ligne par défaut)
  dans une carte `.container` + `.containerhead` ; plus de `white-space:pre-wrap` sur les
  `td` (hauteur de cellule uniforme 38px).
- **Carte à onglets `.tabcard`** : device (`Basics`/`Interfaces`/`IP`), détail générique
  (`?rel=`, ex. site/1 = 5 onglets), ipblock (sections) → onglets + contenu dans une seule
  carte, contenu intérieur aplati.
- **Login** : champs alignés (empilés, pleine largeur), bouton `.btn`, bouton header
  « log in » masqué ; soumission OK (redirect home), échec → `<p class="error">`.
- **Recherche MAC** (`/management/physaddr/search?search=D0C24E`) : colonnes **First Seen**
  + **Last Seen** ajoutées (format `AAAA-MM-JJ HH:MM:SS`, cohérentes avec le détail) en plus
  de l'adresse MAC liée ; 200, tableau `sortable`.
- **Rapports en design 2026** : les tables de rapports (`/reports/device`, asset, macs,
  ipbat, security, database, …) utilisent `<thead>`/`<tbody>` + `datatable` (plus de classes
  legacy `formtabletitle`/`datatablerN`) → en-tête, zebra et coins arrondis modernes.

### Vérifié le 2026-10-14 (vues device IP/BGP/Access Rights)

- **Pages BGP** (device 532 `cr-bu21` = 2 peers, local AS 65310, bgpid 10.55.3.10 ;
  device 12115 = sans BGP) : vue / `editbgp=1` / `addpeer=1` / `editdevbgp=1` = **200** ;
  sections eBGP/iBGP, colonne Monitored, boutons [Edit]/[Add] au-dessus du tableau
  ([Add] visible même sans peer) ; liens whois radb.net rendus pour un AS public
  (23456, device 11380) et correctement **absents** pour un AS privé en eBGP (65130) ;
  device sans local AS → `n/a` + `data-nd-asn-id=""` (le JS saute le PATCH ASN).
- **Pages Rights** : affichage (User/Group, subject lié, right) + formulaire « Add
  rights » (Admin) ; tab Rights gated par `access_section` (masqué sinon).
- **API round-trips** (DB vérifiée avant/après, état restauré) :
  `PATCH /api/bgppeering/<id>` (bgppeeraddr/monitored), `POST /api/bgppeering`
  (création, defaults `max_v4/v6_prefixes=0` via `_adjust_vals`) + `DELETE`
  (réponse single `{"deleted":"BGPPeering/<id>"}`), `PATCH /api/device/532 {bgpid}`,
  `PATCH /api/asn/2 {number}` (local AS, aller-retour 65310→65311→65310),
  `POST /api/accessright` (user + group, Device + Ipblock ; re-grant idempotent =
  pas de doublon de ligne join grâce à l'overload du modèle) +
  `DELETE /api/userright|groupright/<id>` ; cas d'erreur 400/404 vérifiés
  (`rights` vide, droit invalide, subject inexistant, classe non autorisée via
  `get_classes`, objet inexistant).
- **JS** : harnais DOM-stub Node (`/tmp/js_bgp_test.js`) — A (édition peers :
  PATCH des seuls champs sales + batch DELETE), B (info : PATCH device + PATCH asn),
  C (add : POST body complet) → **PASS** ; `initRights` inchangé (générique).
- **Log daemon** : 0 erreur depuis le dernier restart (hors bruit préexistant :
  compile error `device_discover.html.ep` + passphrases USM SNMP).
- **Booléens JSON** (Device Basics) : `PATCH {"collect_stp":true}` 0→1, post
  identique répété, 1→0 → tous **200** (avant : 1er post 400 `get_label` sur
  `JSON::PP::Boolean`, 2ᵉ post 200 — le SQL étant commité avant le crash du
  trigger `after_update`) ; l'audit enregistre bien `1`/`0` dans `vals` ;
  état du device restauré. Fixs : normalisation `_args` + guard `_audit`
  (cf. `PORTING_NOTES.md` §6) — commit `5eaa6e72`.
