# Changelog — AdaChess-BB

## Non publié (développement post bb-1.0)

> **Développement assisté par IA.** Toutes les entrées ci-dessous (postérieures
> au fork initial) ont été développées **avec l'aide d'agents IA** ; **aucun
> développement n'a été fait manuellement**. Modèle principal : **DeepSeek V4.1
> Flash** ; corrections et compléments apportés par des **prompts générés avec
> Claude** et **Kimi K3**. Outils de travail de base : **opencode** (agent
> *Sisyphus* / OhMyOpenCode) et des **interfaces web**. Voir `DEVELOPMENT.md`
> (note en tête et §11).

### Recherche — Lazy SMP : interblocage, fuite mémoire, sélection du coup (D6)

- **Interblocage** : `setoption name Threads` pendant une recherche faisait
  attendre la barrière de fin un effectif jamais lancé (4→8 en cours de route =
  blocage définitif). L'effectif est désormais **figé au lancement**
  (`Root_Num_Threads`). Voir `DEVELOPMENT.md` §45.
- **Fuite mémoire** : un objet tâche par thread et par recherche n'était jamais
  libéré (~34 kB/recherche à 8 threads) ; il est maintenant récupéré après
  terminaison de la tâche.
- **Sélection du coup** : priorité au résultat **complet du thread primaire**
  (celui qui imprime le PV), repli sur le plus profond des helpers ; le
  `bestmove` ne pouvait auparavant pas correspondre à la dernière ligne `post`.
  Une itération d'aspiration interrompue ne peut plus être rapportée (instantané
  du dernier itéré complet).
- **Identité mono‑thread conservée** : `--bench` 1→12 bit‑identique, `--bench
  9/11` = 496 570 / 1 434 292 exactement, `--selftest` vert, `portable` et
  `release` propres. Scalabilité mesurée : 1,59× à 2 threads, 1,94× à 4,
  plateau à 8 (pas de régression).

### Recherche — 17 constantes exposées en params + tuning SPSA (D4/D4b)

- Marges de recherche (futilité, razoring, aspiration, delta, null, LMP, garde
  d'extension d'échec), ordonnancement (counter‑move, continuation‑history,
  history) et constantes LMR exposées via `--params`/`--dump-params` ; **défauts
  bit‑identiques** (`--bench 9/11` = 496 570/1 434 292).
- `scripts/spsa.py` lit les réels, gagne `--search-only`, et ses pas sont
  **normalisés par l'échelle** (corrige une divergence aux bornes). Voir
  `DEVELOPMENT.md` §43.
- **Campagne SPSA recherche (24×80) : neutre** — θ quasi inchangé (< 1 %), et
  `SPRT 500 : +2,1 ± 20,8 Elo, LOS 58 %`. Bug de format corrigé (les marges
  entières écrites en flottant étaient ignorées). Voir `DEVELOPMENT.md` §44.

### Gestion du temps — séparation soft/hard

- Nouveau module pur `BBChess.Clocks` : `soft = restant/movestogo + 0,75×inc`,
  `hard = 2×soft`, **réserve de 0,1 s** (contre 0,05 s) ; `movestogo`/`level`
  lus et décrémentés.
- `Iterative_Search` consulte le **soft** entre itérations (arrêt si
  `écoulé ≥ soft` ou si l'itération suivante dépasserait le soft d'après la
  précédente) et arme le **hard** comme échéance interruptible ; `movetime`/`st`
  inchangés (soft = hard exact).
- Sur-ensemble strict des points d'entrée existants (`go depth/nodes/infinite`
  et recherche à profondeur fixe passent `soft = hard = échéance`) :
  `--bench 9/11` = 496 570 / 1 434 292 nœuds exacts, perft 1→5 exact,
  `--selftest` vert, `portable` vert.
- **SPRT 1 000 part. à 1+0.1 vs HEAD : +49,6 ± 17,6 Elo, LOS 100 % → PREMIER
  `PASS` de la campagne**, 0 forfait au temps. Voir `DEVELOPMENT.md` §41.

### Outillage UCI — Phase 5 (asynchrone)

- La recherche UCI s'exécute désormais dans une **tâche** : `go` rend la main
  immédiatement. `isready` répond `readyok` pendant la recherche, `stop`
  l'interrompt (le `bestmove` suit en < 1 ms) et `quit` arrête la recherche puis
  sort sans blocage.
