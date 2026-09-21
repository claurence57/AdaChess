#!/usr/bin/env python3
"""SPSA tuner for AdaChess-BB evaluation parameters.

Compares two parameter sets with the *same* binary by wrapping it with
`--params <file>`, so no rebuild is needed. Each iteration perturbs every
tunable parameter simultaneously by +/-c, plays a match between the two
perturbed engines, and nudges the parameters along the measured gradient.
Designed to run for hours (detached); it snapshots the current parameters and
a log every iteration.

Usage:
  python3 scripts/spsa.py [--iterations 50] [--games 200] [--tc 1+0.1]
                          [--binary bin_bb/adachess_bb] [--out /tmp/opencode/spsa]
"""
from __future__ import annotations

import argparse
import math
import random
import re
import shutil
import signal
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OPENINGS = ROOT / "openings" / "openings.epd"
BOOK = ROOT / "books" / "book.bin"

# Curated tunable parameters (material values excluded on purpose).
TUNABLE = [
    "P_BISHOP_PAIR_OP", "P_BISHOP_PAIR_EG",
    "P_MOBILITY_N", "P_MOBILITY_B", "P_MOBILITY_R", "P_MOBILITY_Q",
    "P_ROOK7_OP", "P_ROOK7_EG", "P_ROOK7_KING",
    "P_ROOKOPEN_OP", "P_ROOKOPEN_EG", "P_ROOKSEMI_OP", "P_ROOKSEMI_EG",
    "P_ROOKCONN_OP", "P_ROOKCONN_EG",
    "P_DOUBLED_OP", "P_DOUBLED_EG", "P_ISOLATED_OP", "P_ISOLATED_EG",
    "P_PROTECTED_OP", "P_PROTECTED_EG", "P_OUTSIDE_OP", "P_OUTSIDE_EG",
    "P_SHIELD1", "P_SHIELD2", "P_SHIELD3", "P_OPENFILE", "P_STORM",
    "P_ATK_N", "P_ATK_B", "P_ATK_R", "P_ATK_Q", "P_EXPOSED",
    "P_THREAT_PAWN", "P_THREAT_MINOR",
]

# Pruning margins + LMR log constants only; structural switches (Max_Q_Depth,
# check-extension, History_Max, Null_Red_Div) are deliberately NOT tuned.
TUNABLE_SEARCH = [
    "S_FUTILITY_MARGIN", "S_FUTILITY_BASE", "S_RAZOR_MARGIN",
    "S_ASPIRATION_WINDOW", "S_DELTA_MARGIN", "S_NULL_RED_BASE",
    "S_LMP_BASE", "S_LMP_QUAD", "S_COUNTER_SCORE",
    "S_CONT_HISTORY_WEIGHT", "S_LMR_BASE", "S_LMR_DIVISOR",
]


def dump_params(binary: Path) -> dict[str, float]:
    out = subprocess.run([str(binary), "--dump-params"],
                         capture_output=True, text=True, check=True).stdout
    params = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2:
            # int when possible (exact round-trip), float otherwise (e.g. 7.5E-01)
            try:
                params[parts[0]] = int(parts[1])
            except ValueError:
                params[parts[0]] = float(parts[1])
    return params


def write_params(path: Path, params: dict[str, float]) -> None:
    lines = []
    for k, v in params.items():
        if isinstance(v, float) and not float(v).is_integer():
            lines.append(f"{k} {v:.6g}\n")
        else:
            lines.append(f"{k} {int(round(v))}\n")
    path.write_text("".join(lines))


def make_wrapper(path: Path, binary: Path, params_file: Path) -> None:
    path.write_text(f'#!/bin/sh\nexec "{binary}" --params "{params_file}" "$@"\n')
    path.chmod(0o755)


def score_of_a(output: str) -> float:
    matches = re.findall(r'Score of A vs B: (\d+) - (\d+) - (\d+)', output)
    if not matches:
        raise RuntimeError("score not found; output tail:\n" + output[-800:])
    w, l, d = (int(x) for x in matches[-1])
    return (w + 0.5 * d) / max(1, w + l + d)


