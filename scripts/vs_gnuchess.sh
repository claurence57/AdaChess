#!/usr/bin/env bash
# Match vs GNU Chess (UCI, ~2400-2500 Elo) using the given AdaChess-BB binary.
# Usage: scripts/vs_gnuchess.sh [tc] [games] [seed] [engine_cmd]
#
# Fairness: both engines start from the SAME positions of the -openings suite
# (each played twice with colours swapped, via -repeat), and the AdaChess
# Polyglot book is disabled for the whole match (GNU runs with OwnBook=false).
# Earlier matches played every game from startpos, which skewed the result
# heavily towards White (~70% wins); the opening suite removes that bias.
set -euo pipefail

TC="${1:-20+1}"
GAMES="${2:-4}"
SEED="${3:-7}"
ENGINE="${4:-${HOME}/bin/adachess_bb}"   # default: reference
GNU_WRAP="${GNU_WRAP:-${HOME}/bin/gnuchess_uci.sh}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENINGS="${OPENINGS:-${ROOT}/openings/openings.epd}"
OUT="/tmp/opencode/vs_gnu_$$.pgn"

[ -x "$ENGINE" ] || { echo "engine not executable: $ENGINE"; exit 1; }
[ -x "$GNU_WRAP" ] || { echo "gnuchess wrapper missing: $GNU_WRAP"; exit 1; }
ENGINE="$(realpath "$ENGINE")"

# Disable the AdaChess opening book for the match so both engines are bookless
# (GNU: OwnBook=false in gnuchess.ini). Restore it on exit, whatever happens.
ROOT_BOOK="$ROOT/books/book.bin"
BOOK_HIDDEN=""
cleanup_book() { [ -n "$BOOK_HIDDEN" ] && mv -f "$BOOK_HIDDEN" "$ROOT_BOOK" || true; }
trap cleanup_book EXIT
if [ -f "$ROOT_BOOK" ]; then
  BOOK_HIDDEN="$ROOT_BOOK.hidden.$$"
  mv -f "$ROOT_BOOK" "$BOOK_HIDDEN"
  echo "note: opening book disabled for a fair match ($ROOT_BOOK)"
fi

# Common opening suite: both engines get the identical set of start positions.
OPEN_OPT=()
if [ -f "$OPENINGS" ]; then
  OPEN_OPT=(-openings file="$OPENINGS" format=epd order=random policy=default)
  echo "openings = $OPENINGS"
else
  echo "WARNING: no openings file ($OPENINGS); playing from startpos (high variance)" >&2
fi

echo "Engine = $ENGINE"
echo "cutechess: tc=${TC} games=${GAMES} srand=${SEED}"

# -games 2 + -repeat plays each opening once per colour; rounds = games/2 so the
# match totals ~GAMES games (rounded up to a whole colour pair).
cutechess-cli \
  -engine name=BB cmd="$ENGINE" proto=xboard dir="$(dirname "$ENGINE")" \
  -engine name=GNU cmd="$GNU_WRAP" proto=uci dir=/tmp \
  -each tc="$TC" -maxmoves 100 \
  -games 2 -rounds "$(( (GAMES + 1) / 2 ))" -repeat -srand "$SEED" \
  "${OPEN_OPT[@]}" \
  -pgnout "$OUT" 2>&1 | grep -E "Score of|Elo|LOS|Finished match"
echo "PGN: $OUT"
