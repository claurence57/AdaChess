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
- **Pions passés par bitboard** : fonction `Passed_Pawns` avec masques
  pré-calculés `Above_Rank`/`Below_Rank` + `Front_Files` (3 colonnes), au lieu de
  la double boucle alliés × ennemis.
- **Doublés / isolés** dérivés de comptages par colonne (`File_Mask`) plutôt que
  de listes de cases ; **pions passés liés** testés sur voisins bitboard.
- Tables `Rank_Mask`, `Above_Rank`, `Below_Rank`, `Front_Files` pré-calculées en
  tête de fichier.

Résultats mesurés contre MB, après les ajouts du chantier 3 complet (colonnes
ouvertes, structure de pions, pions protégés/éloignés, tours connectées, tempo) :
- **blitz 1 s+0,1 s** : BB **5-1-0** (Elo ≈ +280, LOS ≈ 95 %),
- **20+1** : BB **5-0-1** (Elo ≈ +417, LOS ≈ 99 %) — BB domine désormais MB à
  temps long aussi. (Petits échantillons, à confirmer, mais la tendance est très
  nette.)

## 6. État actuel & chantiers restants

**Validations** : `./bin_bb/adachess_bb --selftest` passe (perft + roque + éval +
recherche + **SEE**). Self-tests et perft ne doivent **jamais régresser**. Note :
avec le **tempo**, `Evaluate` n'est plus exactement antisymétrique ; le test de
symétrie porte sur `Static` (départ = 0, miroir ⇒ `-Static`).

**Problèmes / chantiers restants (après les chantiers 2 & 3, cf. § 5.4 / § 5.5)**
1. **Temps** : les forfaits sous cutechess sont corrigés (recherche interruptible) et
   BB tient MB à 20+1 sur un petit échantillon. Reste à **confirmer sur plus de
   parties longues** et à **tuner l'allocation** si besoin (constantes en tête
   d'`adachess_bb.adb`).
2. **Force** : l'historique, les fenêtres d'aspiration et l'extension en échec sont en
   place (BB bat MB en blitz, domine à 20+1). Pistes restantes : movegen « légal
   direct » complet, **book d'ouvertures**, et l'usage du **SEE** pour trier plus
   finement la quiescence et les captures.
3. **Évaluation** : le chantier 3 est complet (§ 5.5) — colonnes ouvertes, structure
   de pions (doublés/isolés/passés protégés et éloignés), tours connectées, tempo,
   accélérations bitboard. Reste un **tuning fin des constantes** (tête de
   `bbchess-eval.adb`) qui demanderait un tuner automatique (ex. texel / gradient
   descent), des **outposts** (cases fortes) pour C/F, puis l'évaluation
   **incrémentale** (#9, l'éval reste ~50 % du temps de recherche même optimisée).

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
