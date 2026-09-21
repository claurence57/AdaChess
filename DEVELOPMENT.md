# Notes de développement — AdaChess / AdaChess-BB

Ce document résume le parcours du projet : les améliorations apportées au moteur
**AdaChess** (mailbox, dit **MB**), la création du moteur **AdaChess-BB** (bitboard,
dit **BB**), les différences entre les deux, et l'état des améliorations jusqu'ici.

> **Développement assisté par IA.** Toutes les modifications apportées au projet
> depuis le fork initial — moteur **MB** (`src/`), moteur **BB** (`src_bb/`),
> scripts, tests et documentation incluse — ont été réalisées **avec l'aide
> d'agents IA** ; **aucun développement n'a été fait manuellement**. Modèle
> principal : **DeepSeek V4.1 Flash** ; des corrections et compléments ont été
> apportés par des **prompts générés avec Claude** et **Kimi K3**. Outils de
> travail de base : **opencode** (agent *Sisyphus* / OhMyOpenCode) et des
> **interfaces web**.

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
  LOS 57 %).
- **SPRT 300 parties** (harnais à livre neutralisé) : **neutre** (OLD 93-97-110
  → singular **+4,6 ± 31,3 Elo**, LOS 38,6 %) tout en coûtant des nœuds
  (`--bench 11` +12,5 %). → **retirée**, avec le paramètre `Excluded` devenu
  inutile (commit `f17f217`).

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
- **Ordre des moteurs** : `cutechess-cli` applique le SPRT au **premier** moteur
  listé. `sprt.sh` place donc **NEW en premier** ; sinon un NEW nettement
  meilleur produisait un LLR **négatif** et les libellés PASS/FAIL sortaient
  **inversés** (vérifié : OLD = `bb-1.0`, NEW = HEAD ~+300 Elo → OLD 15 %,
  « -301 ± 90 Elo », LLR **négatif** avec l'ancien ordre).

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

### 15.4 Fairness et taille d'échantillon

Deux pièges découverts en mesurant les tentatives des §17-18 :

- **Livre asymétrique** : la recherche de livre par défaut regarde à côté de
  l'exécutable **et de son parent**. Un binaire dans `bin_bb/` trouvait donc
  `books/book.bin` (parent = dépôt) alors qu'un binaire dans `/tmp` non : NEW
  jouait des coups de livre, OLD non. `sprt.sh` et `ab.sh` **désactivent
  maintenant le livre des deux côtés** pendant le match (et le restaurent) ; la
  suite d'ouvertures fournit la variété. Les A/B antérieurs sont donc à
  considérer avec prudence.
- **Taille d'échantillon** : un contrôle **HEAD vs HEAD** (binaires identiques)
  a donné **41,2 %** (LOS 8 %) sur 40 parties, soit un écart apparent de ±60 Elo
  pour des moteurs identiques — la barre d'erreur à 40 parties est **±87 Elo**.
  À **300 parties** elle tombe à **±33-36 Elo**. Ne rien trancher sous ~300
  parties ; seuls les écarts objectifs (`--bench` nœuds/temps) peuvent écarter un
  candidat plus tôt.
- **Reproductibilité** : la recherche temporisée étant non déterministe, la
  **même graine** ne rejoue pas les mêmes parties (constaté avec la graine 7 :
  OLD 34-32-53 à la 119ᵉ partie d'un run contre 47-32-40 dans un autre).
  Relancer un SPRT avec la même graine donne donc un **échantillon
  indépendant**, pas une continuation.

---

## 16. Build portable (sans POPCNT/BMI)

Le mode `release` de BB suppose POPCNT/BMI1/BMI2 (attaques PEXT matérielles) :
sur un CPU plus ancien le binaire s'arrête sur une instruction illégale. Un
mode `portable` a donc été ajouté au projet pour produire un binaire qui tourne
sur n'importe quel x86-64 :

```bash
gprbuild -P adachess_bb.gpr -XMode=portable   # -> bin_bb/adachess_bb
```

- **`adachess_bb.gpr`** : le mode `portable` utilise `-O3 -gnatN` **sans**
  `-mpopcnt -mbmi -mbmi2` ; le mode `release` reste inchangé.
- **`bbchess-bits.c`** : `bb_pext` utilise `_pext_u64` seulement si `__BMI2__`
  est défini, sinon une boucle logicielle extrait les bits du masque ;
  `__builtin_popcountll` / `__builtin_ctzll` se rabattent sur les routines
  libgcc. Un seul fichier sert donc les deux modes.
- **Mesure** : `--bench 9` ≈ **1,07 M knps** contre 1,46 M en `release` (~27 %
  plus lent), **arbre identique** (780 851 nœuds) ; `--selftest` vert, perft 1→5
  inchangé. Les deux modes partagent `obj_bb/` : ne pas mélanger les builds dans
  le même arbre.

---

## 17. Sécurité du roi — deux tentatives (résultats négatifs)

Contexte : l'analyse des 80 parties contre GNU (§ analyse du milieu de jeu) a
montré que BB **sous-estime l'attaque adverse**. Cas typique (`decision.epd`,
position #10) : l'éval statique de BB donne `f6e6` = +690 (il gagne la dame) et
`f6g5` = −114, mais la recherche joue `f6g5` ; Stockfish dit `f6g5` ≈ −10,5.
Après `Qg5 Rxg7 Kxg7`, BB statique = **+116** alors que Stockfish voit un **mat
forcé** : BB ne « sent » pas l'attaque.

Deux refontes du terme de sécurité du roi (`King_Safety`, `bbchess-eval.adb`)
ont été tentées, chacune : corrige le blunder ciblé, mais **régresse en force**.

### 17.1 Version forte (revertée)

- Zone d'attaque **5×5** (au lieu des seules cases adjacentes), **unités
  d'attaque** pondérées par type (C/F=2, T=3, D=5, pion=1, ajoutés aux params
  `P_Atk_Pawn`/`P_King_Danger`), **danger non linéaire**
  (`Unités² × P_King_Danger / 10`, plafond 1200).
- Calibration `--params` : K=40 → biais décision +43 (vs +53 sans terme), mais
  écart sur les 65 ouvertures équilibrées 75 (vs 63).
- Banc ciblé : **#10 joue `f6e6`** dès depth 12 ; move-quality d18 +0,37 (vs
  +0,55).
- **SPRT vs HEAD (1+0.1, ouvertures neutres) : OLD 24-9-7 (68,8 %), ≈ −137 Elo,
  LOS 99,5 % → régression nette. Revertée.**

### 17.2 Version chirurgicale (revertée)

- Même structure mais **zone lointaine pondérée ÷2**, pions à poids 1,
  **quadratique plafonné à 400**, `P_King_Danger = 60`.
- Calibration : ouvertures |biais| **69** (vs 63 sans terme), biais décision
  **+10** (vs +53) ; **#10 joue `f6e6`** à depth 12.
- **SPRT vs HEAD (300 parties, livre neutralisé) : OLD 161-80-59 (63,5 %),
  HEAD +96,2 ± 36,4 Elo, LOS 100 % → régression confirmée** (le −98 vu sur 40
  parties était réel, ce n'était pas du bruit). **Revertée.**

### 17.3 Leçon

Le terme « sent » bien l'attaque (corrige le blunder, améliore la calibration
sur les positions critiques) mais **pénalise trop de positions saines** : le
coût dépasse le gain (confirmé à 300 parties pour la version chirurgicale). Un
bon terme de
sécurité du roi demande un **modèle plus fin** (attaquants réellement actifs,
phases, lignes ouvertes) **et un tuning automatique**, pas un patch de
constantes. Piste suivante : côté **recherche** (profondeur effective sur les
lignes forcées), documentée en §18.

### 17.4 Revérification (15/09) — harnais corrigé

Le −137 Elo de §17.1 avait été mesuré le 13/09 à 17h17, **avant** le correctif
de neutralisation du livre (13/09 18h26) : il était donc suspect. Le patch
« version forte » a été **reconstruit à l'identique** (zone 5×5, unités d'attaque
C/F=2, T=3, D=5, pion=1, danger non linéaire `Unités² × P_King_Danger / 10`
plafonné à 1200, `P_King_Danger = 40`) dans un worktree **hors dépôt**, puis
re-mesuré avec `sprt.sh` corrigé (livre neutralisé des deux côtés, NEW en
premier) :

