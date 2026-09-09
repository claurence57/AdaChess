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

## 6. État actuel & chantiers restants

**Validations** : `./bin_bb/adachess_bb --selftest` passe (perft + roque + éval +
recherche + **SEE**). Self-tests et perft ne doivent **jamais régresser**.

**Problèmes / chantiers restants (après `11f33f9`)**
1. **Temps** : les forfaits sous cutechess sont corrigés (recherche interruptible).
   Reste à **confirmer sur des cadences longues** (20+1, plusieurs parties) et à
   **tuner l'allocation** si besoin (constantes en tête d'`adachess_bb.adb`).
2. **Force** : BB tient/bat MB en blitz rapide, mais reste probablement inférieur à
   temps long. Pistes : movegen « légal direct » complet, **fenêtres
   d'aspiration**, extension en échec, historique, book d'ouvertures. (Le **SEE**
   en quiescence est en place depuis `11f33f9` — le tri de la quiescence et des
   captures pourrait encore l'utiliser plus finement.)
3. **Évaluation** : constantes à **tuner** (en tête de `bbchess-eval.adb`), et
   éventuellement colonnes ouvertes/semi-ouvertes explicites pour les tours.

**Commandes utiles (Linux/ovh02)**
```bash
gprbuild -P adachess.gpr   -XMode=release    # MB
gprbuild -P adachess_bb.gpr -XMode=release   # BB
./bin_bb/adachess_bb --selftest              # tests BB
# Mini-match (cutechess-cli) :
cutechess-cli -engine name=BB cmd="$PWD/bin_bb/adachess_bb" proto=xboard dir="$PWD" \
              -engine name=MB cmd="$PWD/adachess" proto=xboard dir="$PWD" \
              -each tc=20+1 -games 2 -maxmoves 80 -pgnout match.pgn
```

**Règle d'or pour la suite** : toute modification (éval, search, movegen) doit garder
les perft/self-tests verts, et toute nouvelle évaluation doit rester **symétrique**
(éval de la position initiale = 0).
