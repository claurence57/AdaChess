#!/usr/bin/env python3
"""Build a Texel-tuning dataset from PGN files.

Each output line is "FEN;result" where result is from White's point of view
(1.0 win, 0.5 draw, 0.0 loss). Positions are sampled every 4 plies, skipping
the opening (first 8 plies).

Usage: gen_dataset.py OUT.txt [PGN ...]
"""

import sys
import glob
import chess
import chess.pgn


def main():
    if len(sys.argv) < 2:
        print("usage: gen_dataset.py OUT.txt [PGN ...]", file=sys.stderr)
        return 1
    out_path = sys.argv[1]
    files = sys.argv[2:] or sorted(glob.glob("/tmp/opencode/*.pgn"))

    results = {"1-0": 1.0, "0-1": 0.0, "1/2-1/2": 0.5}
    n = 0
    with open(out_path, "w") as out:
        for fn in files:
            try:
                with open(fn) as f:
                    while True:
                        game = chess.pgn.read_game(f)
                        if game is None:
                            break
                        r = results.get(game.headers.get("Result", "*"))
                        if r is None:
                            continue
                        board = game.board()
                        ply = 0
                        for move in game.mainline_moves():
                            board.push(move)
                            ply += 1
                            if ply < 8 or ply % 4 != 0:
                                continue
                            out.write(f"{board.fen()};{r}\n")
                            n += 1
            except Exception as exc:  # noqa: BLE001
                print(f"skip {fn}: {exc}", file=sys.stderr)

    print(f"positions: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