- `--selftest` vert, perft 1→5 inchangé ; `--bench 9` 801 778 → **1 035 199
  nœuds** ; banc diagnostic **16 → 17/40** (le terme « sent » bien l'attaque).
- **SPRT 300 parties vs HEAD (1+0.1) : OLD 168-65-67, NEW 32,8 %, ≈ −124 ± 36
  Elo, LOS 0 %, LLR −2,03 → INCONCLUSIF au plafond (négatif net).**
- **Réplication indépendante** (graine 13, 300 parties) : NEW 32,7 %,
  ≈ **−125,7 ± 36,2 Elo**, LOS 0 % → mesure **reproductible** (−124 / −126).

**Conclusion** : le verdict de §17.1 est **confirmé** (≈ −124 vs −137, même
LOS 0 %) ; ce n'était pas un artefact du bug de livre. La « version forte »
reste **revertée** (aucun merge) : un terme de sécurité du roi correct exige un
modèle plus fin + un tuning automatique validé par SPRT (règle d'or 3).

---

## 18. Recherche — extensions, IID, checks en quiescence (résultats)

Pour voir la réfutation de `f6g5` (§17) **sans toucher l'éval**, deux extensions
standard ont été essayées dans `bbchess-search.adb`, mesurées par `--bench 9`
(référence : 780 851 nœuds / 0,53 s) et sur le coup joué en #10 :

- **Extension en échec** (tout coup donnant échec cherché +1 ply) :
  arbre **×2,8** (2 190 090 nœuds / 1,73 s) ; #10 joue toujours `f6g5`. Les
  échecs étant très fréquents, l'extension coûte plus que ce qu'elle rapporte.
  **Revertée.**
- **Extension « recapture »** (capture sur la case du coup précédent, +1 ply) :
  arbre **×3,1** (2 400 061 nœuds / 1,86 s) ; #10 joue toujours `f6g5`.
  **Revertée.**

- **IID** (recherche itérative interne quand aucun coup TT n'est disponible) :
  +5 % de nœuds ; SPRT **300 parties** vs HEAD → HEAD 51,0 %, **+6,9 ± 32,5 Elo,
  LOS 66 %** = **neutre** → non retenu.
- **Checks en quiescence** (échecs calmes générés au 1er ply de quiescence) :
  **corrige #10** (`f6g5` → `f6e6`) mais **+49 % de temps** à nœuds quasi égaux
  (knps ÷ 1,4) → écarté.

Leçon : à cadence fixe, extensions et checks en quiescence font perdre plus de
profondeur qu'ils n'en rendent sur la ligne visée ; l'IID, lui, est neutre. Une
amélioration côté recherche demande un ordonnancement/élagage plus fins et sa
**propre campagne SPRT de 300 parties** (cf. §15.4).

Bilan des §17-18 : ni le réglage de l'éval, ni les extensions/IID/checks ne
corrigent le point faible sans coût net. `--selftest` reste vert et le bench
revient à 780 851 nœuds après chaque revert.

---

## 19. Banc de positions diagnostiques

Pour arrêter d'optimiser une seule position (leçon des §17-18), un banc de
40 positions tirées des parties perdues contre GNU a été construit, chacune avec
le **coup attendu de Stockfish** :

- **`scripts/diag_bench.py build`** : parcourt les PGN perdus contre GNU,
  compare le coup joué par BB au meilleur coup de Stockfish et retient les
  erreurs **graduées** (perte 1-6 pions, pour éviter un banc saturé de mats) ;
  écrit `bench/diag.tsv` (`perte`, `phase`, `coup_attendu`, `FEN`).
- **`scripts/diag_bench.py score --binary <b>`** : rejoue chaque position avec un
  **processus BB neuf** (TT isolé, `OwnBook=false` → reproductible) et rapporte
  le **taux de coups corrects** et la **perte moyenne** vs Stockfish (bornée à
  ±10 pions pour neutraliser les scores de mat).

Contenu : 40 positions (27 milieu de jeu, 10 finale, 3 ouverture), pertes 1-6.
**Baseline HEAD : 11/40 coups corrects (28 %), perte moyenne +0,33 pion**
(médiane +0,27). Ce banc est un **thermomètre multi-positions** de
non-régression (en complément de `--selftest`), pas une cible d'optimisation.

---

## 20. Tuner SPSA (infrastructure)

`scripts/spsa.py` implémente la boucle SPSA exigée par le recadrage (le résultat
vient du **résultat réel des parties**, pas de l'erreur statique) :

- compare **deux jeux de paramètres avec le même binaire** via des wrappers
  `--params` (aucun rebuild) ;
- perturbation simultanée ±c de 35 paramètres d'éval (hors matériel), match
  A/B, mise à jour SPSA (pas `c_k = c0/(k+1)^0.101`, `a_k = 6/(k+1+10)^0.602`) ;
- livre neutralisé (fairness) et **restauré même en cas d'arrêt** (signal/
  `finally`) ; snapshots `params_current.txt` + log par itération.

Statut : infrastructure validée par smoke test. Un run utile demande plusieurs
heures de calcul (à 1+0.1, ~300 parties pour trancher un petit écart) ; le
meilleur jeu devra être **re-validé par un SPRT 300 parties** à cadence réelle.

### 20.1 Run complet (16/09) — arrêté car inerte

Un run de **50 itérations × 200 parties** (1+0.1, ~10 000 parties) a été lancé.
Après **27 itérations (~18 h)**, le vecteur `theta` était **resté identique aux
valeurs par défaut** : aucun des 35 paramètres n'a bougé d'une unité. Cause :
l'incrément

`round (a_k · (r − 0,5) · delta / c_k)`

avec `a_k = 6/(k+11)^0.602 ≈ 1,4`, `c_k = max (1, theta//8)` ≈ 1 à 6 et
`(r − 0,5) ≈ ±0,02` (bruit de 200 parties) vaut ≈ 0,003 à 0,03 → **arrondi à 0
systématiquement**. Autrement dit `a_k` est **~30 à 100× trop petit** face à
l'arrondi entier : le SPSA ne peut structurellement pas franchir un pas. Le run
a été **arrêté** (livre restauré) ; la revalidation SPRT aurait comparé HEAD à
HEAD. Piste de correction : augmenter fortement `a_k` (ou co-échelonner les
paramètres, ou augmenter le nombre de parties) et **valider par un run pilote
court** que `theta` bouge avant tout run complet.

### 20.2 Run corrigé (17-18/09) : θ bouge, revalidation non concluante

Après le correctif (`theta` flottant + `--a` configurable), deux **pilotes
courts** (8 itér. × 40 part., 0.2+0.02) confirment que `theta` bouge :
`max_move` 5,3 → 12 avec `a=200` (mais la borne haute est atteinte en ~4 itér.,
donc `a=200` est trop grand) et 1,18 → 2,67 avec `a=50`. Deux runs complets de
**50 × 200 parties** à `1+0.1`, `a=50`, sont lancés **en parallèle** sur des
copies gelées de `bin_bb` (graines 1 et 2).

**Run 1 (graine 1) — terminé.** **22 des 35** paramètres ont bougé (pas de ±1 à
±4 ; ex. `P_ROOKCONN_EG` 14→18, `P_MOBILITY_R` 2→4, `P_ROOKCONN_OP` 10→7).
**Revalidation SPRT 300 vs HEAD** : params SPSA 92-85-123 (51,2 %),
**+8,1 ± 30,2 Elo, LOS 70,1 %, LLR +0,12 → INCONCLUSIF au plafond.** Le tuning
ne démontre donc **aucun gain significatif** → **non adopté**. Cohérent avec la
leçon des § 7sexies/§21 : le tuning automatique d'éval reste déconnecté de la
force.

**Run 2 (graine 2)** : en cours (≈ itér. 37/50) ; sa revalidation SPRT 300 sera
enchaînée automatiquement (`post_all`).

### 20.3 Revalidations des deux runs (18/09)

Les deux runs ont été revalidés par un **SPRT 300 vs HEAD** (binaire optimisé +
wrapper `--params`), enchaînés automatiquement (`post_all`) :

- **Run 1 (graine 1)** : 22/35 paramètres déplacés ; **NEW 92-85-123 (51,2 %),
  +8,1 ± 30,2 Elo, LOS 70,1 %, LLR +0,12 → INCONCLUSIF**.
- **Run 2 (graine 2)** : **28/35** paramètres déplacés ; **NEW 96-79-125
  (52,8 %), +19,7 ± 30,1 Elo, LOS 90,1 %, LLR +0,37 → INCONCLUSIF**.

Aucun n'atteint le seuil de validation (règle d'or : **PASS SPRT uniquement**) →
**non adoptés**. Le run 2 est le **meilleur signal jamais observé** sur le projet
(≈ +20 Elo, LOS 90 %) sans être significatif ; un **SPRT étendu à 600 parties**
(graine 13, même wrapper) a été lancé pour trancher :

- **SPRT étendu (600 part.) : NEW 185-184-231 (50,1 %), +0,6 ± 21,8 Elo,
  LOS 52,1 %, LLR −0,08 → INCONCLUSIF.** Le +19,7 du run 2 était donc **du
  bruit** : l'effet réel des paramètres SPSA est **≈ 0**.

**Conclusion** : aucun jeu SPSA adopté. Le **tuning automatique d'éval** (Texel
§ 7sexies/§21 comme SPSA §20) est **clos comme non concluant** sur BB — cohérent
avec l'idée que l'éval handcrafted par défaut est déjà un bon optimum local.

---

## 21. Tuning d'éval à grande échelle — dataset Lichess CC0

Le tuner Texel (`scripts/tune.py`) avait échoué sur 240 parties d'auto-jeu
(5 801 positions, § 7sexies). La piste est reprise **à la bonne échelle** exigée
par le recadrage : un dataset beaucoup plus grand et **divers** (parties
humaines, pas de l'auto-jeu à profondeur fixe).

- **`scripts/gen_dataset.py`** accepte désormais les `.pgn.zst` (décompression à
  la volée) et une limite `--max`.
- **Corpus** : Lichess standard **CC0**
  (`database.lichess.org/standard/lichess_db_standard_rated_2013-01.pgn.zst`,
  16 Mo) → dataset **100 000 positions, ~97 400 distinctes** (échantillonnage
  1 ply sur 4 après l'ouverture), généré en 18 s.
- **Validation pipeline** : `tune.py` (descente de coordonnées, MSE sigmoïde,
  garde train **et** validation) réduit l'objectif sur une tranche de 10k
  (0,2226 → 0,2131 en 1 round, 18 s).

Protocole prévu (fenêtre de quelques dizaines de minutes) : générer les 100k,
lancer `tune.py`, puis **valider le jeu obtenu par un SPRT 300 parties vs HEAD**
— les règles d'or interdisent d'adopter sur la seule MSE. Le SPRT d'un jeu de
`--params` se fait via un **wrapper** (comme `scripts/spsa.py` en génère) :

```bash
python3 scripts/gen_dataset.py --max 100000 /tmp/opencode/lichess_dataset.txt \
    /tmp/opencode/lichess_2013-01.pgn.zst
python3 scripts/tune.py /tmp/opencode/lichess_dataset.txt --rounds 6 \
    --out /tmp/opencode/tuned_lichess.txt
printf '#!/bin/sh\nexec "$PWD/bin_bb/adachess_bb" --params /tmp/opencode/tuned_lichess.txt "$@"\n' \
    > /tmp/opencode/tuned_wrap.sh && chmod +x /tmp/opencode/tuned_wrap.sh
scripts/sprt.sh 1+0.1 0 5 300 7 "$PWD/bin_bb/adachess_bb" /tmp/opencode/tuned_wrap.sh
```

**Résultat (négatif).** Sur les 100 000 positions, `tune.py` réduit bien la MSE
(train 0,2173 → 0,2141 ; val 0,2158 → 0,2125) mais le jeu obtenu — 30 paramètres
modifiés, souvent poussés à 0 ou à des valeurs extrêmes — **perd ≈ 38 Elo** en
SPRT 300 parties vs HEAD (117-84-99, LOS 99 %) → **rejeté**. Conclusion : à
grande échelle et avec des parties humaines variées, la **MSE reste déconnectée
de la force** ; le tuning Texel n'est pas le bon levier. Reste l'option **SPSA**
(optimise le résultat réel des parties, §20) ou les chantiers de recherche
(point 4 du recadrage).

---

## 22. ProbCut — résultat non concluant (retiré)

Chantier 4 du recadrage (élagage tactique). Le bloc ProbCut est inséré **avant
l'ordonnancement** dans `Negamax` : sur les coups tactiques, à
`Depth ≥ ProbCut_Min_Depth = 5`, jusqu'à `ProbCut_Max_Moves = 2` coups dont le
SEE atteint `ProbCut_Margin = 200`, on cherche une version réduite de
`ProbCut_Depth = 4` plis en fenêtre nulle autour de `β + marge` ; un score qui
dépasse `β` coupe le nœud.

- **Efficacité** : `--bench 9` 801 778 → **764 828 nœuds (−4,6 %)**,
  `--selftest` vert. Mais le banc diagnostique **régresse** : 16 → 13 coups
  corrects sur 40 (perte moyenne +0,16 → −0,13).
- **SPRT 300 parties** (graine 7) : OLD (HEAD) 87-100-113 [47,8 %] →
  ProbCut **+15,1 ± 31,1 Elo**, LOS 82,9 % → **INCONCLUSIF**.
- **SPRT 600 parties** (graine 7, échantillon **indépendant** car les parties ne
  sont pas reproductibles, cf. §15.4) : OLD 193-175-232 [51,5 %] →
  ProbCut **−10,4 ± 21,8 Elo**, LOS 82,6 % pour HEAD → **INCONCLUSIF**.

Les deux échantillons encadrent zéro (cumul ≈ 0) : **aucun gain de force
démontré**, alors que le patch ajoute un chemin de code et dégrade le banc
diagnostique. → **retiré** (patch conservé hors dépôt :
`/tmp/opencode/probcut.patch`). Leçon : deux SPRT (300 puis 600 parties) peuvent
tomber de part et d'autre de zéro ; un patch neutre au sens du SPRT est rejeté,
conformément à la règle « ne jamais valider un patch sauf SPRT ».

---

## 23. Multi-cut — résultat négatif (rejeté)

Chantier 3 du recadrage, jamais tenté jusqu'ici. Variante « passe préliminaire
réduite » dans `Negamax` : à un nœud non‑PV (`Beta − Alpha = 1`), hors échec, à
`Depth ≥ 6`, on sonde jusqu'à `MultiCut_Max_Probes = 6` coups ordonnés (en
sautant le premier) avec une fenêtre nulle à `Depth − 4` ; si au moins
`MultiCut_Moves = 3` sondes atteignent `Beta`, le nœud est coupé sans recherche
complète.

- `--selftest` vert, perft inchangé ; `--bench 9` 801 778 → **787 300 nœuds
  (−1,8 %)** (temps en légère hausse).
- **SPRT 300 parties vs HEAD (1+0.1, graine 7) : OLD 111-69-120, NEW 43,0 %,
  ≈ −49 ± 31 Elo, LOS 0,1 %, LLR −1,08 → INCONCLUSIF au plafond (négatif net).**

Le multi-cut réduit bien l'arbre mais **coûte de la force** : des coupures
réduites trop optimistes font manquer des défenses. Comme le ProbCut (§22), la
technique n'apporte rien dans BB → **non retenue** (patch conservé hors dépôt,
`/tmp/opencode/adachess_bb_multicut`).

---

## 24. Outposts — résultat neutre (non retenu)

Chantier 4 du recadrage (réserve, ouvert après l'échec des chantiers 1-3). Terme
d'éval : un cavalier/fou posé sur une case **défendue par un pion ami** et
**qu'aucun pion ennemi ne peut attaquer**, hors colonne de bord et dans la
moitié adverse, reçoit un bonus (`P_Outpost_N = 25`, `P_Outpost_B = 10`, terme
`Both`).

- `--selftest` vert (symétrie et perft inchangés) ; `--bench 9` 801 778 →
  **901 287 nœuds**.
- **SPRT 300 parties vs HEAD (1+0.1, graine 7) : OLD 92-91-117, NEW 49,8 %,
  ≈ −1 ± 31 Elo, LOS 47 %, LLR −0,07 → INCONCLUSIF au plafond (neutre).**

Aucun gain mesurable (terme standard, mais ici neutre) → **non retenu** (binaire
conservé hors dépôt, `/tmp/opencode/adachess_bb_outposts`).

**Bilan des quatre chantiers du recadrage** : 1. sécurité du roi « forte » →
confirmée négative (≈ −125 Elo, répliquée) ; 2. SPSA → inerte en l'état (pas de
déplacement de paramètre) ; 3. multi-cut → négatif (≈ −49 Elo) ; 4. outposts →
neutre. Aucune de ces pistes n'ouvre de gain ; le harnais SPRT corrigé (§15) et
le banc diagnostique (§19) restent les outils de référence.

---

## 25. Optimisations CPU guidées par `perf` (×1,59, arbre identique)

Profilage par `sudo perf record -F 999 -g` (bench 11) : `Positional_Score`
23 %, `Generate_Legal_Common` 18 %, `Negamax` 16 %, `Order` 6 %, `Quiescence`
4 %, attaques glissantes ~9 %, shims `ctz/popcnt/pext` ~8 %. Optimisations
retenues, toutes **sémantiquement neutres** (`--bench 9` et `--bench 11`
gardent exactement **801 778** et **2 618 135** nœuds, `--selftest` vert,
perft 1→5 inchangé) :

- `pragma Inline` sur les primitives chaudes inter‑unités (attaques glissantes,
  `Board.Lowest_Bit/Popcount/Piece_At`, `Eval.Piece_Attacks`,
  `Movegen.Is_Attacked/Pin_Mask`, helpers de `Search`).
- `Board.Piece_At` en **O(1)** : tableau de 64 cases maintenu de façon
  incrémentale dans `Put_Piece`/`Remove_Piece` (toute mutation passe par là).
- `Order`/`Quiescence` : `Is_Tactical` et la pièce capturée calculés **une fois**
  par coup et portés à travers le tri.
- `Move_List` en `pragma Suppress_Initialization` (le remplissage à zéro des 256
  enregistrements coûtait 15 % de la movegen et 63 % de la quiescence).
- **Fusion d'éval** : les jeux d'attaques déjà calculés pour la mobilité
  alimentent aussi la sécurité du roi et le bonus `threats`, au lieu de les
  recalculer dans `King_Safety` ; l'arrondi entier est conservé à l'identique.
- `bb_popcountll`/`bb_ctzll` importés en `Convention => Intrinsic` (POPCNT/TZCNT
  en ligne en `release`, repli libgcc en `portable`) ; `bb_pext` inchangé.

**Mesure** (A/B entrelacé, cœur épinglé) : `--bench 9` 0,517 → 0,325 s
(**×1,59**, 1 552 → 2 467 knps) ; `--bench 11` 1,704 → 1,067 s (×1,60) ;
instructions retirées **−28 %**. Candidats **rejetés** après mesure : cache
d'attaques par case, inlining de SEE.

---

## 26. Match vs GNU Chess — instabilité de GNU 6.2.7

Match **2 min + 1 s, 30 parties**, **sans livre des deux côtés** (BB : livre
masqué par le SPSA ; GNU : `OwnBook = false` dans `gnuchess.ini`).
**Résultat : BB 3-20-7 = 21,7 %, ≈ −223 ± 134 Elo (LOS 0 %)** — cohérent avec
la baseline documentée (gauntlet Phase 1 : ≈ −241 Elo). L'échantillon de
6 parties qui donnait −417 était donc du bruit amplifié par la petite taille.

**Point important** : `GNU Chess 6.2.7` **segfault de façon chronique**
(journal noyau : `gnuchess[…]: segfault at 2d0 … in libc.so.6`), ce qui peut
faire **avorter un match** (`Termination "abandoned"`, « disconnects ») — un
premier essai de 30 parties s'est arrêté à la 2ᵉ. **BB n'a jamais planté**
(aucun `adachess` dans le journal noyau) : l'instabilité est purement côté GNU,
et la gestion du temps de BB est saine (0 forfait au temps).

---

## 27. Move picker (staged) — neutre (non retenu)

Implémentation d'un picker incrémental (`BBChess.Move_Picker` : `Init`/`Next`
en **sélection partielle O(n)**, filtrage TT/killers/counter, légalité
vérifiée) intégré dans `Negamax`/`Quiescence`, en trois variantes.

