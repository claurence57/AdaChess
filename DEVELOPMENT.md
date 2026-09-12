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
**~2550 knps** (≈ **×5,5**), à compteurs de nœuds **identiques** (aucun
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
7. **Évaluation incrémentale** : matériel + PST maintenus dans
   `Position.Material` (initialisés par `Load`/`Start_Position`, mis à jour par
   `Make_Move`/`Unmake_Move`) ; `Static` ne parcourt plus le plateau. Test croisé
   en self-test (clé Zobrist **et** matériel = recompute). → ~+4 %.

Note : un **hash de pions** (clé pions+rois, `Pawn_Key` incrémental) a été
implémenté puis retiré : il n'apporte rien, la structure de pions étant déjà
bon marché une fois `Popcount` en instruction matérielle.

Pièges : un build `-pg`/gprof laisse des objets instrumentés ; gprbuild ne les
recompile pas toujours au retour à la normale → **toujours `rm -rf obj_bb`**
après un profil, sinon les mesures sont faussées d'un facteur ~3.

## 7quater. Movegen légal direct & table de transposition (chantiers M1/M2)

**M1 — Génération de coups** (`bbchess-movegen.adb`, `bbchess-attacks.adb`) :
- tables `Between[64][64]` et `Line[64][64]` (élaboration), `File_A_BB`/`File_H_BB` ;
- `Pin_Mask` réécrit via `Between` ;
- **génération groupée des pions** par shifts (poussées, doubles, captures,
  promotions) au lieu d'une boucle par pion ;
- **légalité directe** : `Checkers` (masque d'échec), masque de résolution
  (capture du donneur ∪ interposition), restriction des pièces clouées à
  `Line[roi][pièce]`, sécurité du roi via `Is_Attacked` avec la case du roi
  retirée de l'occupancy. **Plus aucun make/unmake** dans la movegen, sauf
  l'en-passant (cas rare, testé par make/unmake pour rester correct).

**M2 — TT** (`bbchess-moves.adb`, `bbchess-search.adb`) :
- coups encodés en **32 bits** (`Pack_Move`/`Unpack_Move`) pour le stockage TT ;
- **TT à 2 voies** (bucket = index pair) avec **aging** par génération de
  recherche et remplacement *depth-preferred*.

**Résultat** : `--bench 9` ≈ **2,8 M knps** (contre ~2,55 M avant M1), self-tests
verts (perft exact, dont KiwiPete d1-d3, tests `Between`/`Line`, round-trip du
packing). A/B vs `bb-1.0` : **REF 1-11-8 NEW** (M2), aucune régression.

## 7quinquies. Protocole UCI

Le moteur parle désormais **UCI** en plus de XBoard (`adachess_bb.adb`). La
détection se fait par la commande `uci` ; `UCI_Mode` garde les commandes UCI
spécifiques (`isready`, `ucinewgame`, `position`, `go`, `stop`, `setoption`)
séparées de XBoard (attention : `go` existe dans les deux protocoles).

Commandes prises en charge : `uci`, `isready`, `ucinewgame`, `position
startpos|fen ... moves ...`, `go wtime/btime/winc/binc/movetime/depth`,
`setoption name Clear Hash`, `stop`/`ponderhit` (no-op), `quit`. Sortie
`bestmove <coord>`. Les coups sont déjà en notation coordonnée
(`e2e4`, `e7e8q`), donc `To_String`/`From_String` servent directement.

Limite : la recherche est synchrone, donc `stop` n'interrompt pas un `go`
en cours (pas encore de thread de recherche) ; `go infinite` n'est pas géré.

**Correctif important** : le buffer d'entrée est passé de 256 à 8192 octets.
Les longues lignes `position ... moves ...` (parties > ~50 coups) étaient
**coupées** par `Get_Line`, ce qui désynchronisait la position et produisait des
coups illégaux.

## 7sexies. Tuner d'évaluation automatique

Les constantes scalaires de l'évaluation sont regroupées dans un tableau
`Params` (`bbchess-eval.adb`) ; les constantes nommées sont des `renames`, donc
le reste de l'éval est inchangé. Interface exposée : `Set_Param`,
`Load_Params`, `Dump_Params`. Modes de ligne de commande :
- `--dump-params` : affiche `Nom Valeur` (une par ligne) ;
- `--eval-fens <fichier>` : lit des positions (`FEN` ou `FEN;résultat`) et sort
  l'éval statique blanche, une par ligne ;
- `--params <fichier>` : charge des paramètres avant tout mode.

Outillage (`scripts/`) :
- `gen_dataset.py` : convertit des PGN en `FEN;résultat` (résultat du point de
  vue blanc, échantillonnage tous les 4 coups, après l'ouverture) via
  `python-chess` ;
- `tune.py` : descente de coordonnées type **Texel** (minimise l'écart
  `sigmoid(K·eval/400)` vs résultat, `K = 1.13`), en pilotant le moteur par
  `--eval-fens`/`--params`. Un jeu de validation (1 position sur 5) filtre les
  changements : un candidat n'est retenu que s'il améliore **train ET
  validation**.

**Résultat de l'expérience (négatif)** : sur un dataset de 240 parties
d'auto-jeu à ouvertures aléatoires (5 801 positions), la descente fait baisser
l'objectif (train 0,1025 → 0,0950 ; validation 0,1033 → 0,0951) mais les
paramètres obtenus **régressent en parties réelles** (~−147 Elo en A/B contre
les défauts). En ne gardant que les paramètres positionnels (matériel aux
défauts), l'effet est ~neutre. Conclusion : à cette échelle, minimiser l'erreur
d'éval sur des parties d'auto-jeu ne corrèle pas avec la force de jeu ; il
faudrait un dataset bien plus grand/divers (ou une recherche de paramètres
validée par SPRT). **Les valeurs par défaut sont conservées.**

## 7septies. Lazy SMP & attaques PEXT

**Lazy SMP** (`bbchess-search.adb`) : la TT est **partagée** entre les threads,
tandis que l'état de recherche (killers, historique, chemin de répétition,
compteur de nœuds, échéance) vit dans un `Search_Context` **par thread**. Les
threads sont des tâches Ada ; le thread primaire (1) produit et rapporte le
résultat, les autres remplissent la TT. Le drapeau d'arrêt est `pragma Atomic`.
Activation : `--threads N` ou UCI `setoption name Threads value N` (max 16).
- Mesure : à 1 s+0,1 s, **1 thread 2-9-9 4 threads** (SMP ≈ **+127 Elo**) ;
  occupation CPU 99 % → 759 % selon N, temps respecté (budget identique).
- La génération de coups ne touche plus au drapeau global `Keys_Enabled`
  (clé toujours maintenue pendant la recherche) : c'était nécessaire pour le
  SMP (le drapeau global aurait été une course entre threads).

**Attaques par PEXT** (`bbchess-attacks.adb`, `bbchess-bits.c`) : les magics
sont remplacés par un indexage `_pext_u64` (BMI2) sur le masque d'occupation.
Plus de recherche de magics au démarrage : le **démarrage passe de ~1,9 s à
~0,03 s** (et le self-test de ~2,4 s à ~0,27 s). Compilation `-mbmi2`.

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
# BB en UCI sous cutechess (le moteur parle aussi XBoard) :
cutechess-cli -engine name=BB cmd="$PWD/bin_bb/adachess_bb" proto=uci \
  -engine name=GNU cmd=/home/christophe/bin/gnuchess_uci.sh proto=uci \
  -each tc=5+0.5 -games 2
```

**Règle d'or pour la suite** : toute modification (éval, search, movegen) doit garder
les perft/self-tests verts, et toute nouvelle évaluation doit rester **symétrique**
(éval de la position initiale = 0).

---

## 9. Phase 0/1 — correctifs de recherche et élagage moderne

Objectif : réduire l'écart avec GNU Chess (~2400-2500 Elo), qui battait BB
**0-8-2** en blitz 1 s+0,1 s (≈ -382 Elo). Deux étapes menées dans
`bbchess-search.adb`, validées par `--selftest` (perft 1→5 inchangé) et par A/B
`cutechess-cli`.

### 9.1 Phase 0 — correction de la recherche
- **LMR** : un fail-high de la recherche réduite (y compris un beta cutoff) est
  désormais **re-vérifié à profondeur pleine** ; auparavant la borne réduite
  pouvait être acceptée telle quelle.
- **History** : bonus quadratique `depth²` (au lieu de `min(depth², 64)`, quasi
  inerte) plafonné, et **malus** des coups calmes qui n'améliorent pas alpha.
- **Nulles terminales** : règle des 50 coups, matériel insuffisant (KvK,
  K+pièce mineure vs K, fous de même couleur — garde `All_Occ ≤ 4` pour rester
  quasi gratuit), et répétition comptée comme nulle dès la 2ᵉ occurrence dans la
  ligne de recherche (3-fold conservé pour l'historique de partie).
- **Mate-distance pruning**.

Bilan : neutre en A/B (10-9-21, ≈ ±9 Elo non significatif) mais supprime des
erreurs de recherche réelles ; prérequis pour la suite.

### 9.2 Phase 1 — élagage
- **LMR log** : `R = 0,75 + ln(depth)·ln(move)/2,25` (table précalculée à
  l'élaboration), avec PVS correct : fenêtre nulle réduite, puis re-recherche
  pleine sur fail-high, puis re-recherche pleine fenêtre si le score retombe
  dans la fenêtre.
- **Late move pruning** (depth ≤ 3, coups calmes tardifs), **futility pruning**
  des coups calmes (depth ≤ 2), **razoring** (depth ≤ 2, résolu par
  quiescence), **delta pruning** en quiescence (capture dont la victime + marge
  n'atteint pas alpha).

Bilan mesuré (blitz 1 s+0,1 s) :
- arbre de recherche ÷ ~11 à profondeur 9 (7,6 M → 0,67 M nœuds) ;
- A/B self-play vs version d'origine : ≈ **+61 Elo** (LOS 94 %) ;
- vs GNU Chess : **1-13-6** (≈ -241 Elo) contre 0-8-2 (≈ -382) avant, soit
  ≈ **+140 Elo** — l'écart se resserre mais GNU reste devant.

### 9.3 Phase 2 (ordonnancement) — essayée puis revertée

Tentative d'un lot « ordonnancement » : history **persistante entre les coups**
(table au niveau paquetage, partagée entre threads), **countermove** (chemin de
coups `Move_Path` + table `Counter_Move`), et tri **SEE** des captures (bonnes
captures avant, captures perdantes après les coups calmes).

Résultats :
- self-play entre versions voisines non concluant : trois A/B (Phase 1 vs
  Phase 2 avec SEE, avec SEE vs sans SEE, Phase 1 vs Phase 2 sans SEE) donnaient
  des signes contradictoires, tous dans ±65 Elo (≈ 47 % de nulles) ;
- **gauntlet contre GNU Chess** (mêmes conditions pour les deux versions,
  tc 1 s+0,1 s) : Phase 1 **8/30**, Phase 2 **2/30** — régression nette ;
- le tri SEE coûtait en outre ~13 % de knps pour un arbre légèrement plus gros.

Décision : **tout le lot est annulé**, retour à l'état Phase 1 (bench
668 081 nœuds, identique). Enseignement méthodologique : à cette cadence, le
self-play entre versions voisines est trop bruité ; c'est le **match contre GNU**
qui doit trancher, avec si possible un gauntlet et plusieurs centaines de parties.

### 9.4 Phase 4a — terme d'évaluation « threats »

Ajout dans `bbchess-eval.adb` d'un terme de menaces, calculé par couleur dans
`Positional_Score` (donc symétrique par construction) :
- **menaces de pions** : chaque pièce ennemie (hors pion) attaquée par un pion
  ami rapporte `P_Threat_Pawn × valeur_pièce / 100` ;
- **menaces de pièces mineures** : un cavalier/fou attaquant une tour ou une
  dame ennemie rapporte `P_Threat_Minor × valeur_pièce / 100`.

Deux paramètres ajoutés au tableau `Params` (tunables via `--params`). Le
`--selftest` reste vert (symétrie de `Static`, départ = 0) ; l'arbre de `--bench 9`
passe de 668 k à 802 k nœuds (le terme change les choix, sans surcoût notable).

Mesure : gauntlet vs GNU (30 parties) Phase 1 ≈ 1,5/30, Phase 4a ≈ 3,5/30 —
léger mieux mais **dans le bruit**. Limite méthodologique importante : la
recherche est temporisée et donc non déterministe, ce qui rend les petites
différences inmesurables sur 20-30 parties ; il faudrait un vrai SPRT sur
plusieurs centaines de parties pour trancher.

Prochaines étapes : Phase 4b (singular extensions, ProbCut, SPSA), puis Syzygy
et l'usage du book dans les tests.

---

## 10. Livre d'ouvertures Polyglot

Objectif : supprimer l'ouverture faible de BB (`1.Nc3` récurrent) en utilisant
un book standard.

- **Module `BBChess.Polyglot`** : clé Zobrist Polyglot (table de 781 constantes
  embarquée, générée depuis `python-chess`) — placement des pièces (encodage
  Polyglot : **noir en premier**), droits de roque, en passant **conditionnel**
  (seulement si un pion du trait peut capturer), trait. Lecture d'un `.bin`
  (16 octets/entrée, big-endian, trié par clé) et probe : recherche binaire,
  choix pondéré par le poids, décodage du coup et **vérification de légalité**.
- **Intégration driver** : probe avant la recherche dans `Play_If_My_Turn`
  (XBoard) et `Handle_UCI_Go` (UCI) ; limite **16 plies** ; `--book <fichier>`
  et recherche par défaut (`books/book.bin`, répertoire de l'exécutable et son
  parent, `~/.adachess/book.bin`) ; options UCI `OwnBook`/`BookFile` ;
  désactivé pour les modes `--selftest`/`--bench`/`--eval-fens`.
- **Source des données** : books **CC0** générés par `jja`
  (https://www.chesswob.org/jja/books/), téléchargés par
  `scripts/fetch_book.sh` (défaut `gm2600`, ~12 Mo / 750 k entrées). Le `.bin`
  n'est pas commité (`books/` gitignoré).
- **Validation** : cross-check de `Polyglot_Key` contre `python-chess` ajouté au
  `--selftest` (startpos, roque, en passant capturable et non capturable,
  milieu de partie). `--bench 9` inchangé (book non chargé dans ces modes).
- **Mesure** (gauntlet vs GNU, 30 parties par config) : avec book ≈ -352 Elo,
  sans book ≈ -382 — léger mieux (+30), non significatif à cet échantillon.
  Effet visible : `1.Nc3` disparaît (e4/d4/Nf3/c4) et les réponses en Noir
  suivent le book (c5, e5, d5, Nc6, Nf6).

Piège rencontré : le buffer complet du book (12 Mo) alloué en local dans
`Open_Book` provoquait un `STORAGE_ERROR` (pile) → lecture par entrée de 16
octets. Autre piège : l'encodage Polyglot met **noir en premier** (index pair =
pièce noire) ; l'inverser donnait une clé fausse (détecté par le cross-check).

Prochaines étapes : Phase 4b (singular extensions, ProbCut, SPSA), Syzygy, et
mesurer le book sur un plus gros échantillon / une suite d'ouvertures.

---

## 11. Développement assisté par IA

Les évolutions décrites aux **sections 9 et 10** (Phase 0/1 de la recherche,
terme d'évaluation `threats`, et livre d'ouvertures Polyglot) ont été développées
avec l'assistance d'un agent IA :

- **Agent** : *Sisyphus* — projet **OhMyOpenCode** ;
- **Modèle** : `deepseek/deepseek-v4-flash` ;
- **Environnement** : **OpenCode**.

Méthode : l'humain fixe l'objectif et tranche les choix structurants (format du
book, source des données, priorités) ; l'agent implémente, compile, exécute les
self-tests et les matchs `cutechess-cli`, puis documente. Chaque étape est
validée par `--selftest` (perft inchangé) et par des matchs. Les expériences
négatives (Phase 2 d'ordonnancement, tuning Texel) sont **conservées** dans ce
document plutôt que masquées, et les mesures sont données avec leur incertitude
(échantillons bruités — voir §9.3).

---

## 12. Optimisation de l'évaluation (prompt `/tmp/kk`)

Tentative d'optimisation CPU de `BBChess.Eval.Static` (sans changer les scores),
à partir d'un prompt d'implémentation. Étapes 0 à 3 exécutées.

**Profilage (étape 0).** `perf` indisponible (`perf_event_paranoid = 4`) ;
repli `gprof` via un build `release` + `-pg` (distordu : 2,6 s contre 0,56 s au
`--bench 9`, donc ×4,7). Postes : `positional_score` ≈ **20 %** (appelé 1,07 M
fois = 2×/`Static`), `order` ≈ 10 %, `popcount` ≈ 10 %, attaques ≈ 12 %. Le
`-pg` surestime les petites fonctions appelées des millions de fois.

**B1 — `Defended_By_Pawn` en un lookup (conservé).** Remplacé par
`(Pawn_Attacks (Opposite (Color), Square) and Position.Pieces (Make (Color,
Pawn))) /= 0` (relation d'attaque inverse). Sémantique identique (nœuds du bench
inchangés), ~30 lignes en moins.

**B3 — phase incrémentale (revertée).** Implémentée (champ `Phase` dans
`Position`/`Undo`, maintenu par Make/Unmake, cross-check self-test
`Phase = Game_Phase`), mais **gain non mesurable** : bench 11 interleavé,
médianes 1,80 s (avant) vs 1,81 s (après), dans le bruit. En build optimisé,
les 8 `Popcount` de `Game_Phase` sont des instructions uniques (~4 M cycles sur
~1,8 G, soit ~0,2 %) ; le champ ajouté alourdit les copies de `Position`. Le
profil `-pg` avait surévalué ce poste. **Tout est reverté.**

**B6 — `pragma Inline` sur les helpers chauds (conservé).** `Both`, `"+"`,
`Blend`, `PST`, `Piece_Value`, `Own_Row`, `Defended_By_Pawn`. `-gnatN` n'inline
que les sous-programmes marqués `pragma Inline` : sans marquage il ne servait à
rien pour l'éval. Piège : marquer `Piece_Attacks` casse la compilation (son
`case` inliné dépasse le sous-type `Knight .. Bishop` du terme `threats`) →
pragma retiré. Effet mesuré : neutre, conservé car sans coût.

**Écarté / non fait** : B2 (miroir `Front_Blockers` — `Front_Blockers` n'est que
7 shifts, miroir non évidemment plus rapide), B4 (fusion des deux
`Positional_Score` — refactor lourd, gain incertain), B5 (pions en un passage —
marginal), C1 (table d'attaques roi — invasif). A1 (flags `-gnatN` off + LTO)
non tenté : retirer `-gnatN` contredit le ×3,8 mesuré en §7ter.

**Conclusion** : aucune optimisation d'éval du prompt n'apporte de gain
mesurable ; le levier reste la **qualité de recherche** (Phase 4b : singular,
ProbCut, SPSA ; puis Syzygy).

---

## 13. Singular extensions

Implémenté dans `bbchess-search.adb` : quand le coup de la table de
transposition est nettement meilleur que toutes les alternatives, il est
cherché un ply plus profond.

- `Negamax` prend un paramètre `Excluded` (défaut `Empty_Move`). Le probe
  singulier recherche la **même position** à profondeur `(Depth-1)/2` avec le
  coup de référence **exclu** ; `Excluded` désactive aussi le cutoff et le store
  de la TT (pour ne pas polluer la table avec un score calculé sans ce coup), et
  le coup exclu est sauté dans la boucle de coups.
- Conditions : `Depth ≥ 8`, hors échec, coup TT présent, score TT fiable
  (`TT_Depth ≥ Depth-3`, borne ≠ supérieure). Si le meilleur autre coup est
  `< TT_Score − 2·Depth`, le coup est singulier → extension de **+1 ply**.
- Coût mesuré : `--bench 11` 2,62 M → **2,95 M nœuds (+12,5 %)**, temps +17 %.
  `--selftest` vert.
- A/B self-play (60 parties, 1 s+0,1 s) : **neutre** (PRE +5,8 ± 67,9 Elo,
  LOS 57 %). Conservé (technique standard, demandée) mais **gain non démontré**
  à cette cadence — à re-mesurer en SPRT sur plusieurs centaines de parties.

Prochaine étape : Syzygy.

---

## 14. Tablebases Syzygy

Probe de fin de partie via **Fathom** (bibliothèque C, licence **MIT**),
vendue dans `src_bb/fathom/` (`tbprobe.c`, `tbchess.inc` inclus par
`tbprobe.c`, `tbconfig.h`, `stdendian.h`, plus le wrapper aplati
`bbchess-tbwrap.c`). Le wrapper expose `bb_tb_init`, `bb_tb_largest`,
`bb_tb_wdl` au binding Ada `BBChess.Syzygy`.

- **Binding** (`bbchess-syzygy.ads/.adb`) : `Init (chemin)`, `Largest`,
  `Probe_WDL` (convertit la `Position` en bitboards Fathom). Le probe WDL est
  refusé s'il subsiste des **droits de roque** ; le halfmove est **ignoré** (le
  WDL suppose `rule50 = 0` — le DTZ serait nécessaire pour respecter la règle
  des 50 coups).
- **Recherche** : dans `Negamax`, si des tables couvrent le matériel
  (`Popcount (All_Occ) ≤ Largest`), le WDL exact est renvoyé : gain →
  `TB_Win − Ply`, perte → `−(TB_Win − Ply)`, nulle/blessed/cursed → 0.
  L'itération s'arrête dès qu'un score TB est atteint.
- **Driver** : `--syzygy <dossier>` (modes de jeu) et UCI
  `setoption name SyzygyPath value <dossier>`.
- **Validation** : `--selftest` vert ; avec les tables 3-pièces
  (KQvK/KRvK/KPvK, miroir `sesse.net`), un KQvK blanc renvoie **19999** dès la
  profondeur 2 et s'arrête. Sans tables, l'intégration est **inerte**
  (`Largest = 0`, aucun surcoût au bench).
- **Limite** : pas de probe **DTZ** au root → dans une finale gagnée, le moteur
  peut « tourner » sans progresser (nulle par la règle des 50 coups). À ajouter.

Piège de build : `tbchess.c` est destiné à être **inclus** par `tbprobe.c`
(unity build), pas compilé seul → renommé `tbchess.inc` (sinon gprbuild le
compile séparément et échoue).

Licence : Fathom est **MIT** (compatible GPLv3), voir `src_bb/fathom/LICENSE`.

---

## 15. Protocole SPRT (validation A/B)

Objectif : sortir du bruit des matchs à taille fixe. Jusqu'ici les A/B de
20-60 parties donnaient des écarts contradictoires (±65-80 Elo) : aucun des
changements récents (threats, livre, singular extensions) n'a pu être validé
proprement, et la Phase 2 a été acceptée puis revertée sur des mesures
incohérentes (cf. §9.3). Le SPRT remplace « je joue N parties puis je regarde
l'intervalle » par une **procédure séquentielle** qui décide après chaque partie.

### 15.1 Le modèle

Le **Sequential Probability Ratio Test** (Wald, 1945) teste deux hypothèses sur
l'écart d'Elo réel entre deux binaires :

- **H0** : NEW n'est pas meilleur que OLD de plus que `elo0` → le patch échoue ;
- **H1** : NEW est meilleur que OLD d'au moins `elo1` → le patch passe.

Après chaque partie on met à jour le **log-rapport de vraisemblance (LLR)** entre
les deux hypothèses (modèle logistique gain/nulle/perte ; `cutechess-cli` utilise
le modèle « pentanomial » par paires de couleurs). On le compare à deux bornes :

- borne haute `A = ln((1-β)/α)` ;
- borne basse `B = ln(β/(1-α))`.

Décisions : `LLR ≥ A` → H1 acceptée (**PASS**) ; `LLR ≤ B` → H0 acceptée
(**FAIL**) ; sinon on continue. Avec α = β = 0,05 : A ≈ **+2,944** et
B ≈ **−2,944**. Le test s'arrête tôt pour un patch nettement bon ou mauvais, et
ne joue beaucoup que si l'écart réel tombe entre les bornes. Les probabilités
d'erreur de type I/II hors de `[elo0, elo1]` sont bornées par α et β.

À ne pas confondre avec le **LOS** affiché par `cutechess-cli` : le LOS est la
probabilité que NEW > OLD **sans seuil d'effet** (un +1 Elo peut avoir LOS 60 %),
le SPRT teste un **effet minimal** et rend un verdict PASS/FAIL.

### 15.2 Implémentation

- **`scripts/sprt.sh`** — harnais : deux binaires (OLD/NEW), cadence, bornes
  `elo0`/`elo1`, α/β, plafond de parties, graine. Il lance `cutechess-cli -sprt`,
  lit la dernière ligne `SPRT:` du log et imprime un verdict
  `PASS` / `FAIL` / `INCONCLUSIVE` (codes de sortie 0 / 1 / 2).
- **`openings/openings.epd`** — 65 ouvertures équilibrées (4-6 plis), générées
  par **`scripts/gen_openings.py`** (liste SAN validée par `python-chess`).
  Chaque position est jouée **deux fois, couleurs inversées** (`-repeat`) :
  supprime le biais de couleur et décorrèle les parties (hypothèse i.i.d.).
- **Contrainte de comptage** : pour deux moteurs, `cutechess` joue
  `rounds × games` parties ; le script fixe `-games 2 -rounds max_games/2`
  pour jouer chaque ouverture dans les deux couleurs.

```
scripts/sprt.sh [tc] [elo0] [elo1] [max_games] [seed] [old] [new]
# défauts : 1+0.1  0  5  2000  7  ~/bin/adachess_bb  bin_bb/adachess_bb
```

Pour valider un **patch**, passer le binaire **d'avant** en OLD :

```
scripts/sprt.sh 1+0.1 0 5 2000 7 /tmp/opencode/adachess_bb_p1 bin_bb/adachess_bb
```

(Comparer directement à la référence `bb-1.0` donne un PASS immédiat : l'écart
est d'environ +300 Elo.)

### 15.3 Bonnes pratiques

- `--selftest` vert et perft inchangé **avant** tout match.
- Suite d'ouvertures variée obligatoire : sans elle, les parties se ressemblent
  et l'hypothèse d'indépendance est violée. Le self-play entre versions voisines
  (~50 % de nulles) reste le cas le plus bruité.
- Un FAIL est une information, pas un échec : un patch neutre (±2 Elo) est
  rejeté vite ; un patch borderline fait jouer longtemps avant de trancher.
- Si le non-déterminisme de la recherche temporisée gêne, valider d'abord en
  profondeur/nœuds fixes, puis confirmer en cadence réelle.
- Conserver les PGN (chemin imprimé en fin de script) pour inspecter les parties.