- Nouveaux modes `go nodes N` (arrêt au plafond de nœuds, pollé dans la
  récursion comme l'échéance) et `go infinite` (borné par `stop`). Aucun
  changement de décision de recherche : `--bench 9/11` = 801 778 / 2 618 135
  nœuds exacts, XBoard inchangé, `go depth 10` OLD vs NEW identique (bestmove et
  nœuds). Mécanisme : seconde demande d'arrêt atomique `Abort_Request` et plafond
  par contexte de recherche, plus un verrou console partagé pour les sorties.

### Recherche — Phase 0/1 (correctness + élagage)

- **Phase 0 (correctness)** : re-recherche pleine de tout fail-high de la
  réduction LMR ; history quadratique (`depth²`, plafonnée) avec **malus** des
  coups calmes qui n'améliorent pas la fenêtre ; nulles terminales (règle des
  50 coups, matériel insuffisant, répétition dès la 2ᵉ occurrence dans la
  ligne) ; **mate-distance pruning**.
- **Phase 1 (élagage)** : LMR en **formule log** (`0.75 + ln(d)·ln(m)/2.25`)
  avec PVS correct (re-recherche pleine sur fail-high réduit), **late move
  pruning**, **futility pruning** des coups calmes, **razoring**, **delta
  pruning** en quiescence.
- Mesures blitz 1 s+0,1 s : arbre ÷ ~11 à profondeur 9 (7,6 M → 0,67 M nœuds),
  A/B self-play ≈ **+61 Elo** vs version d'origine, match contre GNU Chess
  **1-13-6 (≈ -241 Elo)** contre 0-8-2 (≈ -382) avant, soit ≈ **+140 Elo**.
  `--selftest` vert (perft 1→5 inchangé).

### Recherche — Phase 2 (ordonnancement) : essayée puis revertée

- Tentative : history **persistante entre les coups** (table au niveau paquetage,
  partagée) + **countermove** + tri SEE des captures.
- Mesures : self-play non concluant (les trois A/B se contredisaient dans le
  bruit, ±65 Elo), mais **régression nette contre GNU Chess** en gauntlet
  (Phase 1 : 8/30 ; Phase 2 : 2/30). Le tri SEE coûtait en plus ~13 % de knps.
- Décision : **changement annulé**, retour à l'état Phase 1 (bench 668 081
  nœuds identique). Leçon : à 1 s+0,1 s le self-play entre versions voisines est
  trop bruité (~47 % de nulles) ; juger sur le match contre GNU, pas sur l'A/B.

### Évaluation — Phase 4a (threats)

- Terme `threats` ajouté à l'évaluation : pions attaquant des pièces ennemies,
  et pièces mineures (C/F) attaquant tours/dames adverses, bonus proportionnel
  à la valeur de la victime (`P_Threat_Pawn`, `P_Threat_Minor`). Calcul
  bitboard par couleur, donc symétrique (`--selftest` vert, départ = 0).
- Gauntlet vs GNU Chess (30 parties) : Phase 1 ≈ 1,5/30, Phase 4a ≈ 3,5/30 —
  léger mieux, **non significatif** à cette taille d'échantillon.

### Ouvertures — livre Polyglot

- Module `BBChess.Polyglot` : clé Zobrist Polyglot (table de 781 constantes),
  lecture d'un `.bin` standard (16 o/entrée, big-endian, trié) et probe avec
  sélection pondérée + vérification de légalité.
- Intégration driver (XBoard + UCI) : `--book <fichier>`, recherche par défaut
  (`books/book.bin`, répertoire de l'exécutable, `~/.adachess/book.bin`),
  options UCI `OwnBook`/`BookFile`, limite 16 plies, désactivé pour
  `--selftest`/`--bench`/`--eval-fens`.
- `scripts/fetch_book.sh` : télécharge un book **CC0** (Lichess/jja) et
  l'installe en `books/book.bin` (non commité, gitignoré).
- Cross-check de la clé Polyglot ajouté au `--selftest` (startpos, roque,
  en passant capturable/non capturable, milieu de partie).
- Mesure : gauntlet vs GNU, avec book ≈ -352 Elo vs sans book ≈ -382
  (≈ +30 Elo, non significatif à 30 parties) ; l'ouverture `1.Nc3` disparaît
  au profit de e4/d4/Nf3/c4.

### Finales — tablebases Syzygy (Fathom)

- Fathom (C, licence MIT) vendu dans `src_bb/fathom/` + wrapper
  `bbchess-tbwrap.c` + binding Ada `BBChess.Syzygy`.
- Probe WDL exact dans `Negamax` (matériel couvert, sans droits de roque) :
  `TB_Win`/`TB_Loss`/nulle, avec sortie anticipée de l'itération.
- Driver : `--syzygy <dossier>` et UCI `setoption name SyzygyPath`.
- Testé avec les tables 3-pièces : KQvK blanc → score **19999** dès depth 2.
  Inerte sans fichiers `.rtbw`/`.rtbz` (aucun surcoût au bench).
- Limite : pas de DTZ au root (progression en finale gagnée).

### Recherche — singular extensions

- Extension singulière dans `Negamax` : paramètre `Excluded` (défaut
  `Empty_Move`) ; probe à `(Depth-1)/2` en excluant le coup TT, extension de
  +1 ply si les alternatives sont nettement moins bonnes ; TT ni lue ni écrite
  pendant le probe.
- Coût : `--bench 11` +12,5 % de nœuds (+17 % temps). A/B self-play 60 parties :
  **neutre** (PRE +5,8 ± 67,9 Elo, LOS 57 %).
- **SPRT 300 parties** : **neutre** (singular `+4,6 ± 31,3 Elo`, LOS 38,6 %) →
  technique et paramètre `Excluded` **retirés** (commit `f17f217`). Voir
  `DEVELOPMENT.md` §13.

### Évaluation — optimisations mesurées (prompt `/tmp/kk`)

- **B1** : `Defended_By_Pawn` remplacé par un lookup inversé unique
  (`Pawn_Attacks (Opposite (Color), Square) and pions amis`) — simplification à
  sémantique identique, **conservée**.
- **B6** : `pragma Inline` sur les helpers chauds de l'éval (`Both`, `"+"`,
  `Blend`, `PST`, `Piece_Value`, `Own_Row`, `Defended_By_Pawn`) pour activer
  l'inlining frontend (`-gnatN`) — **conservé** (neutre au bench, sans coût).
