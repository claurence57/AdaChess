# Changelog — AdaChess-BB

## Non publié (développement post bb-1.0)

> Les entrées **Phase 0/1**, **Phase 2**, **Phase 4a (threats)** et **livre
> Polyglot** ci-dessous ont été développées avec l'agent IA **Sisyphus**
> (OhMyOpenCode) sous **OpenCode**, modèle `deepseek/deepseek-v4-flash`
> (voir `DEVELOPMENT.md` §11). Les entrées plus anciennes (Performance, M1/M2,
> UCI, etc.) sont antérieures.

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
