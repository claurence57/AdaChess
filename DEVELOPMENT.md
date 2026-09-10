# Notes de développement — AdaChess / AdaChess-BB

Ce document résume le parcours du projet : les améliorations apportées au moteur
**AdaChess** (mailbox, dit **MB**), la création du moteur **AdaChess-BB** (bitboard,
dit **BB**), les différences entre les deux, et l'état des améliorations jusqu'ici.

---

## 1. AdaChess (MB) — les améliorations apportées

Le moteur d'origine (`adachess.gpr` → `adachess.exe`/`adachess`) est écrit en Ada
avec une représentation **mailbox** (plateau `array (0..119)` = 10×12, cases 0..119).
Il servait à l'origine en console / XBoard. Au fil du projet il a reçu plusieurs
corrections de **protocole et de robustesse** :

| Commit | Description |
|---|---|
| `1b55531` | **Réponse `ping`→`pong`** (Scid attendait cette synchro) et **analyse interruptible** : lecture des commandes pendant la recherche, abandon/reprise sur changement de position (résout le blocage « figé sur l'ancienne position » dans Scid). |
| `c966f65` | Support de la commande **`move <coord>`** (cutechess) et correction de la sémantique **`white`/`black`** = couleur du moteur. |
| `a711b32` | Parse du **`level MM:SS`** de cutechess (passe en mode blitz pour rester dans le temps). |

MB est conservé comme **référence** : c'est l'oracle de perft et l'adversaire de
référence des matchs. Son évaluation reste beaucoup plus riche que celle de BB.

## 2. Création d'AdaChess-BB (bitboard)

Objectif (choisi au départ) : **apprendre** en construisant un moteur bitboard
indépendant, validé contre MB.

Décisions structurantes :
- **Deux projets `.gpr` indépendants** dans le même dépôt (option 2) :
  - `adachess.gpr` → MB (inchangé, sources `src/`) ;
  - `adachess_bb.gpr` → BB (sources `src_bb/`, exécutable `bin_bb/adachess_bb`).
- **Réécriture propre** en Ada 2012, représentation bitboard (64 bits/case,
  a1 = bit 0 … h8 = bit 63).

| Commit | Description |
|---|---|
| `1d71dc7` | Moteur BB complet : plateau/pièces, **magic bitboards** (fous/tours/dame), movegen légal, make/unmake, parseur FEN, **perft** validé, évaluation + recherche alpha-bêta de base, interface XBoard, self-tests. |

## 3. Différences entre MB et BB

| | **MB (mailbox)** | **BB (bitboard)** |
|---|---|---|
| Plateau | `array(0..119)` de pièces (10×12, cadre) | 12 bitboards 64 bits (un par pièce) + occupation |
| Case | 0..119, a8=21…h1=98 | 0..63, a1=LSB…h8=MSB |
| Génération de coups | Movegen légal optimisé spécifique (dans le moteur) | pseudo-coups + **filtre de légalité par épingles** (seuls roi/pièces épinglées/en passant sont testés quand pas en échec) |
| Make/Unmake | Historique intégré au plateau | **Snapshot + `Undo_Info`** (position copiable, pratique perft/search/FEN) |
| Évaluation | Très riche (~2 500 lignes, spécifique mailbox) | Matériel + PST, **interpolé ouverture/finale (phase)** : mobilité, paires de fous, tours (colonnes ouvertes, 7ᵉ), pions passés, **sécurité du roi**, activité du roi en finale |
| Recherche | Alpha-bêta (profonde), clocks | Alpha-bêta + **table de transposition** (1 M) + itération itérative + quiescence (coups tactiques) + **PVS, killers/MVV-LVA, LMR, null-move** |
| Hachage | Zobrist incrémental | **Zobrist** recalculé à chaque make, **désactivé pendant le movegen** |
| Protocole | XBoard/Winboard | XBoard/Winboard (même sous-ensemble) + horloge `level`/`time`/`otim` |
| Force actuelle | Nettement supérieure | Plus faible à temps long, mais **tient/bat MB en rapide** (1 s+0,1 s) après la dernière session |
| Projets | `adachess.gpr` | `adachess_bb.gpr` |

## 4. Améliorations apportées à BB jusqu'ici

### Movegen & règles
- Perft validé sur la position initiale (d1→d5) et sur des suites **roque / en passant /
  promotions** — valeurs identiques aux constantes connues **et** à MB (oracle).
- `334874d` — **Correction des droits de roque** : les droits sont désormais
  **événementiels** (perte si le roi bouge, si la tour de coin bouge ou est capturée),
  plus jamais dérivés de l'occupation. Corrigeait le bug « BB joue un roque `e8c8`
  illégal » (roi sorti puis revenu en e8).
- `2524768` — **Movegen légal optimisé** : calcul du **masque d'épingles** ; quand on
  n'est pas en échec, seuls roi, pièces épinglées et en-passant sont vérifiés par
  make/unmake. Perft strictement inchangé.

### Recherche
- `2132117` — **Quiescence bornée** : coups **tactiques seuls** + profondeur max 4
  (fin des explosions 5–9 s).
- `28c8435` — **Ordonnancement** des coups (tactiques d'abord) ; profondeur par coup
  portée à 5.
- `2524768` — profondeur par coup portée à **6**.
- *(après `11f33f9`)* — **SEE** (Static Exchange Evaluation) : package
  `BBChess.See` (`bbchess-see`) qui évalue la séquence de captures sur une case
  (attaquant le moins cher d'abord, **épingles exclues**, roi seulement en dernier
  attaquant, renoncement possible). Utilisé dans la **quiescence** pour ne pas
  chercher les captures **perdantes** (SEE < 0), sauf promotions et évasions sous
  échec — réduit l'arbre et évite les échanges perdants à l'horizon.

### Évaluation
- `e6c1268` — tables **pièce-case (PST)**.
- `997ee3e` — ajout **mobilité, paire de fous, tours (colonnes ouvertes/7ᵉ),
  pions passés** (tous symétriques ⇒ éval de départ = 0).

### Gestion du temps & protocole
- `08cb54f` — lecture de l'horloge (`time`/`otim`) et **allocation par coup**
  (`min(restant/30, 0.5 s)`), attente du premier `go`, profondeur plafonnée.
- (divers) réponse `ping→pong`, `setboard`, `white`/`black` = couleur moteur,
  `usermove`/`move`.

## 5. Dernière session (commit `11f33f9`, 2026-09-09)

Trois chantiers menés sur BB dans la continuité de la section 4, chacun validé par
`./bin_bb/adachess_bb --selftest` (perft 1→5 **inchangé**, éval de départ = 0,
symétrie) et par des mini-matchs cutechess.

### 5.1 Gestion du temps fiabilisée (fin des forfaits sous cutechess)

- Lecture des commandes d'horloge XBoard **`level` / `time` / `otim`** (en plus de
  `st`/`sd` déjà présentes).
- La recherche est déclenchée **dès que le coup adverse est appliqué** (ou sur un
  prompt `go`/`?`), donc toujours avec une horloge à jour (avant, le moteur jouait
  avant de lire le `time` rafraîchi).
- **Recherche interruptible** : une échéance (`Time_Alloc`) est armée dans
  `Best_Move` et **pollée toutes les 1024 nœuds** dans le negamax **et** la
  quiescence (exception `Search_Interrupted`) ; on garde le meilleur coup de la
  dernière itération complète, sinon un coup légal de secours (`Quick_Move`).
- Allocation par coup : `restant/30 + 0,75 × incrément`, plafonnée (≤ 2 s, ≤ restant,
  ≥ 0,01 s) — auto-régulante quand la pendule baisse.
- Résultat : plus aucun forfait à 20+1 (avant : forfaits dès ~8 coups sur ovh02),
  temps/coup bornés (~1,3–1,5 s), blanc et noir.

### 5.2 Évaluation « tapered » + sécurité du roi (toujours symétrique)

Au-dessus du matériel + PST, chaque terme est noté **ouverture/finale** puis
interpolé par une **phase de jeu** (0 finale → 100 ouverture, calculée sur le
matériel restant) :

- **paires de fous** (bonus plus fort en finale) ;
- **mobilité** C/F/T/D ;
- **tours sur la 7ᵉ** (+ bonus si le roi adverse est encore sur les rangées arrière) ;
- **pions passés** : peu en ouverture, décisifs en finale (2 tables) ;
- **sécurité du roi** (bouclier de pions, colonnes ouvertes près du roi, pion-storm,
  attaquants visant la zone du roi) — évaluée en ouverture/milieu seulement ;
- **activité du roi en finale** : le PST de milieu garde le roi au roque, en finale
  une table dédiée le pousse au centre (correction interpolée).

Tout est calculé par couleur et mis en miroir (aucune branche Blanc/Noir dédiée) :
éval de départ = 0 et **test de symétrie** (miroir rangée + couleurs ⇒ `-Eval`)
ajouté au self-test sur 3 FEN.

### 5.3 Recherche : vitesse et profondeur

- **PVS** au root et sur chaque nœud (fenêtre nulle `[α, α+1]` + re-search), au lieu
  de chercher chaque coup racine en fenêtre pleine (le principal trou d'origine).
- **Ordonnancement des coups** : hash move → captures **MVV-LVA** → promotions →
  **killers** (2 par pli) ; quiescence triée MVV.
- **LMR léger** sur les coups tranquilles tardifs (hors échec).
- **Null-move pruning** (profondeur ≥ 3, hors échec / zugzwang) et **reverse
  futility** à profondeur 1.
- **TT portée à 1 M entrées** — l'effacement se fait **en boucle** : l'agrégat
  `(others => <>)` sur la table entière était construit sur la pile (8 Mo) et
  débordait.
- **Zobrist désactivé pendant le movegen** : chaque make/unmake de test de légalité
  recalculait la clé complète (coût majeur supprimé).

Résultats mesurés (startpos, ovh02) : depth 7 ≈ 0,25 s, **depth 10 ≈ 6 s**
(avant cette session : depth 6 ≈ 34 s). BB **bat** sa version précédente (3-0-3 en
1 s+0,1 s, aucune défaite) et **tient/bat MB** en rapide (à 1 s+0,1 s : nuls en
Blanc, gain en Noir ; après intégration du movegen épingles du remote : victoires
2-0).

### 5.4 Chantier 2 : force en recherche (historique, aspiration, extension échec)

Après `1deb991` (SEE), trois leviers du chantier « Force » implémentés dans
`bbchess-search.adb` :

- **Historique** : une table `History` (par couleur, case départ, case arrivée)
  récompense les coups tranquilles qui provoquent des beta-cutoffs (bonus
  `depth²`, plafonné à 850 000) ; les coups tranquilles sont ordonnés par cette
  valeur après les killers. Réinitialisée entre les parties (`Reset_Search` sur
  la commande xboard `new`), persistante au sein d'une partie.
- **Fenêtres d'aspiration** : itération 1 en fenêtre pleine, puis recherche autour
  du score précédent ± 40 cp ; en cas de fail high/low, la profondeur est
  re-cherchée en fenêtre pleine (correct et peu coûteux quand la fenêtre tient).
  `Root_Search` prend désormais une fenêtre `(Alpha, Beta)` et stocke la vraie
  borne (exacte / inférieure / supérieure) dans la TT.
- **Extension en échec** : un nœud où le trait est en échec cherche ses évasions
  un pli de plus (au lieu de basculer directement en quiescence), borné par le
  pli courant pour ne pas exploser sur une longue suite d'échecs. La quiescence
  gère aussi proprement l'échec : **pas de stand-pat** quand le roi est en échec
  (toutes les évasions sont cherchées, les coups tranquilles compris) et
  **mat/stalemate détectés** à l'horizon (auparavant une position d'échec à
  l'horizon pouvait être évaluée statiquement comme si de rien n'était).

Résultats mesurés contre MB (`cutechess-cli`, après rebuild) :
- **1 s+0,1 s** : BB **3-0-3** (aucune défaite ; Elo ≈ +191, LOS ≈ 96 %) —
  cohérent avec le niveau déjà atteint, confirmé sur 6 parties.
- **20+1** : **1-1-2** (gain en Noir, défaite en Blanc, 2 nulles par répétition) —
  plus aucun forfait temps ; BB tient désormais MB à temps long sur cet
  échantillon (à confirmer avec plus de parties).

### 5.5 Chantier 3 : évaluation plus riche et plus rapide

Deux volets menés dans `bbchess-eval.adb`, validés par le self-test (symétrie
conservée : éval de départ = 0, miroir ⇒ `-Eval`) et par mini-matchs.

**Termes d'évaluation ajoutés**
- **Colonnes ouvertes / semi-ouvertes pour les tours** : une tour sans pion ami
  sur sa colonne est récompensée (file totalement ouverte : ~22/16 cp ; file
  semi-ouverte : ~10/6 cp, ouverture/finale). Détection par masque `File_Mask`
  sur les pions des deux couleurs.
- **Structure de pions** :
  * pions **doublés** (pénalité par pion excédentaire sur une colonne) ;
  * pions **isolés** (aucun pion ami sur les colonnes adjacentes) ;
  * **pions passés** : bonus de base par rangée, + bonus s'ils sont
    **protégés** (défendus par un pion ami, ~40-50 % du bonus) ou **éloignés**
    (à ≥ 2 colonnes du roi ennemi, ~10-15 cp, utile pour le dévier en finale) ;
- **Tours connectées** : deux tours qui se défendent (même colonne/traversée,
  ligne libre) : ~10/14 cp.
- **Tempo** (~10 cp au trait, ajouté par `Evaluate`) — comme il brise
  l'antisymétrie exacte de `Evaluate`, le test de symétrie porte désormais sur
  `Static` (le cœur sans tempo) : `Static(départ) = 0`, miroir ⇒ `-Static`.

**Accélération / exploitation bitboard** — une partie 1 s+0,1 s profilée montrait
l'éval à **~50-55 % du temps de recherche** (~1,1 M appels/partie), premier poste
de coût. Corrections :
- `Occupancy` calculée **une seule fois** par `Static` et passée en paramètre à
  `Positional_Score` puis `King_Safety` (auparavant recalculée 1×/couleur puis de
  nouveau dans chaque `King_Safety`).
- Case du roi adverse **hissée** hors de la boucle des tours (elle était
  re-dérivée par `Lowest_Bit` à chaque tour).
- **Pions passés par bitboard** : fonction `Passed_Pawns` par **front-span pur
  bitboard** (propagation des pions ennemis élargis d'une colonne, rangée par
  rangée — helpers `East_1/West_1/North_1/South_1`), sans boucle par-pion.
- **Doublés / isolés** dérivés de comptages `Popcount` par colonne (`File_Mask`),
  sans liste de cases ; un pion passé **protégé** est testé par `Defended_By_Pawn`
  (présence d'un pion ami sur les cases de défense arrière), **éloigné** par la
  distance en colonnes au roi ennemi.
- Tables `Rank_Mask` et `File_Mask` pré-calculées en tête de fichier.

Résultats mesurés contre MB, après les ajouts du chantier 3 complet (colonnes
ouvertes, structure de pions, pions protégés/éloignés, tours connectées, tempo) :
- **blitz 1 s+0,1 s** : BB **5-1-0** (Elo ≈ +280, LOS ≈ 95 %),
- **20+1** : BB **5-0-1** (Elo ≈ +417, LOS ≈ 99 %) — BB domine désormais MB à
  temps long aussi. (Petits échantillons, à confirmer, mais la tendance est très
  nette.)

La **réécriture bitboard de la structure de pions** (§ 5.5) a été validée par un
A/B **référence (git `50c06fb`, version bouclée) vs nouvelle version** : 20 parties
à 1 s+0,1 s, **NEW bat REF 10-3-7** (≈ +127 Elo) — aucun signe de régression et un
léger gain, self-test vert.

## 6. Release bb-1.0 & Phase A (TT persistante + répétitions)

### 6.1 Release `bb-1.0` (référence figée)
- Version exposée : `feature myname="AdaChess-BB 1.0"` ; `CHANGELOG.md` ajouté.
- Tag git annoté **`bb-1.0`** (sur `084e08c`, avant Phase A).
- Binaire de référence installé dans **`~/bin/adachess_bb`** (+ `~/bin` au PATH) :
  c'est la référence des A/B futurs.
- Scripts réutilisables : `scripts/ab.sh` (référence vs HEAD) et
  `scripts/vs_gnuchess.sh` (vs GNU Chess). L'ancien tag `v4.0` correspond à la
  ligne MB d'origine, d'où un nommage `bb-*` pour éviter la confusion.

### 6.2 Phase A — TT persistante entre les coups
La table de transposition n'est **plus vidée à chaque `Best_Move`** : elle est
conservée d'un coup à l'autre de la partie (reset seulement sur `new` via
`Reset_Search`). Les scores de mat étaient déjà encodés en `value_to_tt` /
`value_from_tt` (décalage par le ply à l'écriture, inverse à la lecture), donc
indépendants du root : aucune modification nécessaire. Gain : le moteur réutilise
les nœuds vus plus tôt dans la partie.

### 6.3 Phase A — détection de répétition (3-fold)
- `adachess_bb` tient un **historique des clés Zobrist** de toutes les positions
  de la partie (`Game_Keys`, capacité 512) ; il le transmet à la recherche avant
  chaque réflexion (`Set_Game_History`).
- Dans `Negamax`, le nœud courant est comparé à l'historique de partie **et** au
  chemin de recherche (`Search_Path`, par ply). Si la position est déjà apparue
  **deux fois** (donc la visite courante est la 3ᵉ), le nœud renvoie une nulle.
  Un test dédié vérifie que la recherche reste correcte avec un historique
  répété et que `Reset_Search` remet l'historique à zéro.

Résultats A/B (1 s+0,1 s, 20 parties, graine 7) : **NEW bat REF 8-0-12**
(≈ +147 Elo, LOS ≈ 99,8 %) — pas de régression, gain net. Self-test vert
(perft inchangé + test répétition).

Confirmation à **30 s+1 s, 12 parties** (graine 7) : **REF 1-4-7 NEW**
(NEW ≈ +89 Elo, 0 défaite) — le gain tient à temps long. Contrôle de niveau :
la référence `bb-1.0` contre **GNU Chess** à 30 s+1 s donne **BB 0-9-3**
(3 nulles, GNU ~2500 Elo reste hors de portée), ce qui situe la marge de
progression restante.

**Bug préexistant repéré (corrigé)** : sur un **FEN illégal** où le camp au
trait est « en échec » vis-à-vis du roi adverse (donc le roi adverse est
capturable), le moteur capturait le roi puis `Lowest_Bit` plantait. `Load`
**valide désormais le FEN à l'entrée** : exactement un roi par camp, et le camp
qui n'a pas le trait ne doit pas être en échec (sinon `Constraint_Error`,
signalée par `Error (bad FEN)` côté XBoard). Deux tests dédiés couvrent le cas.

## 7. Instrumentation `post`/`info`

Le moteur gère les commandes XBoard **`post`** / **`nopost`** : quand `post` est
actif, chaque itération complétée du deepening (recherche temporisée) émet une
ligne au format « thinking output » XBoard :

```
depth score time nodes bestmove
```

- `score` en centipawns du point de vue du trait ; les mats sont émis en
  `100000 - plies` (convention comprise par cutechess/XBoard, cf.
  `XboardEngine::adaptScore`) ;
- `time` en centisecondes ; `nodes` = nœuds de l'itération ;
- `bestmove` en notation coordonnée.

Ainsi cutechess enregistre l'évaluation et la profondeur de BB dans le PGN
(`{+0.23/7 0.11s}`), ce qui permet de diagnostiquer la profondeur atteinte et
la qualité des évaluations. Pas de PV complète pour l'instant (seulement le
meilleur coup).

## 7bis. Sécurité du roi renforcée (motif `Bxh7+`)

Diagnostic (via `post` et GNU Chess) : sur le « cadeau grec »
`12.Bxh7+ Kxh7 13.Rxe7 Nxe7`, BB n'évaluait la position qu'à **+30/40** (Blanc)
alors que GNU la voit **+150** — l'attaque sur le roi noir était sous-évaluée,
et BB tombait dans le piège (Noir) ou abandonnait le sacrifice (Blanc).

Améliorations dans `King_Safety` (`bbchess-eval.adb`), générales et symétriques :
- la **case du roi** est incluse dans la zone attaquée (un échec compte) ;
- **zone à distance 2** (« Far », demi-poids) : un attaquant qui peut rejoindre
  l'attaque est compté, ce qui capte l'attaque *potentielle* ;
- danger **non linéaire** : `Near_Danger * (Nb_Attaquants + 1) / 2` (une attaque
  coordonnée pèse plus que la somme) ;
- poids d'attaque relevés (C/F 10, T 16, D 24) ;
- **roi exposé** : pénalité si le roi a quitté sa rangée arrière (`Own_Row > 0`).

Résultats A/B vs `bb-1.0` (1 s+0,1 s) :
- réglage conservateur : neutre (3-3-14) ;
- réglage renforcé (retenu) : **REF 9-18-13 NEW** sur 40 parties
  (NEW ≈ **+80 Elo**, LOS ≈ 96 %) — gain net, self-test et symétrie verts.

Contrôle à **30 s+1 s, 12 parties** (graine 7) : **REF 5-4-3 NEW**
(NEW ≈ −29 Elo, LOS 63 %) — dans le bruit (±187 Elo), donc **non confirmé à
temps long** ; à re-mesurer sur plus de parties. Le gain est net en blitz.

Limite : le motif n'est pas « résolu » au sens où, sans profondeur suffisante,
l'attaque reste en partie invisible statiquement (BB continue de jouer `exd5` à
basse profondeur). L'amélioration est cependant générale et mesure un gain réel
en blitz.