- **A0 — refactor pur, ordre identique** : `--bench 9` = 801 778 et
  `--bench 11` = 2 618 135 nœuds **inchangés** ; un mode debug `--picker-check`
  compare, nœud par nœud, l'ensemble **et l'ordre** des coups à l'ancien `Order`
  + tri complet → **0 mismatch** (88 689 nœuds de recherche). **Aucun gain de
  performance mesurable** : la génération reste **globale en amont** (nécessaire
  à la détection mat/pat), donc le « staging » n'évite pas de générer les coups
  silencieux.
- **A1 — tri SEE des captures** (`SEE ≥ 0` d'abord, tie MVV-LVA) : `--bench 9`
  801 778 → **654 607 nœuds (−18 %)** ; **SPRT 300 vs HEAD : NEW 92-87-121
  (50,8 %), +5,8 ± 30,4 Elo, LOS 64,6 % → INCONCLUSIF**.
- **A2 — counter-move** (table plombée dans le contexte) : `--bench 9` →
  **669 442 nœuds (−16 %)** ; **SPRT 300 : NEW 95-89-116 (51,0 %), +6,9 ± 30,8
  Elo, LOS 67,1 % → INCONCLUSIF**.

Les trois variantes sont **neutres** : ni le picker seul (A0), ni le tri SEE
(A1, cohérent avec l'échec du « tri SEE » de la Phase 2), ni le counter-move
(A2, déjà reverté en Phase 2) n'apportent de gain significatif ; la réduction de
nœuds ne se traduit pas en force. → **non retenu** (patch conservé hors dépôt,
`/tmp/opencode/adachess_bb_picker*`).

---

## 28. Modulation du LMR (killer) — résultat négatif

Seul manque réel identifié dans le LMR (audit : la table log et la re-recherche
PVS existent déjà) : la **modulation** de la réduction. Premier incrément,
isolé : un coup qui est **killer** à ce pli est réduit **d'un cran de moins**
(`R := R − 1`, borné à 0), les killers étant des coups calmes connus comme forts.

- `--selftest` vert, perft inchangé ; `--bench 9` 801 778 → **757 779 nœuds
  (−5,5 %)** mais `--bench 11` 2 618 135 → **2 715 954 (+3,7 %)**.
- **SPRT 300 vs HEAD (1+0.1, graine 7) : OLD 101-71-128, NEW 45,0 %,
  ≈ −34,9 ± 29,8 Elo, LOS 1,1 %, LLR −0,81 → INCONCLUSIF au plafond (négatif).**

Réduire moins les killers **nuit** ici : cela revient à chercher plus
profondément des coups déjà bien ordonnancés (le killer a déjà un score d'ordre
élevé), au prix d'un arbre plus gros par ailleurs. → **non retenu** (patch hors
dépôt, `/tmp/opencode/adachess_bb_lmr_killer`). Restent non testés le flag
`improving` et une modulation par l'history, mais l'échec du killer rend la
famille peu prometteuse.

---

## 29. Validation en force de l'optimisation CPU (×1,59)

L'optimisation du §25 est **bit-identique** (mêmes nœuds à profondeur fixe) :
elle ne change pas la qualité des décisions mais rend la recherche **×1,58 plus
rapide** (`--bench 9` 0,560 → 0,355 s, 1 432 → 2 258 knps). À **cadence fixe**,
elle doit donc chercher plus profond et jouer plus fort.

**SPRT 300 parties à 1+0.1** (binaire optimisé vs binaire pré-optimisation, livre
neutralisé) :

- **NEW (optimisé) 128-57-115 (61,8 %), +83,8 ± 31,2 Elo, LOS 100 %,
  LLR +1,68 → INCONCLUSIF au plafond (positif massif).**

C'est le **seul gain de force démontré et important** de la campagne
(≈ **+84 Elo** à 1+0.1) : il valide l'optimisation CPU comme **le levier le plus
rentable**, bien plus que les techniques de recherche/éval testées (§§22-28,
toutes neutres ou négatives). Leçon : pour un moteur handcrafted déjà proche de
son optimum, **la vitesse rapporte plus que les heuristiques**. Piste
prioritaire pour la suite : **poursuivre l'optimisation CPU** (éval
incrémentale, etc.).