- **B3** (phase incrémentale) : implémentée et cross-checkée par self-test, mais
  **revertée** — gain non mesurable (bench 11 : médianes 1,80 s avant vs 1,81 s
  après). Le profil `-pg` surestimait `popcount` (instruction unique en build
  optimisé) ; le champ ajouté à `Position`/`Undo` n'était pas justifié.
- Profilage : `perf` bloqué (`perf_event_paranoid=4`), repli `gprof` via `-pg`
  (build distordu ×4,7) → `positional_score` ≈ 20 %, `order` ≈ 10 %.
- Bilan : aucune optimisation d'éval du prompt n'apporte de gain mesurable ;
  l'axe utile reste la qualité de recherche.

### Outillage — harnais SPRT

- **`scripts/sprt.sh`** : test séquentiel (Wald) entre deux binaires, avec bornes
  `elo0`/`elo1`, `alpha`/`beta`, plafond de parties et graine ; verdict
  `PASS`/`FAIL`/`INCONCLUSIVE` (codes 0/1/2). Remplace les A/B à taille fixe
  dont le bruit (±65-80 Elo sur 20-60 parties) rendait les petits gains
  inmesurables (cf. `DEVELOPMENT.md` §9.3).
- **`openings/openings.epd`** (+ `scripts/gen_openings.py`) : 65 ouvertures
  équilibrées (4-6 plis, SAN validé par `python-chess`) ; chaque position est
  jouée dans les deux couleurs (`-repeat`) pour supprimer le biais de couleur
  et décorréler les parties.
- **Ordre des moteurs (corrigé)** : `cutechess-cli` applique le SPRT au
  **premier** moteur ; `sprt.sh` liste désormais **NEW en premier** (sinon un
  NEW nettement meilleur donnait un LLR négatif et les verdicts PASS/FAIL
  sortaient inversés).
- **Reproductibilité** : la recherche temporisée étant non déterministe, la même
  graine ne rejoue pas les mêmes parties ; « prolonger » un SPRT donne un
  échantillon indépendant (voir `DEVELOPMENT.md` §15.4).
- Protocole documenté en `DEVELOPMENT.md` §15.

### Outillage — build portable (sans POPCNT/BMI)

- Nouveau mode `-XMode=portable` dans `adachess_bb.gpr` : mêmes optimisations
  (`-O3 -gnatN`) mais **sans** `-mpopcnt -mbmi -mbmi2`.
- `bbchess-bits.c` : `bb_pext` garde `_pext_u64` si `__BMI2__` est défini,
  sinon repli logiciel (boucle sur les bits du masque) ; `__builtin_popcountll`
  et `__builtin_ctzll` se rabattent sur les routines libgcc.
- Le binaire portable tourne sur **n'importe quel x86-64** (~27 % plus lent :
  `--bench 9` ≈ 1,07 vs 1,46 M knps), arbre identique (780 851 nœuds),
  `--selftest` vert et perft 1→5 inchangé. Le mode `release` est inchangé.

### Évaluation — sécurité du roi : deux tentatives négatives

- **Version forte** : zone 5×5, unités d'attaque pondérées (+ pions), danger
  non linéaire plafonné. Corrige le blunder ciblé (`f6g5` → `f6e6`) mais
  **SPRT vs HEAD ≈ −137 Elo, LOS 99,5 %** → revertée.
