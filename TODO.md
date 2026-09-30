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

## 4. Cable Plant — ⚠️ divergence avec l'original

Le nav Mojo ≠ le menu original.

| Type (route)       | Dans le nav Mojo | Dans l'original | État |
|--------------------|------------------|-----------------|------|
| site               | ✅               | ✅ (SITES)      | 🔶 gén. |
| closet             | ✅               | ✅ (CLOSETS)    | 🔶 gén. |
| room               | ✅               | — (ajout)       | 🔶 gén. |
| floor              | ✅               | — (ajout)       | 🔶 gén. |
| **backbonecable**  | ⬜ **absent**    | ✅ (BACKBONE)   | 🔶 routable, non listé |
| **horizontalcable**| ⬜ **absent**    | ✅ (HORIZONTAL) | 🔶 routable, non listé |
| **circuit**        | ⬜ **absent**    | ✅ (CIRCUITS)   | 🔶 routable, non listé |

> `backbonecable`, `horizontalcable`, `circuit` sont **routables (200)** mais absents du nav.
> **Décision à prendre** : Cable Plant = {Sites, Closets, Rooms, Floors} (actuel) ou
> {Sites, Closets, Backbone, Horizontal, Circuits} (original) ?

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

## 7. Export (section Admin) — ⬜ section entière manquante

- [ ] ⬜ **Configurations** : export des configs devices (`htdocs/export/`). Pas de route/controller.

## 8. Help — ⬜ section entière manquante

- [ ] ⬜ **User Manual** (`htdocs/help/`)
- [ ] ⬜ **Database Help** (schéma/relations)

---

## Hors périmètre (écriture) — ⛔

Objectif = vues lecture seule. Pages de création/édition/suppression **non portées** :
`device_tasks`, `asset_tasks`, `dhcp_tasks`, `host_tasks`, `vlan_tasks`, `zone_tasks`,
`address_tasks`, `addneighbor`, `addservice`, `choose_ip`, `updatedevice`, `template_edit`,
`ip-rec`.

---

## Prochaines étapes suggérées (par priorité)

1. ⬜ **Nav** : ajouter Backbone/Horizontal/Circuits (Cable Plant) ; trancher la divergence Cable Plant. (DHCP ✅ fait)
2. ⬜ **Détails spécialisés** (si parité avec l'original) pour : asset, vlan, zone, person, entity, contactlist, site, closet, room, floor, service.
3. ⬜ **Section Export** (Configurations) — Admin.
4. ⬜ **Section Help** (Manual + Database Help).
5. ⬜ **Page Advanced DB-ops** (si on conserve la structure originale).
6. ⛔ **Édition** (hors périmètre — à re-évaluer si demandé).

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
- `tablesort.js` : 15/15 tests unitaires, servi en 200, référencé par le layout.
