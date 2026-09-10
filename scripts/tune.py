#!/usr/bin/env python3
"""Texel-style automatic tuner for the AdaChess-BB evaluation.

Coordinate descent over the scalar evaluation parameters. A change is kept
only when it improves the mean squared error on both the training set and a
held-out validation set, which limits overfitting.

Usage: tune.py [DATASET] [--rounds N] [--out FILE] [--val-every N]
"""

import argparse
import os
import subprocess
import sys

ENGINE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "bin_bb", "adachess_bb"))
K = 1.13  # sigmoid scaling (centipawns -> [0,1])


def load_dataset(path):
    results = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            _, _, r = line.rpartition(";")
            results.append(float(r))
    return results


def read_params():
    out = subprocess.run([ENGINE, "--dump-params"], capture_output=True,
                         text=True, check=True)
    params = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2:
            params[parts[0]] = int(parts[1])
    return params


def write_params(params, path):
    with open(path, "w") as f:
        for name, value in params.items():
            f.write(f"{name} {value}\n")


def mse(evals, idx):
    total = 0.0
    for i in idx:
        p = 1.0 / (1.0 + 10.0 ** (-K * evals[i] / 400.0))
        total += (results[i] - p) ** 2
    return total / len(idx)


def evaluate(params, dataset, tmp):
    write_params(params, tmp)
    out = subprocess.run([ENGINE, "--eval-fens", dataset, "--params", tmp],
                         capture_output=True, text=True, check=True)
    evals = [int(x) for x in out.stdout.split()]
    if len(evals) != len(results):
        raise RuntimeError(f"eval count mismatch: {len(evals)} != {len(results)}")
    return mse(evals, train_idx), mse(evals, val_idx)


def initial_step(name):
    if name in ("P_PAWN", "P_KNIGHT", "P_BISHOP", "P_ROOK", "P_QUEEN"):
        return 20
    if name.startswith("P_ATK") or name in ("P_EXPOSED", "P_OPENFILE",
                                            "P_PROTECTED_OP", "P_PROTECTED_EG"):
        return 5
    return 3


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dataset", nargs="?", default="/tmp/opencode/dataset2.txt")
    ap.add_argument("--rounds", type=int, default=6)
    ap.add_argument("--out", default="/tmp/opencode/tuned2.txt")
    ap.add_argument("--val-every", type=int, default=5)
    args = ap.parse_args()

    global results, train_idx, val_idx
    results = load_dataset(args.dataset)
    if not results:
        print("empty dataset", file=sys.stderr)
        return 1
    val_idx = list(range(0, len(results), args.val_every))
    val_set = set(val_idx)
    train_idx = [i for i in range(len(results)) if i not in val_set]

    params = read_params()
    tune = [p for p in params if p != "P_PAWN"]
    step = {p: initial_step(p) for p in tune}
    tmp = "/tmp/opencode/_cur_params.txt"

    best_train, best_val = evaluate(params, args.dataset, tmp)
    print(f"initial train={best_train:.6f} val={best_val:.6f}", flush=True)

    for rnd in range(args.rounds):
        improved_any = False
        for name in tune:
            steps = 0
            moved = True
            while moved and steps < 8:
                moved = False
                for sign in (1, -1):
                    cand = dict(params)
                    cand[name] = params[name] + sign * step[name]
                    if cand[name] < 0:
                        continue
                    c_train, c_val = evaluate(cand, args.dataset, tmp)
                    if c_train < best_train - 1e-9 and c_val < best_val - 1e-9:
                        params = cand
                        best_train, best_val = c_train, c_val
                        moved = True
                        improved_any = True
                        steps += 1
                        break
        for name in tune:
            step[name] = max(1, step[name] // 2)
        print(f"round {rnd + 1}: train={best_train:.6f} val={best_val:.6f}",
              flush=True)
        if not improved_any and max(step.values()) <= 1:
            break

    write_params(params, args.out)
    print(f"best train={best_train:.6f} val={best_val:.6f} -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