## 7ter. Optimisation des performances (éval + recherche)

Objectif : maximiser les nœuds/seconde pour gagner de la profondeur effective.
Mesure via un harnais dédié `--bench [profondeur]` : 8 positions fixes
(début, ouvertures, milieu, finale) cherchées à profondeur fixe, sortie
`nœuds / temps / knps`. À profondeur 9, on est passé de **~470 knps** à
**~2400 knps** (≈ **×5,2**), à compteurs de nœuds **identiques** (aucun
changement de comportement de recherche).

Gains, par ordre d'implémentation :
1. **Intrinsèques bits** : shim C `bbchess-bits.c` (`__builtin_popcountll`,
   `__builtin_ctzll`) importée en Ada ; `Lowest_Bit`/`Popcount` ne sont plus des
   boucles logicielles. Compilation `-mpopcnt -mbmi`. `pragma Inline` sur les
   helpers chauds + `-gnatN`. → ×3,8 à lui seul.
2. **Zobrist incrémental** : `Make_Move` met `Position.Key` à jour par XOR
   (pièce/capture/roque/droits/ep/côté) au lieu de `Hash.Compute` (parcours
   complet). Test croisé en self-test : clé incrémentale = `Compute`.
3. **Recherche** : quiescence en **génération tactique seule** (hors échec) ;
   `Is_Repetition` limité à la fenêtre réversible `Halfmove` (au lieu de 512) ;
   statut d'échec renvoyé par la movegen (évite un second test).