- **Version chirurgicale** : zone lointaine ÷2, quadratique plafonné à 400,
  `P_King_Danger = 60`. Corrige aussi le blunder et améliore la calibration
  (biais décision +10 vs +53) mais **SPRT 300 parties ≈ −96 Elo** (HEAD
  +96,2 ± 36,4, LOS 100 %) → revertée.
- Détails et leçon en `DEVELOPMENT.md` §17.
- **Revérification (15/09)** : patch « version forte » reconstruit hors dépôt et
  re-mesuré avec le harnais corrigé (livre neutralisé, NEW en premier) :
  **≈ −124 ± 36 Elo** en 300 parties vs HEAD (LOS 0 %) → le −137 original est
  **confirmé**, ce n'était pas un artefact de livre. Toujours reverté.
  `DEVELOPMENT.md` §17.4.
- **Réplication indépendante** (graine 13, 300 parties) : NEW 32,7 %,
  ≈ **−125,7 ± 36,2 Elo**, LOS 0 % → mesure **reproductible**.

### Recherche — extensions, IID, checks en quiescence (résultats)

- **Extension en échec** : arbre ×2,8 (2,19 M nœuds), ne corrige pas le coup
  ciblé → revertée.
- **Extension « recapture »** : arbre ×3,1 (2,40 M nœuds), ne corrige pas le
  coup ciblé → revertée.
- **IID** : +5 % de nœuds ; SPRT 300 parties = **neutre** (HEAD +6,9 ± 32,5) →
  non retenu.
- **Checks en quiescence** : corrige le coup ciblé mais **+49 % de temps** →
  écarté. Détails en `DEVELOPMENT.md` §18.

### Recherche — ProbCut : essayé puis retiré

- Bloc ProbCut avant l'ordonnancement (coups tactiques de SEE ≥
  `ProbCut_Margin`, `Depth ≥ 5`, jusqu'à 2 coups, recherche réduite de 4 plis en
  fenêtre nulle) : `--bench 9` **−4,6 %** de nœuds mais banc diagnostique
  **dégradé** (16 → 13 coups corrects sur 40).
- **SPRT 300 parties** : ProbCut **+15,1 ± 31,1 Elo** (LOS 82,9 %) →
  INCONCLUSIF. **SPRT 600 parties** (échantillon indépendant) : **−10,4 ± 21,8
  Elo** (LOS 82,6 % pour HEAD) → INCONCLUSIF. Cumul ≈ 0 : **aucun gain démontré**
  → **retiré**. Voir `DEVELOPMENT.md` §22.

### Recherche — multi-cut : essayé puis rejeté

- Variante « passe préliminaire réduite » dans `Negamax` (nœud non‑PV, hors
  échec, `Depth ≥ 6` ; jusqu'à 6 coups sondés à `Depth − 4` en fenêtre nulle ;
  coupure si ≥ 3 dépassent `Beta`). `--selftest` vert, `--bench 9` 801 778 →
  **787 300** nœuds.
- **SPRT 300 parties vs HEAD : NEW 43,0 %, ≈ −49 ± 31 Elo, LOS 0,1 %** →
  régression nette, **non retenu**. Voir `DEVELOPMENT.md` §23.

### Évaluation — outposts : neutre (non retenu)

- Terme outpost (cavalier/fou sur case défendue par un pion et inattaquable par
  les pions ennemis) : `P_Outpost_N = 25`, `P_Outpost_B = 10`, `--selftest` vert.
- **SPRT 300 parties vs HEAD : NEW 49,8 %, ≈ −1 ± 31 Elo, LOS 47 %** → **neutre,
  non retenu**. Voir `DEVELOPMENT.md` §24.

### Recherche — move picker (staged) : neutre (non retenu)

- Picker incrémental (`BBChess.Move_Picker`, sélection partielle O(n)) intégré à
  `Negamax`/`Quiescence`. **A0** (ordre identique) : nœuds `--bench`
  **inchangés** (801 778 / 2 618 135) + debug `--picker-check` « set + ordre
  identiques » (0 mismatch). **A1** (tri SEE) : −18 % de nœuds mais
  **SPRT +5,8 ± 30,4 Elo (LOS 64,6 %) → neutre**. **A2** (counter-move) :
  −16 % de nœuds mais **SPRT +6,9 ± 30,8 Elo (LOS 67,1 %) → neutre**. Aucune
  variante retenue. Voir `DEVELOPMENT.md` §27.

### Recherche — modulation LMR (killer) : négatif (non retenu)

