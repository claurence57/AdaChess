# NOTES_TUNING — recherche, quiescence, évaluation (audit et deltas)

Ce document répond au prompt « amélioration AdaChess, chantiers 1‑3 ». Il recense,
pour chaque chantier, **ce qui existait déjà**, **ce qui a été ajouté**, et **ce
qui a déjà été testé** (avec résultats). Règle appliquée : ne rien réimplémenter
qui existe, ne mesurer un delta qu'au **SPRT** (une réduction de nœuds **ne
prouve pas** un gain de force — cf. §28 du journal : LMR‑killer réduisait les
nœuds et perdait ~35 Elo).

## CHANTIER 1 — Recherche (`src_bb/bbchess-search.adb`)

| Élément demandé | État avant intervention | Action |
|---|---|---|
| Null move pruning (R adaptatif, zugzwang, gardes) | **Existant**, mais **R fixe = 2** ; garde zugzwang `Has_Non_Pawn` déjà présente ; désactivé en échec et sous `Depth < 3` | **AJOUTÉ : R adaptatif `R = 3 + Depth/4`** |
| Late Move Reductions (table log‑log, re‑recherche, exclusions) | **Existant** : table `Compute_LMR` (`0.75 + ln(D)·ln(M)/2.25`), re‑recherche pleine sur fail‑high réduit, exclut captures/promotions/échecs ; le coup TT est trié en tête → non réduit | rien |
| Futility + Razoring (marges 100/200/300) | **Existant** : reverse‑futility (`Futility_Margin=180`), futility par coup (`Futility_Base=120`), razoring (`Razor_Margin=300` × profondeur) | rien |

**Delta retenu (commit `36aff42`)** — `Null_Reduction := 2` remplacé par
`N_Reduction := 3 + Depth/4` (division entière), avec clamp explicite pour que la
profondeur enfant reste un `Natural` valide. Gardes conservées : `Depth >= 3`,
`not In_Check`, `Has_Non_Pawn`, fenêtre `(-B, -B+1)`.

- Nœuds : `--bench 9` 801 778 → **593 786 (−25,9 %)** ; `--bench 11`
  2 618 135 → **1 585 577 (−39,4 %)**.
- **SPRT 300 (1+0.1) vs HEAD : +18,5 ± 28,9 Elo, LOS 89,6 % → positif.**
- Gates : `--selftest` vert, perft 1→5 identique, partie complète sans coup
  illégal, `portable` vert.

## CHANTIER 2 — Quiescence (`src_bb/bbchess-search.adb`)

| Élément demandé | État avant intervention | Action |
|---|---|---|
| Stand‑pat + delta pruning (~200 cp) | **Existant** : stand‑pat (hors échec), `Delta_Margin = 200` + valeur de la victime | rien |
| Élaguer SEE < 0 (sauf en échec) | **Existant** : `Static_Exchange_Value (...) < 0` hors échec | rien |
| Évasions complètes en échec | **Existant** : `Generate_Legal_Moves` si `In_Check`, mat si 0 coup | rien |
| Borner la profondeur de quiescence | **ABSENT** (récursion non bornée) | **AJOUTÉ : `Max_Q_Depth = 8`** |

**Delta retenu (commit `f4437fc`)** — compteur de profondeur propre à la
quiescence (`QDepth`), propagé aux appels (`Negamax` à `Depth=0`, chemin de
razoring, récursion `QDepth+1`). Au plafond :
- **hors échec** → retourne le stand‑pat (borné par alpha) ;
- **en échec** → génère **toutes** les évasions et note chacune statiquement
  (sans récursion) : jamais d'éval statique d'une position en échec, mat/joueur
  pat conservés.

- Nœuds : `--bench 9` 801 778 → **750 402 (−6,4 %)** ; `--bench 11`
  2 618 135 → **2 043 401 (−21,9 %)**.
- **SPRT 300 (1+0.1) vs HEAD : +15,1 ± 29,7 Elo, LOS 84,0 % → positif.**
- Gates : `--selftest` vert, perft 1→5 identique, mat‑en‑2 détecté
  (`99997/99995/99999` identiques à l'ancien), self‑play depth 4 propre,
  `portable` vert.

**Effet combiné** des deux deltas (SPRT 300 vs HEAD) : **+10,4 ± 29,4 Elo,
LOS 75,7 % → positif** (subadditif : les deux élags portent sur des lignes
proches ; chaque delta reste individuellement positif).

## CHANTIER 3 — Évaluation (`src_bb/bbchess-eval.adb`)

| Élément demandé | État | Action |
|---|---|---|
| Éval « tapered » MG/EG par phase | **Existant** : `Tapered_Score_Type`, `Game_Phase`, `Blend` (interpolation linéaire) | rien |
| Outil de Texel tuning (EPD + résultats, descente locale, K) | **Déjà fait autrement** : `scripts/tune.py` (python‑chess) + `scripts/gen_dataset.py`, cible via `--eval-fens`/`--params` | rien à ajouter |

**Résultat déjà connu (journal §21)** : le tuning d'éval à grande échelle
(dataset Lichess CC0) a été **négatif** — −147 Elo (premier essai) puis −38 Elo
(après correction) → **rejeté**. Le SPSA d'éval a également été **neutre**
(§20 : 2 runs + revalidations + SPRT étendu 600 → +0,6 Elo, LOS 52 %).

Conclusion : conformément au journal, le **seul levier de force démontré** sur ce
moteur reste la **vitesse CPU** (§29‑37, cumul ≈ ×2,3 ⇒ ≈ +140 Elo). Les gains
de recherche ci‑dessus sont modestes mais réels et validés par SPRT.

## Validation (ordre demandé)

1. **Compilation propre** : `gprbuild -P adachess_bb.gpr -XMode=release` sans
   nouvel avertissement ; `portable` également.
2. **Self‑tests** : `--selftest` = `all self tests OK`.
3. **Perft** : profondeurs 1→5 (20/400/8902/197281/4865609) **identiques** avant
   et après (la recherche ne touche pas au movegen).
4. **Matchs de non‑régression** : SPRT 300 (1+0.1) par delta et combiné, vs HEAD,
   via `scripts/sprt.sh` (cutechess-cli), livre ouvertures.epd. Aucun run n'est
   resté « à faire ».

## Reproductibilité

- Graine SPRT : `7` ; cadence `1+0.1` ; ouvertures `openings/openings.epd`
  (les deux couleurs).
- Binaires hors dépôt : `/tmp/opencode/adachess_bb_nmp_r`,
  `/tmp/opencode/adachess_bb_qbound` ; patches `nmp_r.patch`, `qbound.patch`.

## Chantier solidité / propreté / performance (P0-P7)

Réalisé en **2026-09-22** sur la base `d2c8b4e` (v2.0) : nettoyage C, invariant
`Squares`, avertissements (`-gnatwa` en debug), `BBChess.Piece_Values`,
SEE itérative, factorisation (`Pin_Mask`, `Tunable`) et `Cont_History` 16 bits.
Protocole, résultats et écarts assumés dans **`CHANGELOG_TECHNIQUE.md`** ;
résumé dans `DEVELOPMENT.md` §48. Aucun paramètre d'éval ou de recherche n'a été
retuné : gates identiques (perft, `--bench` 496 570 / 1 434 292, `--selftest`).
