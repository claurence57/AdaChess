#!/usr/bin/env bash
# SPRT (Sequential Probability Ratio Test) between two AdaChess-BB builds.
#
# SPRT decides game after game between two hypotheses on the *true* Elo gap:
#   H0: NEW is stronger than OLD by less than ELO0   -> FAIL
#   H1: NEW is stronger than OLD by at least ELO1    -> PASS
# It stops as soon as one is accepted (or at the max_games cap), controlling
# the false-positive (alpha) / false-negative (beta) rates. This replaces the
# fixed-length A/B whose +-65-80 Elo noise made small gains unmeasurable.
#
# Every game starts from a position in openings/openings.epd and each opening
# is played twice with colours swapped (-repeat): that removes the colour bias
# and decorrelates the games, which SPRT assumes.
#
# Usage:
#   scripts/sprt.sh [tc] [elo0] [elo1] [max_games] [seed] [old_engine] [new_engine]
#
#   tc          time control (default 1+0.1)
#   elo0, elo1  SPRT bounds in Elo (default 0 and 5)
#   max_games   safety cap, rounded up to an even number (default 2000)
#   old_engine  baseline binary  (default ~/bin/adachess_bb, tag bb-1.0)
#   new_engine  candidate binary (default bin_bb/adachess_bb)
#
# Env overrides: ALPHA (0.05), BETA (0.05), OPENINGS, PROTO (xboard), MAXMOVES (200)
#
# Note: to validate a *patch*, pass the previous build as OLD, e.g.
#   scripts/sprt.sh 1+0.1 0 5 2000 7 /tmp/opencode/adachess_bb_p1 bin_bb/adachess_bb
# Comparing directly to the bb-1.0 reference will PASS instantly (gap ~+300).
set -euo pipefail

TC="${1:-1+0.1}"
ELO0="${2:-0}"
ELO1="${3:-5}"
MAXGAMES="${4:-2000}"
SEED="${5:-7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD="${6:-${HOME}/bin/adachess_bb}"
NEW="${7:-${ROOT}/bin_bb/adachess_bb}"

ALPHA="${ALPHA:-0.05}"
BETA="${BETA:-0.05}"
OPENINGS="${OPENINGS:-${ROOT}/openings/openings.epd}"
PROTO="${PROTO:-xboard}"
MAXMOVES="${MAXMOVES:-200}"

OLD="$(realpath "$OLD")"
NEW="$(realpath "$NEW")"
[ -x "$OLD" ] || { echo "OLD engine not executable: $OLD" >&2; exit 1; }
[ -x "$NEW" ] || { echo "NEW engine not executable: $NEW" >&2; exit 1; }

mkdir -p /tmp/opencode
LOG="/tmp/opencode/sprt_$$.log"
OUT="/tmp/opencode/sprt_$$.pgn"

# cutechess total games = rounds * games; games=2 + -repeat plays each opening
# once per colour, so rounds = max_games / 2.
ROUNDS=$(( (MAXGAMES + 1) / 2 ))

echo "SPRT: OLD=$OLD"
echo "      NEW=$NEW"
echo "      tc=${TC} elo0=${ELO0} elo1=${ELO1} alpha=${ALPHA} beta=${BETA} max=${MAXGAMES} seed=${SEED}"

OPEN_OPT=()
if [ -f "$OPENINGS" ]; then
  OPEN_OPT=(-openings file="$OPENINGS" format=epd order=random policy=default)
  echo "      openings=${OPENINGS}"
else
  echo "WARNING: no openings file ($OPENINGS); playing from startpos (high variance)" >&2
fi

# Pipe through tee so the raw cutechess output is kept for verdict parsing.
cutechess-cli \
  -engine name=OLD cmd="$OLD" proto="$PROTO" dir="$(dirname "$OLD")" \
  -engine name=NEW cmd="$NEW" proto="$PROTO" dir="$(dirname "$NEW")" \
  -each tc="$TC" -maxmoves "$MAXMOVES" \
  -games 2 -rounds "$ROUNDS" -repeat -srand "$SEED" \
  "${OPEN_OPT[@]}" \
  -sprt elo0="$ELO0" elo1="$ELO1" alpha="$ALPHA" beta="$BETA" \
  -ratinginterval 20 -pgnout "$OUT" 2>&1 | tee "$LOG" \
  | grep -aE "Score of|Elo|LOS|SPRT|Finished match|^Finished game" || true

# --- verdict ---------------------------------------------------------------
SPRT_LINE="$(grep -a "SPRT:" "$LOG" | tail -1 || true)"
LLR="$(printf '%s\n' "$SPRT_LINE" | sed -n 's/.*llr \([^ ]*\).*/\1/p')"
LB="$(printf '%s\n' "$SPRT_LINE" | sed -n 's/.*lbound \([^,]*\).*/\1/p')"
UB="$(printf '%s\n' "$SPRT_LINE" | sed -n 's/.*ubound \([^,]*\).*/\1/p')"

echo
echo "Last SPRT: ${SPRT_LINE:-<none>}"
RC=0
python3 - "$LLR" "$LB" "$UB" <<'PY' || RC=$?
import math, sys

def num(x):
    try:
        return float(x)
    except ValueError:
        return math.inf if x.startswith("u") else -math.inf

if not sys.argv[1]:
    print("VERDICT: ERROR (no SPRT line found in cutechess output)")
    sys.exit(3)
llr, lo, hi = (num(x) for x in sys.argv[1:4])
if llr >= hi:
    print("VERDICT: PASS  (H1 accepted: NEW is stronger by >= elo1)")
elif llr <= lo:
    print("VERDICT: FAIL  (H0 accepted: NEW is not stronger by >= elo0)")
else:
    print(f"VERDICT: INCONCLUSIVE (cap reached; llr={llr:.2f} in [{lo:.2f}, {hi:.2f}])")
    sys.exit(2)
PY

echo "PGN: $OUT"
exit "$RC"
