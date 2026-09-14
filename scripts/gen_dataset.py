#!/usr/bin/env python3
"""Build a Texel-tuning dataset from PGN files (plain or .zst).

Each output line is "FEN;result" where result is from White's point of view
(1.0 win, 0.5 draw, 0.0 loss). Positions are sampled every 4 plies, skipping
the opening (first 8 plies). `.pgn.zst` files are decompressed on the fly.

Usage: gen_dataset.py OUT.txt [--max N] [PGN ...]
"""

import argparse
import glob
import io
import subprocess
import sys

import chess
import chess.pgn


def open_pgn(path):
    if path == "-":
        return sys.stdin
    if path.endswith(".zst"):
        proc = subprocess.Popen(["zstd", "-dc", path], stdout=subprocess.PIPE)
        return io.TextIOWrapper(proc.stdout, encoding="utf-8", errors="replace")
    return open(path, encoding="utf-8", errors="replace")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("pgn", nargs="*")
    ap.add_argument("--max", type=int, default=0,
                    help="stop after N positions (0 = no limit)")
    args = ap.parse_args()
    files = args.pgn or sorted(glob.glob("/tmp/opencode/*.pgn"))

    results = {"1-0": 1.0, "0-1": 0.0, "1/2-1/2": 0.5}
    n = 0
    stop = False
    with open(args.out, "w") as out:
        for fn in files:
            try:
                f = open_pgn(fn)
                while not stop:
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
                        if args.max and n >= args.max:
                            stop = True
                            break
            except Exception as exc:  # noqa: BLE001
                print(f"skip {fn}: {exc}", file=sys.stderr)
            if stop:
                break

    print(f"positions: {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