- Premier incrément de la modulation LMR : killer → `R−1` (réduire moins).
  `--bench 9` −5,5 % de nœuds mais **SPRT 300 = NEW 45,0 %, −34,9 ± 29,8 Elo,
  LOS 1,1 %** → régression nette, **non retenu**. Voir `DEVELOPMENT.md` §28.

### Matchs — vs GNU Chess : instabilité de GNU 6.2.7

- Match 2+1, 30 parties, **sans livre des deux côtés** (BB : livre masqué par le
  SPSA ; GNU : `OwnBook = false`) : **BB 3-20-7 = 21,7 %, ≈ −223 ± 134 Elo**,
  0 forfait au temps.
- `GNU Chess 6.2.7` **segfault de façon chronique** (`segfault … in libc.so.6`,
  offset `0x2d0`) et peut faire avorter un match ; **BB n'a jamais planté**.
  Voir `DEVELOPMENT.md` §26.

### Performance — optimisations guidées par perf (×1,59, arbre identique)

- `pragma Inline` des primitives chaudes, `Piece_At` **O(1)** incrémental,
  `Is_Tactical`/pièce capturée calculés une fois dans `Order`, `Move_List` sans
  initialisation, fusion éval mobilité / sécurité‑roi / threats, `ctz`/`popcount`
  en intrinsèques.
- `--bench 9` 0,517 → 0,325 s (**×1,59**) et `--bench 11` ×1,60 ; **nœuds
  inchangés** (801 778 / 2 618 135), `--selftest` vert, perft 1→5 inchangé,
  build `portable` vérifié. Voir `DEVELOPMENT.md` §25.

### Performance — validation en force de l'optimisation (×1,59 → +84 Elo)

- SPRT 300 à 1+0.1 (binaire optimisé vs pré-optimisation, livre neutralisé) :
  **NEW 128-57-115 (61,8 %), +83,8 ± 31,2 Elo, LOS 100 %** → le gain CPU **se
  traduit directement en force** (~+84 Elo) : c'est le seul gain majeur de la
  campagne. Voir `DEVELOPMENT.md` §29.

### Performance — optimisation CPU #2 (×1,13, arbre identique)

- **PEXT inliné** (intrinsèque BMI2 via préprocesseur GNAT en `release`, repli
  logiciel en `portable` ; nouveau `src_bb/prep.data`), `Make_Move` (victime
  O(1), Zobrist roque évité), `Movegen` (chemin rapide, génération en place),
  éval (attaques de pions par shifts, scans de roi restreints).
- `--bench 11` **−11,9 % d'instructions** (9,43 → 8,31 G), `--bench 9` ×1,13 ;
  **nœuds identiques** (801 778 / 2 618 135), `--selftest` et `portable` verts.
  SPRT vs opt1 : **+13,9 ± 29,8 Elo (LOS 82 %)**. Voir `DEVELOPMENT.md` §30.

### Performance — optimisation CPU #3 (×1,13, arbre identique)

- **Movegen** (préfixe non-roi sans copie, `King_First`, `Add` inliné), **SEE**
  (copie bitboard-only), **éval** (mobilité scindée, phase, pions), **null-move**
  (copie minimale). `--bench 11` **−12,2 % d'instructions** (8,31 → 7,29 G),
  `--bench 9` 0,326 → 0,274 s ; **nœuds identiques**, éval byte-identique,
  `--selftest`/`portable` verts. SPRT vs opt2 : **+16,2 ± 30,3 Elo, LOS 85 %**.
  Voir `DEVELOPMENT.md` §31.

### Performance — optimisation CPU #4 (×1,08, arbre identique)

