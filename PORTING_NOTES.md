# Netdot → Mojolicious : notes de portage

Objectif : porter la web-app Netdot (Apache/mod_perl + Mason `.mhtml`) vers
**Mojolicious**, en réutilisant `Netdot::Model`. Portage type par type,
contrôleurs **lecture seule** d'abord.

## Stack / environnement
- Perl 5.40.1 + Mojolicious 9.39.
- BDD **mysql** (voir `etc/Site.conf`).
- Auth LDAP + fallback local.
- Branch git `dev`. L'utilisateur commit à chaque étape.
  **Ne jamais commit/push sans demande.**

## Workflow de validation
- Syntax : `perl -c -Ilib` sur chaque fichier perl modifié.
- Test E2E :
  `bin/mojo daemon -l http://127.0.0.1:8899 -m development &` → kill par port.
  Login : `curl -c ck.txt -d "username=<user>&password=<pass>" /login` (302).
- Bare-`-e` : `use Netdot::Model` charge config+DB ; mais les classes RR*
  (RRMX, RRNS, …) ne se chargent que via les relations RR.
- À chaque étape : vérifier la page ciblée (200, contenu présent) **et** une
  régression (liste du type + un type générique).

## Architecture ciblée
- **Un contrôleur dédié par type majeur** (`Controller/Ipblock.pm`,
  `Controller/Rr.pm`, …), action `show`. Le détail générique reste dans
  `Controller/Show.pm`.
- `lib/Netdot/Mojo.pm` : route `/management/<type>/<id>`, map
  `my %show_ctrl = ( ipblock => 'ipblock', rr => 'rr' );` → contrôle dédié si
  présent, sinon `show#show` (générique). Ajouter un type = une entrée dans la
  map + un `Controller/<Type>.pm`.
- Template par type : `htdocs/management/<type>.html.ep`.
- Les pages racines/breadcrumb sont rendues par `Browse#list` ; elles
  n'exposent PAS les variables du détail (ex. `$block_attrs`) → d'où la règle
  de préambule ci-dessous.

## Pièges (critiques)

### 1. CDBI + `wantarray`
`eval { $class->search(...) } // ()` dégrade `wantarray` : les **itérateurs
CDBI** (retournés par `->children` ET par `->search()`) sont alors stringifiés
au premier `@{ }` / `->first` → `[eval ...] is not an ARRAY reference`.
- Ne jamais `// ()` autour d'un appel de méthode CDBI qui itère.
- Itérer explicitement l'itérateur (`$it = $obj->children; while ($c = $it->next)`)
  ; helper local `_search_all($class, ...)` = `my $r=$c->search(...); my @out;
  while (my $o=$r->next){push @out,$o} @out` quand un array est attendu.

### 2. Templates `.ep`
- **Préambule** : chaque variable du stash utilisée dans le corps doit être
  déclarée `my $x = $c->stash->{x} // default;`. Une var absente du stash →
  erreur `strict` "requires explicit package name".
- `% if/else`, `% for { <tr> }` **en ligne unique ne compile PAS** → multi-lignes.
- `esc` n'existe pas dans le code Perl du contrôleur (helper de template) →
  helper local `_esc` (`s/([&<>"])/\u$1/ge`) ou `escape()` dans `.ep`.
- `esc()` dans `.ep` échappe le HTML ; pour du HTML déjà formaté (grille,
  percent_bar) utiliser `==` (`<%== $var %>`).

### 3. Modèles
- `Registry::link_for($obj)` renvoie une **arrayref** `[text, href]` →
  déréférencer avec `@{ }`. Génère `/management/<type>/<id>` pour tout type
  enregistré dans `lib/Netdot/Mojo/Registry.pm` (`%TYPES`, `@ORDER`).
- Objets FK stringifient à leur **id** → utiliser `->name`, `->get_label`,
  `->format_address`, ou `Registry::link_for`.
