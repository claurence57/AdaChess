# CHANGELOG_TECHNIQUE — solidité, propreté, performance (P0-P7)

Chantier **solidité / propreté / performance** (pas de retuning, pas de changement
d'heuristique). Référence : `DEVELOPMENT.md` §48. Base : `d2c8b4e` (v2.0).
Toutes les validations sont faites avec le **filet perft** et le gate
**arbre bit-identique** ci-dessous.

## Filet de sécurité (identique à chaque commit)

| Gate | Valeur attendue | Résultat |
|---|---|---|
| perft 1→5 | 20 / 400 / 8902 / 197281 / 4865609 | **exact** |
| `--bench 9` | **496 570** nœuds | **exact** |
| `--bench 11` | **1 434 292** nœuds | **exact** |
| `--selftest` | `all self tests OK` | **vert** (release, portable, debug) |
| `--dump-params` | md5 `f79ae683bee20ce9cf3737a1aaf77a07` | **byte-identique** |

## P0 — nettoyage build (fonctions C mortes)

**La proposition d'origine (« supprimer `bbchess-bits.c` ») était fausse** et n'a
pas été suivie : `bb_pext` y est **utilisé par le build `portable`**
(`bbchess-attacks.adb`, branche `#else` de `#if REL`). Supprimer le fichier
aurait cassé `-XMode=portable`.

Retiré : `bb_popcountll` et `bb_ctzll`, **réellement mortes** (Ada importe
`__builtin_popcountll`/`__builtin_ctzll` directement dans `bbchess-board.adb`).
Preuve : `grep -rn "bb_popcountll\|bb_ctzll" src_bb/` → vide. En-tête du fichier
réécrit (seul le repli PEXT portable y vit). `adachess_bb.gpr` inchangé.

## P1 — invariant `Position.Squares`

`Move_Piece` n'efface pas `Squares (From)`. **Ce n'est pas un bug** : `Remove_Piece`
ne l'efface pas non plus, `Squares` n'est **lu** que dans `Piece_At` après un test
`All_Occ`, et `Piece_Type` n'a pas de valeur « vide » → y écrire `Empty` dans le
seul `Move_Piece` aurait créé une **incohérence**.

Action retenue : invariant **documenté** sur `Square_Piece_Array` (valide seulement
si la case ∈ `All_Occ` ; lecteurs doivent tester `All_Occ` d'abord) + `pragma Assert`
dans `Move_Piece` (source occupée, `To /= From`). Release = `-gnatp`, les asserts y
disparaissent ; debug (`-gnata -gnatVa`) les exécute → selftest vert, jamais déclenchés.

## P2 — avertissements (build debug uniquement)

`adachess_bb.gpr`, mode `debug` : ajout de **`-gnatwa`** et **`-gnatVa`** (le second
a été conservé car il ne casse rien, contrairement à l'attente prudente).
Release/portable **inchangés**.

**38 avertissements → 0.** Tous corrigés, aucun masqué :

| Catégorie | Nombre | Correction |
|---|---|---|
| `with`/`use` inutiles en spec | 18 | déplacés spec → body (sans effet : `use` non transitif) |
| entités mortes (`Flag_Array`, `Cap_Color`, eval `B`, TT `Bound/Depth/Have_TT`) | 6 | supprimées |
| variables pouvant être constantes | 9 | `constant` |
| with/use redondants | 3 | supprimés |
| faute de commentaire | — | corrigée |

Journal : 38 (avant) → 0 (après). **Aucun faux positif restant.**

## P3 — `BBChess.Piece_Values` (fin du doublon `Kind_Value`)

Deux `Kind_Value` aux sémantiques **différentes** coexistaient :
`search.adb` (Roi = 0, ordonnancement/MVV-LVA) et `see.adb` (Roi = 10 000).

Nouveau paquet `BBChess.Piece_Values` :
- **`Ordering_Value`** (Roi = 0) — ordonnancement, victime en quiescence ;
- **`SEE_Value`** (Roi = 10 000) — SEE.

Dépend uniquement de `BBChess.Pieces` + `BBChess.Eval` (`Score_Type`), sans cycle.
Doublons locaux supprimés ; 5 sites de recherche → `Ordering_Value`, 5 sites SEE →
`SEE_Value`. Valeurs numériques **identiques**.

## P4 — performance SEE (itérative)

`Exchange` déroulée : **une passe de génération avant + un repli arrière** au lieu de
la récursion. Le masque d'épingle est **toujours** recalculé par pas via `Weakest`
(comme la récursion) : le patch incrémental a été **volontairement écarté** car non
prouvablement identique quand des pièces quittent le plateau.

**Preuve d'équivalence** : paquet de référence temporaire (ancien SEE récursif) +
parcours d'arbre sur 16 positions → **592 068 345 évaluations, 0 divergence**.

**Benchmark NPS** (10 positions, profondeur 12, 1 thread, min de 7 entrelacés) :

| | NPS moyen |
|---|---|
| avant | 3 026 433 |
| après | 3 033 084 |
| Δ | **+0,22 %** |

Instructions **−0,65 %** (médiane de 9 `perf stat` entrelacés). Effet faible mais
positif, **sans régression** → conservé (pas de revert).

## P5 — factorisation

**(a)** `Pin_Mask_See` (SEE) et `Pin_Mask` (movegen) partageaient la même logique :
nouveau `BBChess.Pin_Mask.Pinned (Occ, King_Sq, Own, Enemy_Rook_Queen,
Enemy_Bishop_Queen)`, appelé par les deux. Vérifié contre une marche de bloqueurs
indépendante sur 10 positions × 2 couleurs → **0 divergence**.

**(b)** Le triplet Set/Load/Dump des paramètres était dupliqué entre `Eval` (`P_*`)
et `Search` (`S_*`) : nouveau `BBChess.Tunable` (`Put` int/réel + `Load_File`
générique). Chaque paquet garde ses propres tables/bornes/défauts.
`--dump-params` **byte-identique** ; `--params` identique sur 5 cas (flottant pour un
entier ignoré, entier pour un réel, noms inconnus, espaces, fichier par défaut).

## P6 — `Cont_History` en 16 bits

**La proposition d'origine (index `6×64×64` pièce×from×to) était sémantiquement
fausse** : le tableau est indexé `(pièce, case d'ARRIVÉE du coup précédent) ×
(pièce, case d'arrivée du courant)`. Changer l'index modifie l'heuristique et donc
l'arbre — non livré.

Variante **strictement équivalente** retenue : mêmes indices `(0..767, 0..767)`,
élément **16 bits** (`Cont_Value is range -16_384 .. 16_384`), clamp ±`History_Max`
inchangé, poids/bonus/indices inchangés. Table **2,25 Mo → 1,13 Mo** (−1 152 Ko de
RSS, mesuré exact).

**Profilage préalable** : la table n'était **pas** un goulot — LLC-miss ~0,6 M pour
3,5 G cycles, taux de miss L1d 1,9 %. Après passage : LLC-miss **−10,7 %**, mais
**aucun gain réel en cycles/temps** (tous les deltas dans le bruit). ⇒ Conservé pour
la **mémoire** (−1,1 Mo) à arbre bit-identique, **pas** comme gain de vitesse.

## P7 — validation globale

- **Perft** : 1→5 exact + Kiwipete (via `--bench`, nœuds inchangés). `--selftest` vert.
- **SMP** (profondeur 14, 1 vs 4 threads, 5 positions) : pas de crash, **scores
  plausibles** (`+31` vs `+24` ; `+13` vs `−8` ; identiques ailleurs). 2 bestmoves
  divergent mono/multi — **attendu en Lazy SMP** (partitionnement différent), pas une
  régression : l'identité mono-thread est garantie par `--bench`.
- **SPRT** 100 parties 10+0.1 (OLD `d2c8b4e` vs NEW HEAD) : **NEW 23-21-56
  (51,0 %), +6,9 ± 45,4 Elo, LOS 61,8 % → neutre** (56 % de nulles). Aucune
  régression : conforme à un chantier solidité/propreté à arbre bit-identique.
## NPS global avant/après

`--bench 11`, min de 7 runs entrelacés : **avant 0,5045 s** vs **après 0,5065 s**
(**−0,4 %**, dans le bruit run-to-run). Aucune régression mesurable ; les chantiers
sont de la solidité/propreté et un gain SEE marginal.

## Non fait / écarts assumés

1. **P0 : `bbchess-bits.c` conservé** (pièce portable indispensable) — seule sa partie morte retirée.
2. **P1 : pas d'écriture d'une valeur « vide »** dans `Squares` (aurait créé une incohérence) — invariant documenté + asserts.
3. **P4 : pas de patch incrémental du masque d'épingle** (non prouvablement identique) — seule la récursion→itération faite.
4. **P6 : index conservé** (l'index proposé changeait l'heuristique) — seule la largeur réduite.
5. Les 5 commits P0→P6 couvrent les 7 chantiers ; **P3, P4 et P5 partagent un commit** (leurs hunks sont entrelacés dans les mêmes fichiers — les séparer exigerait des éditions manuelles fragiles).
