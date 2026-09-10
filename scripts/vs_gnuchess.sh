#!/usr/bin/env bash
# Match vs GNU Chess (UCI, ~2400-2500 Elo) using the given AdaChess-BB binary.
# Usage: scripts/vs_gnuchess.sh [tc] [games] [seed] [engine_cmd]
set -euo pipefail

TC="${1:-20+1}"
GAMES="${2:-4}"
SEED="${3:-7}"
ENGINE="${4:-${HOME}/bin/adachess_bb}"   # default: reference
GNU_WRAP="${GNU_WRAP:-/tmp/opencode/gnuchess_uci.sh}"
OUT="/tmp/opencode/vs_gnu_$$.pgn"

[ -x "$ENGINE" ] || { echo "engine not executable: $ENGINE"; exit 1; }
[ -x "$GNU_WRAP" ] || { echo "gnuchess wrapper missing: $GNU_WRAP"; exit 1; }
ENGINE="$(realpath "$ENGINE")"
echo "Engine = $ENGINE"
echo "cutechess: tc=${TC} games=${GAMES} srand=${SEED}"

cutechess-cli \
  -engine name=BB cmd="$ENGINE" proto=xboard dir="$(dirname "$ENGINE")" \
  -engine name=GNU cmd="$GNU_WRAP" proto=uci dir=/tmp \
  -each tc="$TC" -games "$GAMES" -maxmoves 100 -pgnout "$OUT" \
  -repeat -rounds 1 -srand "$SEED" 2>&1 | grep -E "Score of|Elo|LOS|Finished match"
echo "PGN: $OUT"