- **`Negamax`** (prefetch TT à l'entrée du nœud, `Is_Tactical` hissé), **movegen**
  (`Target_Mask` hissé), **éval** (structure de pions repliée par fichier,
  bouclier/tempête du roi en pur bitboard, `Front_Blockers` Kogge-Stone),
  **quiescence** (partition tactique sautée hors échec).
- `--bench 11` **−6,9 % d'instructions** (7,29 → 6,79 G), ×1,08 en cycles A/B ;
  **nœuds identiques**, éval byte-identique (41 diag + 10 000 aléatoires),
  bestmoves identiques ; `--selftest`/`portable` verts. SPRT vs opt3 :
  **+15,1 ± 29,5 Elo, LOS 84 %**. Voir `DEVELOPMENT.md` §33.

### Bilan — optimisations CPU cumulées (×2,01, +170 Elo)

Trois passes d'optimisation sans changement d'arbre (§29-31). SPRT 300 à 1+0,1
du moteur actuel vs baseline pré-optimisation : **NEW 122-19-86 (72,7 %),
+170,0 ± 36,8 Elo, LOS 100 %, PASS**. `--bench 9` 0,589 → 0,278 s (×2,1).
La 4ᵉ passe (§33) ajoute **×1,08** (cumul ≈ **×2,17**). Re-mesure avec les 4
passes (bench 9 0,561 → 0,264 s, ×2,12) : **NEW 144-42-114 (67,0 %),
+123,0 ± 31,6 Elo, LOS 100 %** — compatible avec les +170, cumul réel vers
**+140 ± 35 Elo**. Voir `DEVELOPMENT.md` §32-33.

### Performance — optimisation CPU #5 (arbre identique)

- **`Negamax` — tableau `Tac` supprimé** : le drapeau « tactique » n'est plus
  transporté dans un troisième tableau à travers le tri par sélection ; il est
  recalculé après le tri (même prédicat), de sorte que seuls `Moves` et `Ord`
  sont permutés. C'est le gain principal.
- **`Make_Move`/`Unmake_Move` — `Move_Piece` fusionné** : le déplacement d'une
  pièce non-promotion se fait en trois XOR (`Bit (From) xor Bit (To)`) au lieu
  d'un `Remove_Piece` + `Put_Piece` (six and/or).
- **LTO** (`-flto`) activé en `release` (Ada et C) ; `Insufficient_Material` et
  `Syzygy.Enabled` inlinés (appelés à chaque nœud).
- `--bench 11` **−3,1 % d'instructions** (6,79 → 6,58 G), A/B entrelacé
  **−3,9 % de cycles** (min de 21 répétitions) ; `--bench 9/11` = **801 778 /
  2 618 135** nœuds exacts, éval byte-identique (41 diag + 10 000 aléatoires),
  perft 1→5 et `Static` inchangés, bestmoves identiques profondeur 8 (40) et
  10 (sous-ensemble), `--selftest` et `portable` verts. Voir `DEVELOPMENT.md`
  §36.

### Performance — optimisation CPU #6 (TT 24 octets, arbre identique)

- **Entrée de table de transposition 32 → 24 octets** : `Depth` porté en 16 bits
  (`TT_Depth_Type`, borné à `Max_Ply`) et membres larges regroupés → table
  32 → 24 Mo, plus proche du L3. Valeurs, condition d'acceptation et politique
  de remplacement **inchangées** → arbre bit-identique.
- A/B entrelacé bench 11 (min de 31 répétitions) : **cycles −2,3 %** (×1,024),
  **instructions −0,1 %** → gain **purement mémoire/cache**. `--bench 9/11` =
  801 778 / 2 618 135 nœuds exacts, éval byte-identique (40 diag + 12 000
  aléatoires), bestmoves identiques d8/d10, `--selftest`/`portable` verts.
  SPRT vs opt5 : **+8,1 ± 28,1 Elo, LOS 71 %**. Voir `DEVELOPMENT.md` §37.

### Recherche — NMP adaptatif et borne de quiescence (adoptées)

- **NMP à réduction adaptative** : `R := 3 + Depth/4` au lieu de `R = 2` fixe
  (gardes `Depth>=3`, hors échec, `Has_Non_Pawn` conservées). Nœuds 801 778 →
  593 786 (−25,9 %) / 2 618 135 → 1 585 577 (−39,4 %) ; **SPRT +18,5 ± 28,9 Elo,
  LOS 90 %**.
- **Borne de quiescence** `Max_Q_Depth = 8` : au plafond, stand‑pat borné alpha
  hors échec, toutes les évasions notées statiquement en échec (mat préservé).
  Nœuds −6,4 % / −21,9 % ; **SPRT +15,1 ± 29,7 Elo, LOS 84 %**.
- Combiné : **+10,4 ± 29,4 Elo, LOS 76 %** (subadditif). Audit complet
  (existant vs ajouté) dans `NOTES_TUNING.md`. Voir `DEVELOPMENT.md` §38.

### Recherche — ordonnancement counter-move + continuation history (gain confirmé)

- **Counter-move** (`Counter (camp,depuis,vers)`, score 800 k) et **continuation
  history 1 ply** (`768×768`, pondérée ×6), tables par thread + `Move_Path` copié
  par valeur (null-move remis à `Empty_Move`). Nœuds `--bench 9` 593 576 →
  496 570 (−16 %) ; `--bench 11` 1 769 154 → 1 434 292 (−19 %).
- **SPRT 1 000 parties à 1+0.1 : +22,3 ± 15,5 Elo, LOS 99,8 %** (IC excluant 0) —
  le gain de recherche le plus net et confirmé de la campagne. Voir
  `DEVELOPMENT.md` §40.

### Corrections — audit Oracle B1-B6 + outillage de match

- **B1** répétition morte sous UCI (`Sync_Game_History` jamais appelé hors XBoard) ;
  **B2** fuite `Stop_Search` après MT→ST (jeu quasi aléatoire) ; **B3** fuite du
  `Search_Context` (~41 Ko/recherche) ; **B4** débordement tampon sous `-gnatp`
  (nouveau `BBChess.Text`) ; **B5** course d'écriture TT sous Lazy SMP (clé
  publiée en dernier).