- **Registry (`lib/Netdot/Mojo/Registry.pm`)** : `%TYPES` minimal =
  `{ class, [nav=>0], [label] }`. `label` (nom méta), `desc` (description méta)
  et `cols` (vue `brief`) sont **dérivés** du méta via `spec()` (mémoïsé) →
  `netdot.meta` = source unique. `display_columns($class)` = vue `all` + tags
  (détail générique). `nav=>0` = objet `linksto` (routable + détail générique,
  masqué de la nav). Les cibles FK « objets » (Product, Availability, Circuit,
  ArpCache, SiteLink, FWTable, STPInstance, HorizontalCable, BackboneCable,
  DhcpScope) sont enregistrées pour que `link_for` les lie.
- **`get_column_order(view=>…)` / `get_column_order_brief()`** renvoient un
  **hash** colonnes→position → appeler en contexte liste :
  `eval { %o = $m->get_column_order_brief(); 1 }` puis
  `sort { $o{$a}<=>$o{$b} } keys %o` (sinon `wantarray` dégradé).
- **Titre du détail générique** : `$obj->get_label` (construit depuis
  `label => [...]` de `netdot.meta`), repli `Type #id`.
- FK du type "nom de domaine → RR" : résoudre avec `RR->search({name=>...})`
  (helper `_name_link`).
- Dates : masquer les valeurs nulles/vides (`_dt_ok`).

### 4. Grille container (portage Mason `container.mhtml`)
- Base d'unité = **/32** (pas /28), sinon les enfants plus fins (ex. /29)
  ont une largeur fractionnaire (0.5) qui casse la grille.
- `cellsperrow = (rowsize>=22) ? 1024 : 2**(32-rowsize)` ; largeur cellule =
  `(2**(32-prefix)) * (2**(rowsize-22))` px. 1 ligne = 1 bloc /rowsize.
- v6 non supporté (message). Liens `/management/ipblock/<id>`.

## Référence Mason → Mojolicious
- Vue générique d'un record : `htdocs/generic/view.html?table=X&id=Y`.
- Portage type : reprendre la page Mason (`htdocs/management/*.mhtml`) et ses
  helpers, adapter vers contrôleur dédié + `.ep`.
- Mécanique de liens de champs : `lib/Netdot/UI.pm` (`form_field`/
  `add_to_fields`, `linkPage`/`linkpages`). NS/MX/TXT/NAPTR → `view.html`
  (vue du record) ; PTR → `host.html` (vue host).
- Styles : `htdocs/css/style.css` (`.ipaddr_*`, `.ipcontainertable`,
  `.tablescroll`, `.container*`, `.progress_bar`).

## Fichiers clés
- `lib/Netdot/Mojo/Controller/Ipblock.pm` — détail bloc (show + helpers
  `_block_attributes`, grille, sites/zones/dhcp/attrs/arp/audit).
- `lib/Netdot/Mojo/Controller/Rr.pm` — détail host (show + `_rr_attributes`,
  `_rr_sections`, `_search_all`, `_name_link`, `_obj_link`).
- `lib/Netdot/Mojo/Controller/Show.pm` — détail générique (14 types).
- `lib/Netdot/Mojo/Registry.pm` — catalogue de types, `link_for`, `format_value`,
  `spec`, `is_sensitive`, `csv_field`.
- `lib/Netdot/Mojo.pm` — app, routes par type, auth hook.
- `htdocs/management/{ipblock,rr,ipaddress,detail}.html.ep` — templates.
- `htdocs/management/host.html` (1136 l.), `container.mhtml`,
  `htdocs/generic/view.html` — références Mason.
- `etc/netdot.meta` — schéma FK/relations.

## État (à mettre à jour)
- Fait : responsive/htmx, Bootstrap, Auth, nav générique, design,
  pagination/CSV/delete, ipblock (nav, subnets, container grid, tree, onglets,
  adresse IP, attrs du bloc, types génériques), **table RR (host)**.
- En cours : navigation records liés (NS/MX/TXT/NAPTR → vue du record RRNS/
  RRMX/RRTXT/RRNAPTR ; PTR → host ok).
- Différé : Access Rights tab ; toutes les fonctions d'écriture ; omissions
  mineures read-only (lien ASN, sélecteur v4/v6, toggle utilization).