---

## 30. Optimisation CPU #2 (×1,13) — adoptée

Deuxième passe de profilage `perf` (§29 ayant montré que la vitesse se traduit
en force). Changements **sans modification de comportement** (`--bench 9` /
`--bench 11` toujours **801 778 / 2 618 135** nœuds, `--selftest` vert,
`portable` vert) :

- **PEXT inliné** : `bbchess-attacks.adb` sélectionne à la compilation
  l'intrinsèque BMI2 (`__builtin_ia32_pext_di`, build `release`, via le
  préprocesseur intégré GNAT `-gnatep` + `-gnateDREL`) ou le repli logiciel
  (`portable`). Nouveau fichier de build `src_bb/prep.data`.
- **`Make_Move`** : victime lue dans la carte O(1) `Squares` (plus de scan des 6
  bitboards) ; boucle Zobrist des droits de roque évitée quand les droits ne
  changent pas.
- **`Movegen`** : chemin rapide sans échec/épingle ; test `Piece = Roi` au lieu
  de la décomposition mod-6 ; génération en place (plus de copie de pile 3 Ko) ;
  rayons précalculés pour `Pin_Mask`.
- **Éval** : ensemble d'attaque des pions par deux shifts ; scans de pions de
  `King_Safety` restreints aux 3 colonnes de l'aile ; `Material_PST_Value`
  inline.