- **B6** borne quiescence non sound en échec : au plafond, détection du mat puis
  **fail‑low** au lieu d'un score statique ; **SPRT +11,6 ± 28,7 Elo, LOS 79 %**.
- Invariants préservés : `--selftest` vert, perft 1→5 exact, `portable` vert,
  `--bench` bit‑identique pour B1‑B5 (593 601/1 769 496). Deux tests de
  régression ajoutés au `--selftest`.
- **Outillage** : `vs_gnuchess.sh` utilise la même suite d'ouvertures que
  `sprt.sh` et neutralise le livre (l'ancien match partait de startpos → 70 % de
  victoires Blanc). Voir `DEVELOPMENT.md` §39.

### Recherche — modulation du LMR par `improving` (rejetée)

Flag `improving` (éval à 2 plis, même camp) modulant le LMR : arbre réduit
(bench 9 801 778 → 733 011) mais **SPRT 300 : −20,9 ± 28,7 Elo, LOS 8 %** →
**négatif**. Avec la variante killer (§28), la modulation LMR est close.
Voir `DEVELOPMENT.md` §34.

### Outillage — harnais A/B équitable

- `sprt.sh`/`ab.sh` désactivent le livre des deux moteurs pendant le match
  (sinon un binaire de `bin_bb/` utilisait `books/book.bin` et pas l'autre) ;
  contrôle HEAD vs HEAD à 40 parties = ±87 Elo → décisions en 300 parties
  (±33-36). Voir `DEVELOPMENT.md` §15.4.

### Outillage — banc diagnostique et tuner SPSA

- **`scripts/diag_bench.py`** (`build`/`score`) + **`bench/diag.tsv`** : banc de
  40 positions tirées des défaites vs GNU, avec le coup attendu de Stockfish,
  pour mesurer un taux de réussite **global** (baseline HEAD : 28 % de coups
  corrects, +0,33 pion de perte moyenne).
- **`scripts/spsa.py`** : tuner SPSA des paramètres d'éval (deux jeux de
  `--params` sur le même binaire, match A/B, livre neutralisé/restauré).
  Infrastructure validée ; voir `DEVELOPMENT.md` §19-20.
