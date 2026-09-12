#!/usr/bin/env python3
"""Generate a balanced opening suite (EPD) for A/B and SPRT testing.

Why: cutechess-cli picks starting positions from an opening file. Using a suite
instead of playing every game from the initial position 1) decorrelates the
games (SPRT assumes independent samples) and 2) removes the "both engines play
the same first 10 moves" bias, which otherwise dominates the score.

The suite is deliberately shallow (4-6 plies) so the engines still have to play
real chess, and it spans the main openings so neither side is forced into a
single tree. Each line is played from the initial position with python-chess;
the resulting position (4-field FEN, i.e. EPD) is emitted.

Output: openings/openings.epd  (committed; regenerate with this script)

Usage: python3 scripts/gen_openings.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import chess

# Mainline openings in SAN, 4-6 plies each. Curated (not exhaustive): the goal
# is diversity + balance, not theory. python-chess validates every move, so an
# illegal line aborts loudly instead of producing a bad position.
LINES: list[str] = [
    # --- 1.e4 e5 ---
    "e4 e5 Nf3 Nc6 Bc4 Bc5 c3 Nf6",                 # Italian, Giuoco Pianissimo
    "e4 e5 Nf3 Nc6 Bc4 Bc5 b4 Bxb4 c3 Ba5",         # Evans Gambit
    "e4 e5 Nf3 Nc6 Bc4 Nf6 d3 Be7 O-O O-O",         # Two Knights, quiet
    "e4 e5 Nf3 Nc6 Bc4 Nf6 Ng5 d5 exd5 Na5",        # Two Knights, main line
    "e4 e5 Nf3 Nc6 Bb5 a6 Ba4 Nf6 O-O Be7",         # Ruy Lopez, Morphy
    "e4 e5 Nf3 Nc6 Bb5 Nf6 d3 Bc5 c3 O-O",          # Ruy Lopez, Berlin
    "e4 e5 Nf3 Nc6 Bb5 a6 Bxc6 dxc6 O-O f6",        # Ruy Lopez, Exchange
    "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Bc5 Be3 Qf6 c3 Nge7",  # Scotch
    "e4 e5 Nf3 Nc6 d4 exd4 Nxd4 Nf6 Nxc6 bxc6 e5 Qe7", # Scotch, Mieses
    "e4 e5 Nf3 Nf6 Nxe5 d6 Nf3 Nxe4 d4 d5 Bd3 Be7",    # Petroff
    "e4 e5 f4 exf4 Nf3 g5 Bc4 Bg7 h4 h6",           # King's Gambit, Kieseritzky
    "e4 e5 f4 d5 exd5 exf4 Nf3 Nf6",                # King's Gambit declined
    "e4 e5 Nc3 Nf6 f4 d5 fxe5 Nxe4 Nf3 Be7",        # Vienna
    # --- Sicilian ---
    "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 a6",         # Najdorf
    "e4 c5 Nf3 d6 d4 cxd4 Nxd4 Nf6 Nc3 g6",         # Dragon
    "e4 c5 Nf3 e6 d4 cxd4 Nxd4 Nc6 Nc3 Qc7",        # Taimanov
    "e4 c5 Nf3 Nc6 d4 cxd4 Nxd4 Nf6 Nc3 e5 Ndb5 d6",  # Sveshnikov
    "e4 c5 Nf3 e6 d4 cxd4 Nxd4 a6 Bd3 Nf6 O-O d6",  # Kan
    "e4 c5 Nc3 Nc6 g3 g6 Bg2 Bg7 d3 d6",            # Closed Sicilian
    "e4 c5 c3 Nf6 e5 Nd5 d4 cxd4 Nf3 Nc6",          # Alapin
    "e4 c5 Nf3 d6 Bb5+ Bd7 Bxd7+ Qxd7 O-O Nc6",     # Moscow
    # --- French ---
    "e4 e6 d4 d5 Nc3 Nf6 e5 Nfd7 f4 c5 Nf3 Nc6",    # Steinitz
    "e4 e6 d4 d5 Nc3 Bb4 e5 c5 a3 Bxc3+ bxc3 Ne7",  # Winawer
    "e4 e6 d4 d5 Nd2 Nf6 e5 Nfd7 Bd3 c5 c3 Nc6",    # Tarrasch
    "e4 e6 d4 d5 exd5 exd5 Nf3 Nf6 Bd3 Bd6",        # Exchange
    # --- Caro-Kann ---
    "e4 c6 d4 d5 Nc3 dxe4 Nxe4 Bf5 Ng3 Bg6 h4 h6",  # Classical
    "e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5",             # Advance
    "e4 c6 d4 d5 exd5 cxd5 Bd3 Nc6 c3 Nf6",         # Exchange
    # --- Others 1.e4 ---
    "e4 d5 exd5 Qxd5 Nc3 Qa5 d4 Nf6 Nf3 c6",        # Scandinavian
    "e4 d6 d4 Nf6 Nc3 g6 Nf3 Bg7 Be2 O-O",          # Pirc
    "e4 g6 d4 Bg7 Nc3 d6 Nf3 Nf6 Be2 O-O",          # Modern
    "e4 Nf6 e5 Nd5 d4 d6 Nf3 g6 Bc4 Nb6",           # Alekhine
    "e4 Nc6 Nf3 d6 d4 Nf6 Nc3 g6",                  # Nimzowitsch
    "e4 e5 Nf3 Nc6 Bc4 Nd4 Nxd4 exd4 O-O Ne7",      # Blackburne Shilling
    # --- 1.d4 d5 ---
    "d4 d5 c4 e6 Nc3 Nf6 Bg5 Be7 e3 O-O",           # QGD, Orthodox
    "d4 d5 c4 e6 Nf3 Nf6 Nc3 Be7 Bf4 O-O",          # QGD, quiet
    "d4 d5 c4 c6 Nf3 Nf6 Nc3 dxc4 a4 Bf5",          # Slav
    "d4 d5 c4 c6 Nc3 Nf6 e3 e6 Nf3 Nbd7",           # Semi-Slav
    "d4 d5 c4 dxc4 Nf3 Nf6 e3 e6 Bxc4 c5",          # Queen's Gambit Accepted
    "d4 d5 c4 e5 dxe5 d4 Nf3 Nc6",                  # Albin Counter-Gambit
    "d4 d5 c4 Nc6 Nf3 Bg4 cxd5 Bxf3 gxf3 Qxd5",     # Chigorin
    "d4 d5 Nf3 Nf6 c4 e6 Nc3 Be7 Bg5 O-O",          # transposition QGD
    # --- Indian defences ---
    "d4 Nf6 c4 e6 Nc3 Bb4 e3 O-O Bd3 d5 Nf3 c5",    # Nimzo-Indian
    "d4 Nf6 c4 e6 Nf3 b6 g3 Bb7 Bg2 Be7 O-O O-O",   # Queen's Indian
    "d4 Nf6 c4 g6 Nc3 Bg7 e4 d6 Nf3 O-O Be2 e5",    # King's Indian
    "d4 Nf6 c4 g6 Nc3 d5 cxd5 Nxd5 e4 Nxc3 bxc3 Bg7",  # Grünfeld
    "d4 Nf6 c4 e6 Nf3 Bb4+ Bd2 Qe7 g3 O-O",         # Bogo-Indian
    "d4 Nf6 c4 c5 d5 b5 cxb5 a6 bxa6 Bxa6",         # Benko Gambit
    "d4 Nf6 c4 e6 g3 d5 Bg2 Be7 Nf3 O-O O-O dxc4",  # Catalan
    "d4 Nf6 Nf3 e6 c4 b6 g3 Bb7 Bg2 Be7",           # Queen's Indian, fianchetto
    # --- Other 1.d4 ---
    "d4 f5 g3 Nf6 Bg2 e6 Nf3 Be7 O-O O-O",          # Dutch, Classical
    "d4 f5 c4 Nf6 Nc3 e6 Nf3 d5 e3 c6",             # Dutch, Stonewall
    "d4 f5 e4 fxe4 Nc3 Nf6 g4 d5",                  # Dutch, Staunton
    "d4 Nf6 c4 c5 d5 e6 Nc3 exd5 cxd5 d6 e4 g6",    # Modern Benoni
    "d4 c5 d5 Nf6 Nc3 e6 e4 exd5 exd5 d6",          # Benoni
    "d4 Nc6 d5 Ne5 e4 Ng6 f4 e6",                   # Nimzowitsch
    # --- Flank / Réti / English ---
    "Nf3 d5 c4 e6 g3 Nf6 Bg2 Be7 O-O O-O",          # Réti
    "Nf3 Nf6 c4 c5 Nc3 Nc6 g3 g6 Bg2 Bg7",          # English, Four Knights
    "c4 e5 Nc3 Nf6 Nf3 Nc6 g3 d5 cxd5 Nxd5",        # English, Four Knights
    "c4 c5 Nf3 Nf6 d4 cxd4 Nxd4 e5 Nb5 d5",         # English, symmetrical
    "c4 Nf6 Nc3 e6 Nf3 d5 e3 Be7 b3 O-O",           # English, Hedgehog
    "c4 e6 Nc3 d5 d4 Nf6 Nf3 Be7",                  # English/QGD
    "f4 d5 Nf3 g6 e3 Bg7 Be2 Nf6 O-O O-O",          # Bird
    "g3 d5 Bg2 e5 d3 Nf6 Nf3 Nc6",                  # King's Indian Attack
    "b3 e5 Bb2 Nc6 e3 Nf6 Bb5 Bd6",                 # Larsen
    "Nc3 d5 d4 Nf6 Bf4 a6 e3 e6",                   # Dunst (BB's old 1.Nc3)
]

REPO_ROOT = Path(__file__).resolve().parent.parent
OUT = REPO_ROOT / "openings" / "openings.epd"


def main() -> int:
    seen: set[str] = set()
    positions: list[str] = []
    for i, line in enumerate(LINES, 1):
        board = chess.Board()
        try:
            for token in line.split():
                board.push_san(token)
        except ValueError as exc:
            print(f"ERROR line {i}: {line!r}: {exc}", file=sys.stderr)
            return 1
        epd = " ".join(board.fen().split()[:4])  # ignore halfmove/fullmove
        if epd in seen:
            continue
        seen.add(epd)
        positions.append(epd)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(positions) + "\n", encoding="ascii")
    print(f"Wrote {len(positions)} unique openings to {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