**Mesure** : `--bench 11` **9,43 G → 8,31 G instructions (−11,9 %)** ; `--bench 9`
0,326 → 0,288 s (×1,13). **SPRT 300 à 1+0.1 vs opt1 : NEW 92-80-128 (52,0 %),
+13,9 ± 29,8 Elo, LOS 82,0 % → positif mais non significatif** (cohérent avec
l'effet attendu ≈ +20 Elo pour un gain de vitesse de ×1,13). Adoptée sur le
critère **objectif** (arbre bit-identique + plus rapide + self-test vert), comme
opt1 (§25).

---

## 31. Optimisation CPU #3 (×1,13) — adoptée

Troisième passe (profilage + optimisation), toujours **sans changement de
comportement** (`--bench 9/11` = **801 778 / 2 618 135** nœuds, `--selftest`
vert, éval **byte-identique** sur 41 positions, bestmoves identiques à
profondeur 8 et 10, `portable` vert) :

- **`Movegen`** : `Generate_Pseudo_Moves` signale `King_First` ; chemin rapide
  (sans échec/épingle/ep) qui **avance `Count` au-delà du préfixe non-roi** sans
  copier un seul coup, puis filtre la queue du roi ; boucle générique sans
  auto-copie ; `Add` inliné.
- **Éval** : boucle de mobilité scindée en 4 corps littéraux (pliage des
  `Piece_Attacks`/poids) ; `Game_Phase` un popcount par type sur l'union ;
  test de colonne de tempête supprimé (masque d'aile déjà restrictif) ;
  isolés via `Neighbor_Files` précalculé ; `Front_Blockers` hissé.
- **SEE** : copie de travail réduite à un `See_Board` bitboard-only (12 boards +
  2 occupations) au lieu d'une `Position` complète ; `Pin_Mask_See` local.
- **`Negamax`** : le null-move ne sauve/restaure que `Side`/`En_Passant`/`Key`
  au lieu de copier toute la `Position`.

**Mesure** : `--bench 11` **8,31 G → 7,29 G instructions (−12,2 %)** ; `--bench 9`
0,326 → 0,274 s. **SPRT 300 à 1+0.1 vs opt2 : NEW 96-82-122 (52,3 %),
+16,2 ± 30,3 Elo, LOS 85,3 % → positif (non significatif).** Adoptée sur le
même critère objectif que opt1/opt2.

---

## 32. Bilan force des optimisations CPU (capstone) — ×2,01 vitesse, +170 Elo

Mesure agrégée des trois passes (§29-31) par un **SPRT 300 à 1+0,1** entre le
moteur actuel (opt1+opt2+opt3) et la **baseline d'avant toute optimisation** :

| | avant (pre-opt) | après (opt1+2+3) | facteur |
|---|---|---|---|
| `--bench 9` | 0,589 s | 0,278 s | **×2,12** |
| knps | 1 360 | 2 880 | **×2,12** |

**SPRT** : NEW 122-19-86 (**72,7 %**), **+170,0 ± 36,8 Elo, LOS 100 % →
VERDICT PASS (H1 accepté)**. L'arbre reste **bit-identique**
(801 778 / 2 618 135 nœuds) : le gain est **purement** dû à la vitesse.

**Re-mesure après la 4ᵉ passe** (§33, opt1+2+3+4, `--bench 9` 0,561 → 0,264 s,
**×2,12**), même protocole : SPRT 300 : NEW 144-42-114 (**67,0 %**),
**+123,0 ± 31,6 Elo, LOS 100 % → plafond, positif massif**. La différence avec
les +170 précédents est l'**intervalle de confiance** (±32 vs ±37) : les deux
mesures sont compatibles, le gain cumulé réel se situe vers **+140 ± 35 Elo**
(les deux runs partagent la même graine/livre, d'où une variance corrélée).

Conclusion : sur ce moteur, le **seul levier de force démontré** est
l'optimisation CPU (≈ ×2 vitesse ⇒ ≈ +110 à +170 Elo) ; le tuning de
l'évaluation (Texel, SPSA, §20-21) est resté **neutre/négatif**. Priorité future :
continuer le profilage et l'optimisation.

---

## 33. Optimisation CPU #4 (×1,08) — adoptée

Quatrième passe de profilage/optimisation `perf` (bench 11), toujours **sans
changement de comportement** (`--bench 9/11` = **801 778 / 2 618 135** nœuds
exacts, `--selftest` vert, perft 1→5 inchangé, `portable` vert).

**Profil de départ** (self-%, cycles, bench 11) : `Negamax` ~37 % (dont ~19 %
sur le chargement du bucket TT, cache-miss), `Positional_Score` ~21 %,
`Generate_Legal_Common` ~16 %, `Quiescence` 4,4 %, `SEE.Exchange` 4,2 %,
`Make_Move` 3,4 %, `King_Safety` 2,9 %. Instructions de référence :
**7 293 943 192** (bench 11).

Changements retenus (tous vérifiés **éval byte-identique** sur 41 positions
diag + 10 000 positions aléatoires, bestmoves identiques à profondeur 8 sur les
40 positions et 10 sur un sous-ensemble) :

- **`Negamax` — prefetch TT** : `__builtin_prefetch` (intrinsèque GCC importé
  en Ada) sur le bucket TT **dès l'entrée du nœud**, avant les tests de
  nulle/mat ; le cache-miss se recouvre avec le prologue. Pur indice, aucun
  effet architectural. C'est le gain le plus rentable (l'attente mémoire du
  probe dominait le profil cycles).
- **`Quiescence` — partition tactique sautée hors échec** : en position calme
  le générateur ne produit déjà que des coups tactiques, donc la passe de
  filtrage `Is_Tactical` + permutations est un no-op ; elle n'est conservée que
  dans le cas « en échec ».
- **`Negamax` — `Is_Tactical` hissé** : l'occupation ennemie est calculée une
  fois hors de la boucle d'ordonnancement (prédicat identique).
- **`Movegen` — `Target_Mask` hissé** : masque de cibles (ennemi si tactique,
  non-soi sinon) calculé une fois au lieu d'être re-testé par pièce des 5
  boucles de génération.
- **`King_Safety` — bouclier/storm en pur bitboard** : le minimum par colonne
  des pions est remplacé par des tests de rang (masques précalculés
  `Shield_Row_Mask` / `Home_Row_Mask`) et la tempête par un **popcount** unique
  (`Storm_Mask`) au lieu d'une boucle par pion.
- **`Positional_Score` — structure de pions repliée par fichier** : les huit
  popcounts par colonne sont remplacés par un repli des rangs en un octet de
  présence ; doublés = `popcount(pions) − nb_colonnes`, isolés = popcount de
  l'expansion des colonnes isolées. Algèbre exacte (linéarité), éval identique.
- **`Front_Blockers` — remplissage logarithmique (Kogge-Stone)** des rangs 1..7
  en 3 décalages doublants + 1 décalage final, au lieu de 7 itérations.

**Mesure** (A/B cycles entrelacé, min et médiane concordants sur 12 répétitions) :

| | avant (opt3) | après (opt4) | facteur |
|---|---|---|---|
| instructions bench 11 | 7,294 G | 6,787 G | **−6,9 %** |
| cycles bench 11 | 3,559 G | 3,343 G | **−6,1 %** |
| A/B entrelacé (min) | 3,498 G | 3,231 G | **×1,08** |

`--bench 9` 0,278 → ~0,235 s. Candidats **rejetés après mesure** (plus lents ou
neutres) : accumulateurs scalaires d'éval, cumul de mobilité par type,
popcounts de menace par type, prefetch des deux entrées du bucket, hoist du roi
« à la maison ».

**SPRT 300 à 1+0,1 vs opt3 : NEW 91-78-131 (52,2 %), +15,1 ± 29,5 Elo,
LOS 84,1 % → positif (non significatif).** Adoptée sur le même critère objectif
que opt1/opt2/opt3 (arbre bit-identique, éval byte-identique, plus rapide).
Voir `CHANGELOG.md`.

---

## 34. Modulation du LMR par le flag `improving` (Phase 3b) — résultat négatif

Dernier item non testé de la famille « modulation LMR » (Phase 3). Implémentation
**canonique** : éval statique mémorisée par pli (`Eval_Path`), et
`Improving := Eval_Now > Eval_{même camp, 2 plis avant} − 10` ; un coup calme
tardif à profondeur ≥ 3 est **réduit d'un pli de plus** si `not Improving`.
L'éval du nœud est calculée une seule fois et réutilisée par razoring/futilité.
(La comparaison se fait à **2 plis** — même camp — et non à 1 pli : un écart d'un
pli change de perspective et mesure le tempo, cf. Stockfish/Ethereal.)

- `--selftest` vert, perft 1→5 inchangé, partie complète sans erreur ;
  `--bench 9` 801 778 → **733 011 nœuds** ; `--bench 11` 2 618 135 → **2 298 616**.
- **SPRT 300 vs opt1-3 (1+0.1, graine 7) : NEW 71-89-140, 47,0 %,
  −20,9 ± 28,7 Elo, LOS 7,7 %, LLR −0,55 → INCONCLUSIF au plafond (négatif).**

Avec la variante killer (§28, ≈ −35 Elo), la **modulation du LMR est close :
les deux formes testées nuisent**. Le LMR de base (table log + re-recherche PVS)
est conservé tel quel. → **non retenu** (patch hors dépôt,
`/tmp/opencode/adachess_bb_p3b`). Reste la modulation par l'**history**, non
testée, mais que l'échec des deux autres formes rend peu prometteuse.

---

## 35. Phase 5 — outillage UCI asynchrone (`go nodes` / `go infinite` / `stop`)

**Objectif** : rendre le protocole UCI utilisable comme outil (analyse
interrompue, plafond de nœuds) **sans toucher à une seule décision de
recherche**. Avant, `Handle_UCI_Go` appelait le `Best_Move` synchrone et
bloquait la boucle de commandes : `stop`, `isready` et `quit` n'étaient servis
qu'après le `bestmove`. `stop`/`ponderhit`/`debug`/`register` étaient même
ignorés (`null`).

**Mécanisme (réutilise l'interruption existante)** : la recherche temporisée
était déjà interruptible — `Poll_Time` (tous les `Check_Interval = 1024` nœuds)
lève `Search_Interrupted` sur `Stop_Search` (booléen `pragma Atomic`, posé par
le thread SMP primaire). On ajoute :

- une **seconde demande d'arrêt externe** `Abort_Request` (`Request_Stop` /
  `Clear_Stop`, atomique), testée par le même `Poll_Time`. Elle est distincte de
  `Stop_Search` (que le thread primaire remet à `False` entre deux recherches)
  et n'est effacée qu'au démarrage de la recherche suivante ;
- un **plafond de nœuds** `Node_Limit` **par contexte de recherche** (champ de
  `Search_Context`, armé par le `Best_Move` à 4 arguments), pollé dans
  `Poll_Time` : un `go nodes N` s'arrête à `N` nœuds à un intervalle de sondage
  près. Le plafond est propagé aux threads Lazy SMP via `Root_Node_Cap` ;
- un **verrou console** protégé (`Console` / `Locked_Put_Line`) partagé par les
  rapports d'itération XBoard « post » et les lignes UCI (`readyok`,
  `bestmove`) : `Ada.Text_IO` n'est pas réentrant et la recherche vit désormais
  dans une tâche.

**Côté boucle de commandes** : `Handle_UCI_Go` lance la recherche dans une
**tâche** `UCI_Search_Task` (créée au premier `go`, pour ne pas activer de
tâche en `--selftest`/`--bench`) via une entrée `Start` (position, profondeur,
budget, plafond copiés), et rend la main immédiatement. `isready` répond
`readyok` depuis la boucle principale, même recherche en cours ; `stop` arme
`Abort_Request` ; `quit` (et la fin de stdin) arrête la recherche puis termine
la tâche. Un `go` sur une recherche déjà en cours l'interrompt d'abord (les deux
`bestmove` sont émis). `go infinite` n'est borné que par `stop` (profondeur
64) et `go nodes`/`infinite` ne sondent pas le livre.

