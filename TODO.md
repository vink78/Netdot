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
| zone                | DNS Zones (ZONES)      | 🔶 gén.  | ✅          |
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
| contactlist  | Contact Lists (CLISTS) | 🔶 gén.| ✅          |

## 4. Cable Plant — ✅ tranché : Sites, Closets, Rooms, Floors

Seuls **Sites**, **Closets**, **Rooms** et **Floors** sont utiles (portés). Le câblage
(backbone/horizontal) et les **Circuits** sont **dépréciés**.

| Type (route)        | État                          |
|---------------------|-------------------------------|
| site                | 🔶 gén. (utile)               |
| closet              | 🔶 gén. (utile)               |
| room                | 🔶 gén. (utile)               |
| floor               | 🔶 gén. (utile)               |
| ~~backbonecable~~   | ⛔ **déprécié** — non migré    |
| ~~horizontalcable~~ | ⛔ **déprécié** — non migré    |
| ~~circuit~~         | ⛔ **déprécié** — non migré    |

> **Décision (2026-10-01)** : `backbonecable`, `horizontalcable`, `circuit` sont **dépréciés** —
> à **ne pas migrer / ne pas maintenir** (routables (200) aujourd'hui mais non listés). Un produit
> dédié comme **Netbox** est mieux adapté à la gestion du câblage / des circuits ; il ne sert à
> rien de maintenir cette partie dans Netdot.

## 5. Advanced / Generic — ⚠️ réinterprété

L'original « Advanced » = page **Advanced Database Operations** (ops DB : vacuum, reindex…).
Le nav Mojo a réinterprété « Advanced » comme liste des types « en vrac » :

| Type (route) | Détail   | Dans le nav |
|--------------|----------|-------------|
| interface    | ✅ dédié (Interface.pm + i_fdb/i_arp) | ✅ |
| physaddr     | ✅ dédié (Physaddr.pm + mac.html.ep)   | ✅ |
| service      | 🔶 gén.                         | ✅ |

- [ ] ⬜ Page « Advanced Database Operations » de l'original (vacuum/reindex/…) non portée.

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

## 7. Export (actions réservées aux droits d'écriture) — ✅ portée (DNS + DHCP + RFC952)

- [x] ✅ **Configurations** (`/export`, `Controller/Export.pm`) : export de configs tierces
  via `Netdot::Exporter->generate_configs`. Types portés : **BIND, NAMED, RFC952** (DNS)
  + **DHCPD** (DHCP). Formulaire (types, zones, scopes, force, options HINFO/TXT privées) ;
  log de l'exporteur capturé (String appender) et affiché ; erreurs par type listées.
- **Permission** : réservée aux droits d'écriture — `Permissions::can_export` =
  `has_action('RR', edit) || has_action('RR', delete)` (grant Zone→RR). Admin = toujours ;
  User/Operator si droits écriture sur au moins une zone. (Original : `access_admin_section` / Admin only.)
- ⛔ Types restants (Nagios, Sysmon, Rancid, Smokeping, Apache, GIT, PLAYBOOK, UNILSTAT) :
  réservés aux admins, **non portés**.
- **Config/env** : ajout `REMOTE_EXEC => 0` dans `etc/Default.conf` (SCP vers serveurs
  distants désactivé ; sans cette clé `config->get` levait « Unknown configuration item »).
  Dirs locaux `export/{bind,dhcpd,named,rfc952}` créés.
- Vérifié : admin + smobile (User, droits écriture zones 114/115/116) voient Export et
  exportent (fichiers écrits) ; guest (sans droits) = 403 + nav masquée.

## 8. Help — ⬜ section entière manquante

- [ ] ⬜ **User Manual** (`htdocs/help/`)
- [ ] ⬜ **Database Help** (schéma/relations)

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

1. ⬜ **Section Help** (Manual + Database Help).
2. ⬜ **Détails spécialisés** (si parité) pour : asset, vlan, zone, person, entity, contactlist, site, closet, room, floor, service.
3. ⬜ **Page Advanced DB-ops** (si on conserve la structure originale).
4. ⛔ **Édition** (hors périmètre — à re-évaluer si demandé).

> ✅ **Cable Plant tranché (2026-10-01)** : on garde Sites, Closets, Rooms, Floors ;
> backbone/horizontal/circuit **dépréciés** (non migrés) — cf. §4 + Netbox.
> ✅ **Export tranché (2026-10-01)** : DNS (BIND/NAMED/RFC952) + DHCP (DHCPD) portés,
> réservés aux droits d'écriture (RR) ; le reste (Nagios/Sysmon/…) réservé aux admins.

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
  4 types exportés avec succès (BIND, NAMED, RFC952, DHCPD) — fichiers écrits dans `export/`.
- `tablesort.js` : 15/15 tests unitaires, servi en 200, référencé par le layout.
