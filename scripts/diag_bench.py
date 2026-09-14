#!/usr/bin/env python3
"""Diagnostic position bench for AdaChess-BB.

Instead of a single hand-picked position, this builds a bench of ~40 positions
taken from games BB lost to GNU Chess, each with the move Stockfish would play.
`score` then measures a binary's global success rate (mean loss vs the expected
move, and exact-match rate) -- an objective, multi-position thermometer.

Subcommands:
  build   assemble bench/diag.tsv from PGNs + Stockfish edits
  score   run a binary over the bench and report the success rate

Usage:
  python3 scripts/diag_bench.py build [--pgn F ...] [--depth 12] [--max 40]
  python3 scripts/diag_bench.py score --binary bin_bb/adachess_bb [--depth 14]
"""
from __future__ import annotations

import argparse
import statistics
import sys
from pathlib import Path

import chess
import chess.engine
import chess.pgn

ROOT = Path(__file__).resolve().parent.parent
SF = "/usr/games/stockfish"
DEFAULT_PGNS = [
    "/tmp/opencode/eval_gnu.pgn",
    "/tmp/opencode/eval_gnu_startpos.pgn",
]
VALUE = {chess.PAWN: 1, chess.KNIGHT: 3, chess.BISHOP: 3,
         chess.ROOK: 5, chess.QUEEN: 9}


def phase(board: chess.Board, ply: int) -> str:
    total = sum(v * len(board.pieces(pt, c))
                for pt, v in VALUE.items() for c in (chess.WHITE, chess.BLACK))
    if ply <= 20:
        return "opening"
    if total <= 24:
        return "endgame"
    return "middlegame"


def sf_move_eval(eng, board: chess.Board, depth: int):
    info = eng.analyse(board, chess.engine.Limit(depth=depth))
    pv = info.get("pv")
    move = pv[0] if pv else None
    score = info["score"].pov(board.turn).score(mate_score=100000) / 100.0
    return move, score


def cmd_build(args) -> int:
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 128})
    candidates = []
    for fn in args.pgn:
        p = Path(fn)
        if not p.exists():
            continue
        with p.open(encoding="utf-8", errors="replace") as fh:
            while True:
                game = chess.pgn.read_game(fh)
                if game is None:
                    break
                white, black = game.headers.get("White"), game.headers.get("Black")
                if white == "GNU" or black == "GNU":
                    bb = chess.BLACK if white == "GNU" else chess.WHITE
                elif "BB" in (white, black):
                    bb = chess.WHITE if white == "BB" else chess.BLACK
                else:
                    continue
                res = game.headers.get("Result")
                if res == "1/2-1/2" or (res == "1-0") == (bb == chess.WHITE):
                    continue  # keep only games BB lost
                board = game.board()
                ply = 0
                for mv in game.mainline_moves():
                    if board.turn == bb:
                        best, e_best = sf_move_eval(eng, board, args.depth)
                        after = board.copy()
                        after.push(mv)
                        _, e_after = sf_move_eval(eng, after, args.depth)
                        loss = e_best - (-e_after)
                        if best is not None and mv != best and 1.0 <= loss <= 6.0:
                            candidates.append(
                                (loss, board.fen(), best.uci(),
                                 phase(board, ply), p.name))
                    board.push(mv)
                    ply += 1
    eng.quit()

    candidates.sort(key=lambda t: -t[0])
    per_game: dict[str, int] = {}
    chosen = []
    for loss, fen, best, ph, src in candidates:
        key = f"{src}:{fen.split()[0]}"
        if per_game.get(key, 0) >= 1 and len(chosen) < args.max:
            continue
        if any(c[1] == fen for c in chosen):
            continue
        chosen.append((loss, fen, best, ph, src))
        per_game[key] = per_game.get(key, 0) + 1
        if len(chosen) >= args.max:
            break

    out = ROOT / "bench" / "diag.tsv"
    out.parent.mkdir(exist_ok=True)
    with out.open("w", encoding="ascii") as f:
        f.write("loss\tphase\tsf_best\tfen\n")
        for loss, fen, best, ph, _ in chosen:
            f.write(f"{loss:.2f}\t{ph}\t{best}\t{fen}\n")
    print(f"wrote {len(chosen)} positions to {out}")
    return 0


def _bb_pov_after(eng, board, mv, depth):
    after = board.copy()
    after.push(mv)
    return -sf_move_eval(eng, after, depth)[1]


def cmd_score(args) -> int:
    bench = ROOT / "bench" / "diag.tsv"
    rows = [l.rstrip("\n").split("\t") for l in bench.open() if not l.startswith("loss")]
    eng = chess.engine.SimpleEngine.popen_uci(SF)
    eng.configure({"Threads": 1, "Hash": 128})
    losses, matches = [], 0
    for r in rows:
        _, ph, best, fen = r
        board = chess.Board(fen)
        bb_eng = chess.engine.SimpleEngine.popen_uci(str(Path(args.binary).resolve()))
        bb_eng.configure({"OwnBook": False})
        move = bb_eng.play(board, chess.engine.Limit(depth=args.depth)).move
        bb_eng.quit()
        bb_pov = _bb_pov_after(eng, board, move, 14)
        b = chess.Board(fen)
        exp = chess.Move.from_uci(best)
        exp_pov = _bb_pov_after(eng, b, exp, 14)
        losses.append(max(-10.0, min(10.0, exp_pov - bb_pov)))
        if move == exp:
            matches += 1
    eng.quit()
    print(f"positions: {len(rows)}  exact match: {matches}/{len(rows)} "
          f"({100*matches/len(rows):.0f}%)")
    print(f"mean loss vs Stockfish best: {statistics.mean(losses):+.2f} pawns "
          f"(median {statistics.median(losses):+.2f}, capped at +-10)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("--pgn", nargs="*", default=DEFAULT_PGNS)
    b.add_argument("--depth", type=int, default=12)
    b.add_argument("--max", type=int, default=40)
    b.set_defaults(func=cmd_build)
    s = sub.add_parser("score")
    s.add_argument("--binary", default=str(ROOT / "bin_bb" / "adachess_bb"))
    s.add_argument("--depth", type=int, default=14)
    s.set_defaults(func=cmd_score)
    args = ap.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
