# Changelog — AdaChess-BB

## Non publié (développement post bb-1.0)

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