4. **Éval** : table plate `Material_PST(Piece, Square)` et zones Near/Far du roi
   précalculées.
5. **Occupancy/color boards incrémentales** (`All_Occ`, `Color_Occ` mis à jour
   dans `Put/Remove_Piece`) et détection de capture O(1) dans `Make_Move`.
6. **`Pin_Mask`** par rayons/between (bitboards) au lieu d'un balayage case par
   case. → ~+12 %.

Pièges : un build `-pg`/gprof laisse des objets instrumentés ; gprbuild ne les
recompile pas toujours au retour à la normale → **toujours `rm -rf obj_bb`**
après un profil, sinon les mesures sont faussées d'un facteur ~3.

## 8. État actuel & chantiers restants

**Validations** : `./bin_bb/adachess_bb --selftest` passe (perft + roque + éval +
recherche + **SEE** + répétition). Self-tests et perft ne doivent **jamais
régresser**. Note : avec le **tempo**, `Evaluate` n'est plus exactement
antisymétrique ; le test de symétrie porte sur `Static` (départ = 0, miroir ⇒
`-Static`).

**Adversaire de référence des mini-matchs** : **GNU Chess** (`/usr/games/gnuchess`,
moteur **UCI** ~2400-2500 Elo, bien plus fort que MB). Se joue via un wrapper car
cutechess ne passe pas d'arguments dans `cmd` :
```bash
#!/bin/bash
exec /usr/games/gnuchess -u "$@"
```
puis `cutechess-cli -engine name=GNU cmd=/tmp/opencode/gnuchess_uci.sh proto=uci
dir=/tmp -engine name=BB cmd="$PWD/bin_bb/adachess_bb" proto=xboard dir="$PWD" ...`
(le mode xboard de GNU Chess 6.2.7 est incomplet : il n'émet jamais
`feature done=1`, d'où l'usage d'UCI).

**Problèmes / chantiers restants (après les chantiers 2, 3 et la Phase A)**
1. **Temps** : les forfaits sous cutechess sont corrigés (recherche interruptible) et
   BB tient MB à 20+1 sur un petit échantillon. Reste à **confirmer sur plus de
   parties longues** et à **tuner l'allocation** si besoin (constantes en tête
   d'`adachess_bb.adb`).
2. **Force** : l'historique, les fenêtres d'aspiration et l'extension en échec sont en
   place (BB bat MB en blitz, domine à 20+1). Pistes restantes : movegen « légal
   direct » complet, **book d'ouvertures**, et l'usage du **SEE** pour trier plus
   finement la quiescence et les captures.
3. **Évaluation** : le chantier 3 est complet (§ 5.5) — colonnes ouvertes, structure
   de pions (doublés/isolés/passés protégés et éloignés) en **pur bitboard**, tours
   connectées, tempo. Reste un **tuning fin des constantes** (tête de
   `bbchess-eval.adb`) qui demanderait un tuner automatique (ex. texel / gradient
   descent), des **outposts** (cases fortes) pour C/F, puis l'évaluation
   **incrémentale** (#9). L'éval reste le premier poste de temps (~14 % de
   `positional_score` au profil), la mobilité en tête.

**Commandes utiles (Linux/ovh02)**
```bash
gprbuild -P adachess.gpr   -XMode=release    # MB
gprbuild -P adachess_bb.gpr -XMode=release   # BB
./bin_bb/adachess_bb --selftest              # tests BB
./bin_bb/adachess_bb --bench 9               # perf : 8 positions, profondeur 9 (knps)
# A/B référence (~/bin/adachess_bb, tag bb-1.0) vs HEAD :
scripts/ab.sh 1+0.1 20 7                     # tc, parties, graine
# Match vs GNU Chess (UCI, wrapper requis) :
scripts/vs_gnuchess.sh 30+1 12 7             # tc, parties, graine
```

**Règle d'or pour la suite** : toute modification (éval, search, movegen) doit garder
les perft/self-tests verts, et toute nouvelle évaluation doit rester **symétrique**
(éval de la position initiale = 0).
