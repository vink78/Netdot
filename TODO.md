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

- [x] ✅ **Changelog** (`/changelog`, `Controller/Advanced.pm`) : 200 dernières
  entrées d'audit (tstamp DESC), table : Timestamp / User / Table / Label / Operation / Fields / Values.
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
  `?linked_from=1`), GET `/api/{table}/{id}`, `meta_data`, POST créer/mettre à jour, DELETE.
- [x] ✅ **Endpoints dédiés** : `devinfo`, `host_contacts`, `ipattr`, `host`, `host_like`,
  `updatedev`.
- [x] ✅ **Index** (`GET /api`) : flat-map Netbox-style `{resource: url-absolute}` (tables +
  endpoints dédiés + `docs` + `openapi.yaml`).
- [x] ✅ **Erreurs JSON-aware** : tout `/api/…` répond en JSON (404/405/500), quel que soit
  l'`Accept` (handlers `reply.*` path-aware) ; hors `/api` → pages HTML Netdot.
- [x] ✅ **OpenAPI 3** généré depuis `netdot.meta` : `lib/Netdot/Mojo/OpenAPI.pm` +
  `api/gen_openapi.pl` → `api/openapi.yaml` ; Swagger UI en `/api/docs` (page standalone).

**Déploiement sous préfixe `/netdot`** (Apache/nginx en front) :
- [x] ✅ **`WEB_BASE_URL` = préfixe de chemin** (`/netdot`) dans la config (pas une URL
  absolue) → identique en dev et en prod. L'app est montée sous ce préfixe **des deux côtés** :
  routes (`->under($base)`), static (`css|img|java_script` sous le préfixe), `before_dispatch`
  et nav path-aware, helper `web_prefix()` pour les liens durs restants.
- [x] ✅ **Proxy (préservation du préfixe)** : `ProxyPass /netdot → http://127.0.0.1:3000/netdot`
  (nginx : `location /netdot/ { proxy_pass http://127.0.0.1:3000; }` **sans slash final**).
- [x] ✅ **Dev** : `http://127.0.0.1:3000/netdot/` ; **Prod** : `https://netdot.localdomain/netdot/`.
  URLs absolues de l'API = `<origin de la requête><préfixe>` (ex. `…/netdot/api/device`).

---

## Hors périmètre (écriture) — ⛔

Objectif = vues lecture seule. Pages de création/édition/suppression **non portées** :
`device_tasks`, `asset_tasks`, `dhcp_tasks`, `host_tasks`, `vlan_tasks`, `zone_tasks`,
`address_tasks`, `addneighbor`, `addservice`, `choose_ip`, `updatedevice`, `template_edit`,
`ip-rec`.

## Déprécié / non migré — ⛔

- **Câblage & Circuits** : `backbonecable`, `horizontalcable`, `circuit` — dépréciés,
  **non migrés / non maintenus**. Un produit dédié comme **Netbox** est mieux adapté ;
  inutile de maintenir cette partie dans Netdot (cf. §4 Cable Plant).

---

## Prochaines étapes suggérées (par priorité)

> Le portage **lecture seule est essentiellement complet**. Il ne reste que du polish.

1. ⬜ **Recherche par type** : action `search` manquante pour tout type hormis
   RR, Ipblock, Physaddr. Soit ajouter `search` aux controllers dédiés (device,
   zone, vlan, asset, …) + un `search` générique dans `Show.pm`, soit masquer le
   champ de recherche des listes qui n'en ont pas (le search global home couvre IP/MAC/texte).
2. ⬜ **Polish lecture seule** : tab *Access Rights* (device) ; navigation
   *NS/MX/TXT/NAPTR* depuis la page host ; lien ASN, sélecteur v4/v6, toggle
   utilisation (ipblock) ; affichage des photos de closet (binaire).
3. ⛔ **Édition** (hors périmètre — à re-évaluer si demandé).
4. ⛔ **Câblage/circuits** — dépréciés (Netbox).

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
