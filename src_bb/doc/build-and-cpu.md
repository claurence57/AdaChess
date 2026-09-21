# Construction et optimisation CPU d'AdaChess-BB

Ce document décrit les **instructions de compilation** réellement utilisées et
l'**historique des optimisations CPU** (le levier de force prouvé du moteur).

## Modes de construction

`adachess_bb.gpr` expose le scénario `Mode` (`release` par défaut, `debug`,
`portable`). Le binaire est écrit dans `bin_bb/adachess_bb`.

```bash
gprbuild -P adachess_bb.gpr -XMode=release    # défaut : POPCNT/BMI2/PEXT, -flto
gprbuild -P adachess_bb.gpr -XMode=portable   # tout x86-64, repli PEXT logiciel
gprbuild -P adachess_bb.gpr -XMode=debug      # assertions (-gnata), sans -gnatp
```

### Commutateurs exacts (GNAT + C)

| Mode | Ada (`Switches ("ada")`) | C (`Switches ("c")`) |
|---|---|---|
| **release** | `-gnat2012 -gnatp -gnatN -O3 -gnatf -gnatep=../src_bb/prep.data -gnateDREL -mpopcnt -mbmi -mbmi2 -flto` | `-O3 -mpopcnt -mbmi -mbmi2 -flto` |
| **portable** | `-gnat2012 -gnatp -gnatN -O3 -gnatf -gnatep=../src_bb/prep.data` | `-O3` |
| **debug** | `-gnat2012 -gnata -g -gnatep=../src_bb/prep.data` | `-O0 -g` |

- `-gnatep=../src_bb/prep.data` + `-gnateDREL` : **préprocesseur intégré** GNAT.
  `prep.data` ouvre la session avec `* -u` (symboles indéfinis = faux) ; `REL`
  n'est défini qu'en `release`, donc `#if REL` sélectionne l'intrinsèque **PEXT**
  BMI2, `#else` le repli logiciel. Un seul binaire porte les deux variantes.
- `-gnatp` supprime les contrôles d'exécution (release/portable) → tout accès aux
  tampons doit être borné explicitement (`BBChess.Text`).
- `-flto` (release, Ada **et** C) : édition de liens inter-unités.
- **portable** retire `-mpopcnt/-mbmi/-mbmi2/-flto` et laisse `REL` indéfini :
  tourne sur **tout x86-64**, avec le repli logiciel PEXT de `bbchess-bits.c`
  (≈ 25 % plus lent). C'est le mode à distribuer pour un CPU ancien.
- **Gotcha** : `release` et `portable` partagent `obj_bb/`. Après une
  construction `portable`, faire `rm -rf obj_bb` avant de rebâtir en `release`
  (et ne jamais comparer `--bench` entre les deux modes sans rebuild propre).

### Alias du nombre de threads

Le nombre de threads Lazy SMP (1 à 16) se règle indifféremment par :

```bash
bin_bb/adachess_bb --threads 4      # argument séparé
bin_bb/adachess_bb -T4              # forme courte
bin_bb/adachess_bb --thread=4       # forme longue
```

Les formes `-T#` / `--thread=#` sont analysées par `BBChess.Text.Thread_Count`
(testée dans `--selftest`) ; toute valeur malformée retombe sur 1. En UCI,
`setoption name Threads value N` reste l'équivalent.

## Historique des optimisations CPU

Sept passes « sans changement de comportement » : l'arbre de recherche à
profondeur fixe est **bit-identique** (mêmes nœuds `--bench`), seule la vitesse
augmente. Détail complet dans `DEVELOPMENT.md` (§25, §30-31, §33, §36-37, §46).

| Passe | Changements principaux | Gain mesuré |
|---|---|---|
| 1 (§25) | PEXT inliné (préprocesseur GNAT), `Make_Move`/movegen, éval | **×1,59** vitesse |
| 2 (§30) | PEXT inliné, make/movegen, éval | −11,9 % instructions |
| 3 (§31) | chemin roi d'abord (movegen), SEE bitboard-only, éval | −12,2 % instructions |
| 4 (§33) | prefetch TT, sécurité roi/pions bitboard, hoists | −6,9 % instructions (×1,08) |
| 5 (§36) | suppression du tableau `Tac`, `Move_Piece` fusionné, `-flto` | −3,1 % instructions, −3,9 % cycles |
| 6 (§37) | entrée de TT 32 → 24 octets | −2,3 % cycles (×1,02) |
| 7 (§46) | `Poll_Time` scindé, test d'échec évité, `Suppress_Initialization` | −0,81 % instructions, −1,47 % cycles |

**Cumul** : ≈ **×2,3** de vitesse (`--bench 11` : ~1 360 → ~3 170 knps ; bench 9
0,56 → 0,25 s). Un SPRT « capstone » (300 parties, 1+0.1) entre le moteur actuel
et la baseline pré-optimisation vaut **+123 ± 31,6 Elo** (LOS 100 %) — le seul
levier de force **démontré** du moteur (§32).

## État : plus de gain facile, mais pas « rien à gagner »

Toutes les micro-optimisations **sûres** (arbre bit-identique) ont été
essayées ; les dernières passes rapportent **< 1 %** et le rendement décroît
nettement. Le profil reste dominé par `Negamax` (~39 %, **attente mémoire** de la
table de transposition), `Positional_Score` (~19 %) et `Generate_Legal_Common`
(~18 %). Les pistes restantes sont **non triviales et risquées** :

- **évaluation incrémentale** (mettre à jour les termes d'éval dans
  `Make_Move`/`Unmake_Move`) — la seule vraie réserve structurelle ;
- **réorganisation profonde du TT** (accès, buckets) — changerait les entrées
  acceptées, donc l'arbre.

Ces pistes exigent de **prouver l'identité** (nœuds `--bench` + éval
byte-identique sur des milliers de positions) et un **SPRT long** (≥ 600-1 000
parties) avant toute adoption. Les micro-ajustements restants rapportent trop
peu pour être distinguables du bruit.