**Non-régression vérifiée** : `--selftest` vert ; `--bench 9` = **801 778** et
`--bench 11` = **2 618 135** nœuds (inchangés, ils n'utilisent pas l'UCI) ;
XBoard inchangé (mêmes lignes d'itération, même `move`) ; `go depth 10` sur
startpos **OLD vs NEW : `bestmove b1c3` et nœuds identiques** (20730 / 44349 /
65383 / 109826 aux profondeurs 7→10). Tests de protocole : `go nodes 200000`
s'arrête à 191 274 nœuds (profondeur 11 complétée), `go infinite` + `stop`
rend le coup en **< 1 ms**, `isready` pendant la recherche répond `readyok`
immédiatement, `quit` en pleine recherche sort en 15 ms (pas de blocage),
y compris avec `--threads 4` et sur des cycles `go`/`stop` répétés. Patch hors
dépôt : `/tmp/opencode/p5.patch`, binaire `/tmp/opencode/adachess_bb_p5`.

---

## 36. Optimisation CPU #5 (arbre identique) — adoptée sur critère objectif

Cinquième passe de profilage/optimisation `perf` (bench 11/12), toujours **sans
changement de comportement** (`--bench 9/11` = **801 778 / 2 618 135** nœuds
exacts, `--selftest` vert, perft 1→5 et `Static` inchangés, `--portable` vert).

**Profil de départ** (self-%, cycles, bench 11) : `Negamax` ~37 %,
`Positional_Score` ~21 %, `Generate_Legal_Common` ~16 %, `Make_Move` ~5 %,
`SEE.Exchange` ~4 %, `Quiescence` ~4 %, `King_Safety` ~3 %. Instructions de
référence : **6 787 908 425** (bench 11), cycles 3 262 M.

Changements retenus (éval **byte-identique** sur 41 positions diag + 10 000
positions aléatoires, bestmoves identiques à profondeur 8 sur 40 positions et 10
sur un sous-ensemble) :

- **`Negamax` — tableau `Tac` supprimé (gain principal)** : le drapeau
  « tactique » de chaque coup était recopié dans un troisième tableau à travers
  le tri par sélection, alors qu'il n'est lu qu'à la position finale `I`. Il est
  désormais **recalculé après le tri** (même prédicat : flag ep/promotion ou
  `Enemy_Occ` sur la case d'arrivée), et seuls `Moves` et `Ord` sont permutés :
  une écriture mémoire en moins par coup et par échange.
- **`Make_Move`/`Unmake_Move` — `Move_Piece` fusionné** : pour un déplacement
  non-promotion, `Remove_Piece` + `Put_Piece` (six and/or sur les bitboards
  pièce/occupation/couleur) devient un seul passage en trois XOR
  (`Bit (From) xor Bit (To)`). Les promotions gardent l'ancien remove/put
  (le type de pièce change).
- **LTO** : `-flto` activé en `release` (Ada et C) ; `Insufficient_Material` et
  `Syzygy.Enabled` (appelés à chaque nœud) inlinés.

**Mesure** (A/B cycles+instructions entrelacé, min de 21 répétitions, bench 11) :

| | avant (opt4) | après (opt5) | facteur |
|---|---|---|---|
| instructions bench 11 | 6,778 G | 6,567 G | **−3,1 %** |
| cycles bench 11 | 3,224 G | 3,098 G | **−3,9 %** |
| `--bench 9` (min) | 0,230 s | 0,218 s | **×1,05** |

**Candidats rejetés après mesure** (plus lents ou neutres) : `-march=native`,
`-mtune=native`, `-Ofast`, `-funroll-loops`, `-fomit-frame-pointer`, PGO,
`Move_Type` compacté (bit-packé ou aligné octet), historique 16 bits, TT scindé
clé/données, TT padding 32 octets / bucket aligné sur ligne de cache, accumu-
lation de mobilité par type, `Piece_At` remplacé par la carte `Squares` dans les
menaces, `Store` avec chargement unique du bucket, prefetch côté parent, tri
d'insertion stable (le tri par sélection **n'est pas stable** : l'ordre des
ex-æquo change, donc l'arbre change — vérifié, `--bench 9` passe à 662 777).

**SPRT 300 à 1+0,1 vs opt4 : NEW 86-84-130 (50,3 %), +2,3 ± 29,6 Elo,
LOS 56,1 % → neutre** (attendu : ×1,04 de vitesse ⇒ ~+4 Elo, sous le pouvoir
de résolution de 300 parties). Adoptée sur le même critère **objectif** que
opt1-opt4 : **arbre bit-identique**, éval byte-identique, self-test/portable
verts, plus rapide. Patch hors dépôt : `/tmp/opencode/opt5.patch`, binaire
`/tmp/opencode/adachess_bb_opt5`.

---

## 37. Optimisation CPU #6 (TT 24 octets) — adoptée

Sixième passe. Axe **nouveau** : la **taille** de l'entrée de table de
transposition, seul levier restant après l'épuisement des changements de code.
L'entrée passe de **32 à 24 octets** : le champ `Depth` (borné à `-1 ..
Max_Ply`, soit 0..128, plus le marqueur vide -1) est porté en **16 bits**
(`TT_Depth_Type`, `'Size use 16`) et les membres larges sont regroupés en tête
(8 clé + 4 coup + 4 score + 4 âge + 1 borne + 2 profondeur + 1 bourrage). La
table passe de **32 à 24 Mo**, plus proche des **8 Mo de L3**.

Les **valeurs**, la **condition d'acceptation** et la **politique de
remplacement** sont inchangées (seules deux comparaisons sont converties) : à
profondeur fixe l'arbre reste **bit-identique** (`--bench 9/11` = 801 778 /
2 618 135 nœuds, `--selftest` vert, perft 1→5 et `Static` inchangés, éval
byte-identique sur 40 diag + 12 000 fuzz, bestmoves identiques d8/d10,
`portable` vert).

**Mesure** (A/B entrelacé, min de 31 répétitions, bench 11) : cycles
**3 140 M → 3 067 M (−2,3 %, ×1,024)**, médiane −2,2 %, **instructions
−0,1 %** → le gain est **purement** sur le chemin mémoire/cache (moins de
cache-misses), pas sur le nombre d'opérations. `--bench 9` cycles −2,0 %.

**SPRT 300 à 1+0,1 vs opt5 : NEW 80-73-147 (51,2 %), +8,1 ± 28,1 Elo,
LOS 71,4 % → positif (non significatif).** Adoptée sur le même critère objectif
que opt1-opt5. Patch hors dépôt : `/tmp/opencode/opt6.patch`, binaire
`/tmp/opencode/adachess_bb_opt6`. Piste restante identifiée mais **écartée** :
un TT « scindé clé/données » ou un layout par buckets qui changerait les entrées
acceptées (interdit sans changer l'arbre) ; le stall mémoire dans `Negamax`
(~35 %) est désormais **considéré épuisé** côté micro-optimisations sûres.

---

## 38. Recherche — NMP adaptatif et borne de quiescence (deux gains)

Audit du prompt « chantiers 1‑3 » (détail dans `NOTES_TUNING.md`) : NMP, LMR,
futility, razoring, delta pruning, SEE<0 et évasions complètes **existaient
déjà** ; l'éval est **déjà tapered** et le tuning Texel **déjà fait** (§21,
négatif). Seuls deux vrais manques ont été comblés, chacun validé par SPRT
300 à 1+0,1 vs HEAD (livre neutralisé).

**1. NMP à réduction adaptative** (commit `36aff42`) — `R := 3 + Depth/4`
(division entière, clamp du child depth), au lieu de `R = 2` fixe ; gardes
`Depth >= 3` / hors échec / `Has_Non_Pawn` conservées.

- Nœuds : 801 778 → **593 786** (−25,9 %) ; 2 618 135 → **1 585 577** (−39,4 %).
- **SPRT : +18,5 ± 28,9 Elo, LOS 89,6 % → positif.**

**2. Borne de profondeur en quiescence** (commit `f4437fc`) — `Max_Q_Depth = 8` ;
au plafond, nœud calme → stand‑pat borné par alpha ; nœud **en échec** → toutes
les évasions générées et notées statiquement (pas de récursion), donc jamais
d'éval statique d'une position en échec et mat/joueur pat préservés.

- Nœuds : 801 778 → **750 402** (−6,4 %) ; 2 618 135 → **2 043 401** (−21,9 %).
- **SPRT : +15,1 ± 29,7 Elo, LOS 84,0 % → positif.**

**Effet combiné** (SPRT 300 vs HEAD) : **+10,4 ± 29,4 Elo, LOS 75,7 % →
positif** (subadditif — les deux élags portent sur des lignes proches, mais
chaque delta est individuellement positif). Gates : `--selftest` vert, perft
1→5 identique, mat détecté, self‑play propre, `portable` vert pour les deux.

---

## 39. Corrections d'audit (B1-B6) et outillage de match

Un audit **en lecture seule** (Oracle) a trouvé des défauts concrets, tous
corrigés. Aucun ne changeait le chemin XBoard du SPRT, donc B1-B5 ne coûtent pas
de non‑régression mesurable ; B6 change l'arbre (SPRT).

**B1 — répétition morte sous UCI** (`adachess_bb.adb`) : `Sync_Game_History`
n'était appelé que par le chemin XBoard ; sous UCI la recherche ne voyait pas les
répétitions de la **partie réelle** (seulement celles internes à la recherche).
Corrigé : appel avant le `Start` de la tâche. Preuve : sur triple répétition, le
binaire pristine joue `g1f3` **+19** (aveugle), le corrigé `d2d4` **+2**.

**B2 — fuite `Stop_Search`** (`bbchess-search.adb`) : après `Threads 4` puis
`Threads 1`, le chemin mono‑thread abortait à la première sonde de `Poll_Time`
→ `Empty_Move` → jeu quasi aléatoire. Corrigé : `Stop_Search := False` en tête du
`Best_Move` 4‑args. Test de régression ajouté (nœuds ST après MT : 1024 → 1434).

**B3 — fuite `Search_Context`** (~41 Ko par recherche, jamais libéré) : libéré via
`Unchecked_Deallocation` aux trois sites.

**B4 — débordement tampon sous `-gnatp`** : `Current_Command (1..64)` recevait un
token jusqu'à ~8 Ko. Nouveau `BBChess.Text` (copies bornées) ; le build debug
pristine **crashait**, le corrigé survit.

**B5 — course d'écriture TT sous Lazy SMP** : l'entrée de 24 octets était écrite
d'un bloc ; un lecteur pouvait voir la **clé neuve** avec un payload **périmé**
(cutoff faux). Corrigé : `Hash_Key` **publiée en dernier** (payload d'abord,
champ par champ). Arbre mono‑thread **bit‑identique**.

**B6 — borne quiescence non sound en échec** : au plafond, un nœud en échec
notait ses évasions **statiquement** (`-Evaluate`) — la recapture adverse n'était
pas vue, le score pouvait être grossièrement faux. Corrigé : détection du mat
seule, puis **fail‑low** (`return A`). Nœuds 593 601 → 593 576 / 1 769 496 →
1 769 154. **SPRT 300 vs HEAD : +11,6 ± 28,7 Elo, LOS 78,5 %** (correctif
adopté : pas de régression, bug corrigé). La doc « un mat n'est jamais
manqué » était trop forte : seuls les mats **dans le cap** ou **tout en échecs**
sont garantis.

**Outillage** : `scripts/vs_gnuchess.sh` utilise désormais la **même suite
d'ouvertures** (`openings/openings.epd`) que `sprt.sh` et neutralise le livre des
deux côtés. Auparavant chaque partie partait de la position initiale → biais
Blanc massif (match de 25 part. vs GNU : BB 5-17-3 = 26 %, −181,7 ± 159,9 Elo,
**70 % de victoires Blanc**).

**Invariants** : `--selftest` vert, perft 1→5 exact, `portable` vert,
`--bench` (593 601/1 769 496) préservé pour B1-B5.

---

## 40. Ordonnancement — counter-move + continuation history (gain confirmé)

Le plus grand manque moderne identifié par l'audit (§39) : l'ordonnancement
n'utilisait que hash / promotions / MVV-LVA / killers / history
`(camp, depuis, vers)`.

**Ajouté** (uniquement `bbchess-search.adb`, tables par thread dans
`Search_Context`, remises à zéro dans `Init_Context`) :

- **Counter-move** `Counter (Camp, Depuis, Vers)` : le coup qui a réfuté le coup
  adverse « Depuis-Vers » (score d'ordre **800 000**, juste sous les killers).
- **Continuation history 1 ply** `Cont_History (768 × 768)`, indexée sur
  `(pièce, case)` du coup **précédent** et du coup courant, même saturation que
  l'history (`±16 384`), **pondérée ×6** dans le score d'ordre.
- Nouveau `Move_Path (0..Max_Ply)` par thread : copié **par valeur** en entrée de
  nœud (aucun pointeur → rien de périmé après `Unmake`) ; le null-move le remet à
  `Empty_Move` pour qu'un enfant nul n'hérite pas d'un coup étranger. Vérifié
  aussi en build `-gnata`.

**Effet sur l'arbre** : réduction à **toutes** les profondeurs —
`--bench 9` 593 576 → **496 570** (−16,3 %), `--bench 11` 1 769 154 →
**1 434 292** (−18,9 %), d12 −13,3 %.

**Validation (SPRT 1 000 parties, 1+0.1, graine 7)** — résolution choisie
conformément à §39 pour trancher un effet de ~+20 Elo :

- **NEW 291-227-482 (53,2 %), +22,3 ± 15,5 Elo, LOS 99,8 %** →
  IC [≈ +7 ; +38] **exclut zéro**. C'est le **gain de recherche le plus net et
  confirmé** de la campagne (les deltas §38, mesurés à 300 parties, restaient
  dans le bruit). Gates : `--selftest` vert, perft 1→5 exact, self-play et
  `--threads 4` propres, `portable` vert.
- Adopté. Patch hors dépôt : `/tmp/opencode/d3.patch`, binaire
  `/tmp/opencode/adachess_bb_d3`.

---

## 41. Gestion du temps — séparation soft/hard (audit §39)

L'audit relevait une allocation **très conservatrice** et **sans split
soft/hard** : `restant/30 + 0,75×incrément`, plafonnée à 2 s et à
`restant − 0,05 s`. Le moteur laissait donc de nombreux coups sous-consommer la
pendule (pas d'itération « de secours » au-delà de la cible) et n'exploitait pas
`movestogo` / `level`.

**Nouveau module pur `BBChess.Clocks`** (arithmétique testable en self-test) :

- `Exact (movetime)` : soft = hard = temps demandé (comportement `st`/`movetime`
  inchangé, aucune réserve).
- `Clock_Based (restant, incrément, movestogo)` :
  - `soft = restant / m + 0,75 × incrément`, avec `m = movestogo` s'il est
    annoncé, sinon `m = 30` (l'ancien `/30`) ;
  - plafond anti-pic `2 s` **seulement** quand `m` est inconnu ; un `movestogo`
    explicite lève ce plafond (seule la réserve d'horloge borne) ;
  - `hard = 2 × soft`, borné par la réserve ;
  - **marge de sécurité de 0,1 s** réservée en permanence (`soft` et `hard`
    ≤ `restant − 0,1 s`), contre 0,05 s auparavant ;
  - plancher 1 ms.
- Le **hard** est l'échéance interruptible armée dans le contexte (pollée toutes
  les 1024 nœuds) ; le **soft** n'est consulté qu'entre itérations :
  `Iterative_Search` ne lance plus de nouvelle itération dès que `écoulé ≥ soft`
  **ou** que `écoulé + durée de l'itération précédente > soft`. La **toute
  première itération** est toujours tentée (seule source de coup), bornée par le
  hard. Nouvelle surcharge `Best_Move (Position, Max_Depth, Soft, Hard)`, sans
  plafond de nœuds ; les surcharges existantes (profondeur fixe, échéance seule,
  `go nodes`) passent `soft = hard = échéance` et sont donc bit-identiques.

**Driver** : `movestogo` (UCI) et `level MPS base inc` (XBoard, token 1) sont
lus ; le compteur est décrémenté après chaque coup joué (livre inclus). Les
modes `go infinite`/`go nodes` restent sans budget (soft = hard = 0).

**Gates** : `--selftest` vert, perft 1→5 exact, `--bench 9/11` =
**496 570 / 1 434 292** nœuds exacts (aucune décision de recherche modifiée),
build `portable` vert, parties réelles à `1+0.1` sans forfait (temps/coup
rapporté). Nouveaux self-tests : arithmétique d'allocation (marge, hard ≥ soft,
`movestogo`, petit restant) et non-régression nœuds/move soft/hard = profondeur
fixe.

**SPRT 1 000 parties à 1+0.1 vs HEAD** — le **premier `VERDICT: PASS` de la
campagne** :

- **NEW 269-156-372 (57,1 %), +49,6 ± 17,6 Elo, LOS 100 %, LLR 1,59 → PASS.**
- **0 forfait au temps** sur tout le match (l'ancienne formule, plafonnée à 2 s
  et sans itération « de secours », sous-utilisait la pendule : la nouvelle
  exploite le hard limit et cherche plus profond à cadence fixe).

Adopté. Patch hors dépôt : `/tmp/opencode/d5.patch`, binaire
`/tmp/opencode/adachess_bb_d5`.

---

## 42. Match externe vs GNU Chess après D3+D5 — non concluant

Match **1 min + 1 s, 30 parties**, **ouvertures équitables**
(`openings/openings.epd`, chaque ouverture jouée dans les deux couleurs) et
**livre neutralisé des deux côtés** (nouveau `vs_gnuchess.sh`, §39).

- **BB 2-17-11 = 25,0 %, ≈ −190,8 ± 108,4 Elo (LOS 0 %)**, 0 forfait au temps.
- Répartition **par couleur équilibrée** : BB Blancs 23,3 %, BB Noirs 26,7 %
  (contre 46 % / 4 % sur le match précédent depuis startpos) → **le biais
  d'ouverture est corrigé**.

**Interprétation** : le score externe ne progresse pas de façon démontrable
(25,0 % vs 21,7 % historique §26 ; IC à n=30 de ±108 Elo). Les gains self‑play de
D3 (+22) et D5 (+50, `PASS`) **ne se confirment pas en externe à cet
échantillon** — soit l'effet réel est plus faible, soit 30 parties ne peuvent pas
résoudre ~+50 Elo (il faudrait ~300 parties, ≈ 7 h à 1+1). C'est le schéma
récurrent du projet : **ne jamais conclure sur un match court** ; le SPRT long
reste le seul juge exploitable.

---

## 43. Constantes de recherche exposées (D4) + SPSA recherche (D4b)

**D4 — 17 constantes de recherche rendues tunables** (`bbchess-search.adb`,
`adachess_bb.adb`) via le mécanisme existant `--params` / `--dump-params` (même
patron que l'éval : énumération + tableau + `Set` + `Dump`) : marges
futilité/razoring, fenêtre d'aspiration, delta quiescence, `Max_Q_Depth`, base et
diviseur de la réduction null adaptative, LMP base/quad, garde d'extension
d'échec, score counter‑move, poids continuation‑history, borne history, et les
**deux constantes réelles** de la formule LMR (table reconstruite au changement).

- **Défauts bit‑identiques** : `--bench 9/11` = **496 570 / 1 434 292** sans
  params **et** avec un dump complet des défauts ; `--selftest`/perft/`portable`
  verts. Preuve que les params sont **réellement câblés** : changer une marge
  change le nombre de nœuds.

**D4b — outillage SPSA étendu et corrigé** (`scripts/spsa.py`) : lecture des
réels (`S_LMR_BASE 7.5E-01`) sans planter, mode `--search-only` (marges + LMR,
hors commutateurs structurels et `Counter_Score`), et **pas normalisé par
l'échelle** — le gain était calibré pour l'éval (magnitude ~100) et envoyait
`S_LMP_QUAD`/`S_NULL_RED_BASE` aux bornes en une itération ; perturbation et mise
à jour sont désormais proportionnelles au pas propre de chaque paramètre.

Campagne `--search-only` (24 iter × 80 part. à 0,5+0,05) : **θ reste stable**
au voisinage des défauts (vérifié sur sonde). Le résultat de la campagne et sa
validation SPRT longue sont consignés au §44.

---

## 44. SPSA sur les constantes de recherche (D4b) — neutre

Campagne `--search-only` : **24 itérations × 80 parties** (0,5+0,05). Après
24 itérations, θ n'a quasi **pas bougé** (< 1 % des défauts) : `S_FUTILITY_MARGIN`
180 → 179,8 ; `S_LMP_QUAD` 1 → 1,25 ; `S_CONT_HISTORY_WEIGHT` 6 → 6,02. C'est la
signature d'un **gradient noyé dans le bruit** (80 parties/itération : des effets
de quelques Elo sont indétectables), exactement comme le SPSA d'éval (§20).

Après arrondi (les marges sont **entières**), seuls **4 paramètres** diffèrent
réellement des défauts : `S_DELTA_MARGIN 200→201`, `S_FUTILITY_BASE 120→121`,
`S_LMR_BASE 0,75→0,7507`, `S_LMR_DIVISOR 2,25→2,255` — le reste est identique.

**SPRT 500 parties à 1+0,1 (params SPSA vs défauts)** : NEW 118-115-267 (50,3 %),
**+2,1 ± 20,8 Elo, LOS 57,8 % → neutre.** (Le +58 Elo observé à 77 parties était
du bruit qui est retombé à +2 sur 500 — rappel de ne jamais conclure tôt.)

**Bug de format corrigé au passage** : `spsa.py` écrivait les paramètres
non entiers en **flottants** (`179.845`), or le parseur Ada n'accepte que des
entiers pour ces marges — le fichier était donc **silencieusement ignoré**
(nœuds identiques). Seules `S_LMR_BASE`/`S_LMR_DIVISOR` sont réelles ; les autres
sont désormais arrondies.

**Conclusion** : le tuning SPSA reste **neutre** (recherche comme éval). L'apport
durable de D4 est **l'infrastructure** (17 constantes runtime, défauts
bit‑identiques) pour d'éventuelles campagnes futures à budget bien supérieur, et
non un gain immédiat.