def play_match(binary: Path, params_a: Path, params_b: Path, games: int,
               tc: str, work: Path, seed: int) -> float:
    wrap_a = work / "wrap_a.sh"
    wrap_b = work / "wrap_b.sh"
    make_wrapper(wrap_a, binary, params_a)
    make_wrapper(wrap_b, binary, params_b)
    pgn = work / "match.pgn"
    cmd = [
        "cutechess-cli",
        "-engine", "name=A", f"cmd={wrap_a}", "proto=xboard", "dir=/tmp",
        "-engine", "name=B", f"cmd={wrap_b}", "proto=xboard", "dir=/tmp",
        "-each", f"tc={tc}", "-maxmoves", "200",
        "-games", "2", "-rounds", str(max(1, games // 2)), "-repeat",
        "-srand", str(seed),
        "-openings", f"file={OPENINGS}", "format=epd", "order=random",
        "policy=default",
        "-pgnout", str(pgn),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return score_of_a(res.stdout + res.stderr)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--iterations", type=int, default=50)
    ap.add_argument("--games", type=int, default=200)
    ap.add_argument("--tc", default="1+0.1")
    ap.add_argument("--binary", default=str(ROOT / "bin_bb" / "adachess_bb"))
    ap.add_argument("--out", default="/tmp/opencode/spsa")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--a", type=float, default=200.0,
                    help="SPSA a_k numerator (step size); the old hard-coded 6 "
                         "was ~30-100x too small versus integer rounding")
    ap.add_argument("--a-offset", type=float, default=10.0,
                    help="SPSA a_k denominator offset")
    ap.add_argument("--search-only", action="store_true",
                    help="tune only the S_* search params (D4), not the eval P_*")
    args = ap.parse_args()

    if args.search_only:
        TUNABLE[:] = TUNABLE_SEARCH

    rng = random.Random(args.seed)
    binary = Path(args.binary).resolve()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    work = out / "work"
    work.mkdir(exist_ok=True)

    base = dump_params(binary)
    # theta is kept as float so sub-unit SPSA steps accumulate instead of being
    # erased by integer rounding; only the engine-facing files are rounded.
    theta = {k: float(base[k]) for k in TUNABLE if k in base}
    missing = [k for k in TUNABLE if k not in base]
    if missing:
        print(f"warning: tunable params not found: {missing}", file=sys.stderr)
    float_keys = {k for k in theta if isinstance(base[k], float)}

    def step0(k, v):
        return {
            "S_LMR_BASE": 0.06, "S_LMR_DIVISOR": 0.15,
            "S_COUNTER_SCORE": 50_000, "S_HISTORY_MAX": 2_048,
        }.get(k, max(1, int(abs(v)) // 8))

    c0 = {k: step0(k, base[k]) for k in theta}
    lo = {k: (base[k] - 8 * c0[k] if k in float_keys
              else max(0, int(base[k]) - 8 * c0[k])) for k in theta}
    hi = {k: (base[k] + 12 * c0[k] if k in float_keys
              else int(base[k]) + 12 * c0[k]) for k in theta}
    start = dict(theta)

    book_hidden = None
    if BOOK.exists():
        book_hidden = BOOK.with_suffix(f".hidden.{__import__('os').getpid()}")
        shutil.move(str(BOOK), str(book_hidden))

    def restore_book(*_):
        if book_hidden is not None and book_hidden.exists():
            shutil.move(str(book_hidden), str(BOOK))

    signal.signal(signal.SIGTERM, lambda *a: (restore_book(), sys.exit(0)))
    signal.signal(signal.SIGINT, lambda *a: (restore_book(), sys.exit(0)))

    params_a = out / "params_a.txt"
    params_b = out / "params_b.txt"
    log = out / "spsa.log"

    try:
        for k in range(args.iterations):
            ck = {p: c0[p] / (k + 1) ** 0.101 for p in theta}
            ak = args.a / (k + 1 + args.a_offset) ** 0.602
            delta = {p: (1 if rng.random() < 0.5 else -1) for p in theta}

            def perturb(p, s):
                v = theta[p] + s * ck[p] * delta[p]
                v = min(hi[p], max(lo[p], v))
                return v if p in float_keys else round(v)

            plus = {p: perturb(p, +1) for p in theta}
            minus = {p: perturb(p, -1) for p in theta}
            write_params(params_a, plus)
            write_params(params_b, minus)
            r = play_match(binary, params_a, params_b, args.games, args.tc,
                           work, args.seed + k)
            moved = 0.0
            for p in theta:
                grad = (r - 0.5) * delta[p] / ck[p]
                theta[p] = min(float(hi[p]),
                               max(float(lo[p]), theta[p] + ak * grad))
                moved = max(moved, abs(theta[p] - start[p]))
            with log.open("a") as f:
                f.write(f"iter {k:3d} score(+)={r:.3f} max_move={moved:.3f} "
                        f"theta={{{', '.join(f'{p}:{theta[p]:.2f}' for p in theta)}}}\n")
            write_params(out / "params_current.txt", theta)
            print(f"iter {k:3d} score(+)={r:.3f} max_move={moved:.3f}")
    finally:
        restore_book()
    write_params(out / "params_final.txt", theta)
    print(f"done; parameters in {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