- **Run SPSA complet (16/09) : arrêté car inerte.** Après 27 itérations (~18 h),
  `theta` n'avait pas bougé d'une unité (`a_k` ~30-100× trop petit face à
  l'arrondi entier) ; aucun gain possible, revalidation non lancée. Voir
  `DEVELOPMENT.md` §20.1.
- **Run corrigé (17-18/09)** : `theta` en flottants + `--a` (les pilotes
  confirment que θ bouge). Run 1 (graine 1, 50×200) : **22/35 paramètres
  déplacés**, revalidation SPRT 300 = **+8,1 ± 30,2 Elo, LOS 70,1 % →
  INCONCLUSIF**, **non adopté**. Run 2 (graine 2) en cours. Voir `DEVELOPMENT.md`
  §20.2.
- **Revalidations (18/09)** : run 1 = **+8,1 ± 30,2 Elo (LOS 70,1 %)** ; run 2 =
  **28/35 paramètres, +19,7 ± 30,1 Elo (LOS 90,1 %)** — meilleur signal du projet
  mais **INCONCLUSIF** → **non adoptés** (SPRT PASS requis). **SPRT étendu
  600 part.** : **+0,6 ± 21,8 Elo (LOS 52,1 %) → le +19,7 était du bruit**, effet
  réel ≈ 0. Tuning d'éval automatique (Texel + SPSA) **clos comme non concluant**.
  Voir `DEVELOPMENT.md` §20.3.

### Outillage — tuning d'éval à grande échelle (dataset Lichess)

- `scripts/gen_dataset.py` lit les `.pgn.zst` et accepte `--max`.
- Dataset **100 000 positions (~97 400 distinctes)** depuis Lichess CC0
  (parties humaines variées) ; pipeline Texel (`scripts/tune.py`) validé
  (MSE réduite sur tranche 10k). Validation du jeu tuné **imposée par SPRT
  300 parties** (jamais sur la seule MSE). Voir `DEVELOPMENT.md` §21.
- **Résultat : négatif.** Le jeu tuné (100k positions, 6 rounds) réduit la MSE
  mais **perd ≈ 38 Elo** en SPRT 300 parties vs HEAD → **rejeté**. La MSE reste
  déconnectée de la force à cette échelle.

### Documentation — `src_bb/doc/`

- Nouveau dossier `src_bb/doc/` : 7 fichiers Markdown (français) expliquant les
  principes du moteur — bitboards, évaluation, recherche, finales, ouvertures,
  outillage/tests — avec diagrammes Mermaid et liens Chess Programming Wiki.
  Index dans `src_bb/doc/README.md`.

### Performance
- Harnais `--bench [profondeur]` (8 positions, nœuds/s).
- Intrinsèques bits (`popcnt`/`bsf`) via shim C + `-mpopcnt -mbmi`, inlining
  (`-gnatN`), `pragma Inline` sur les helpers chauds.
- **Zobrist incrémental** dans `Make_Move`, occupancy/couleur incrémentales,
  détection de capture O(1).
- Quiescence en **génération tactique** seule, `Is_Repetition` borné à la
  fenêtre réversible, statut d'échec mis en cache.
- Éval : table plate matériel+PST, zones d'attaque du roi précalculées,
  `Pin_Mask` par rayons/between, **matériel+PST incrémental** (`Position.Material`
  maintenu par Make/Unmake).
- Résultat : ~470 → ~2550 knps à profondeur 9 (×5,5), self-tests verts.

### Génération de coups & table de transposition (M1/M2)
- Tables `Between`/`Line`, pions générés par shifts groupés, **légalité
  directe** (échecs/clouages/roi) sans make/unmake (hors en-passant).
- Coups encodés en 32 bits, **TT à 2 voies avec aging**.
- `--bench 9` ≈ **2,8 M knps** ; perft exact (KiwiPete d1-d3), A/B sans régression.

### Protocole
- **Support UCI** (en plus de XBoard) : `uci`, `isready`, `ucinewgame`,
  `position`, `go` (temps/profondeur), `setoption`, `stop`, `bestmove`.
- Buffer d'entrée porté à 8192 octets (les longues lignes `position ... moves`
  étaient tronquées).

### Outillage
- Constantes d'éval paramétrables (`--dump-params`, `--params`, `--eval-fens`).
- `scripts/gen_dataset.py` et `scripts/tune.py` (tuner Texel). Expérience de
  tuning non concluante sur petit dataset : paramètres par défaut conservés
  (cf. `DEVELOPMENT.md` § 7sexies).

### Recherche & bitboards
- **Lazy SMP** : TT partagée, état de recherche par thread (tâches Ada),
  `--threads N` / UCI `setoption name Threads value N`. +127 Elo à 4 threads.
- **Attaques par PEXT** (BMI2) à la place des magics : démarrage ~1,9 s → ~0,03 s.

### Évaluation
- Sécurité du roi renforcée (zone à distance 2, danger non linéaire, roi
  exposé) — cf. `DEVELOPMENT.md` § 7bis.

## bb-1.0 (2026-09-10)

Première version « figée » d'AdaChess-BB (moteur bitboard en Ada), utilisée
désormais comme **référence** pour les A/B de développement.

### Recherche
- Alpha-bêta negamax + **itération itérative** et **PVS** (root et nœuds).
- **TT** 1 M entrées (Zobrist), ordonnancement hash move → MVV-LVA →
  promotions → killers → **historique**.
- **LMR** léger, **null-move pruning**, **reverse futility**, **extension en
  échec**, **fenêtres d'aspiration**.
- **SEE** en quiescence (pruning des captures perdantes), évasions/mat détectés
  à l'horizon.
- Recherche **interruptible** (deadline pollée) + repli `Quick_Move`.

### Évaluation
- Matériel + **PST**, interpolé ouverture/finale par phase.
- Paires de fous, mobilité, tours (colonnes ouvertes/semi-ouvertes, 7ᵉ,
  connectées), **structure de pions en pur bitboard** (doublés, isolés, passés
  protégés/éloignés), sécurité du roi, activité du roi en finale, **tempo**.
- `Static` symétrique (départ = 0, miroir ⇒ `-Static`) ; symétrie testée.

### Protocole / temps
- XBoard/Winboard : `level`/`time`/`otim`, `st`/`sd`, `ping`, `setboard`,
  `usermove`/`move`. Pas de forfaits sous cutechess.

### Outillage de test
- `--selftest` (perft 1→5, roque, éval/symétrie, SEE, recherche).
- Mini-matchs vs GNU Chess (UCI) et A/B vs référence via `scripts/`.

## Lignes précédentes (développement, non taguées)

Historique complet des chantiers dans `DEVELOPMENT.md` (§ 1 à 6).
