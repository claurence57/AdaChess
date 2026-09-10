#!/usr/bin/env bash
# A/B match: reference (~/bin/adachess_bb, tagged bb-1.0) vs current HEAD build.
# Usage: scripts/ab.sh [tc] [games] [seed]
set -euo pipefail

TC="${1:-1+0.1}"
GAMES="${2:-20}"
SEED="${3:-7}"
REF="${HOME}/bin/adachess_bb"
HEAD="$(dirname "$0")/../bin_bb/adachess_bb"
OUT="/tmp/opencode/ab_$$.pgn"

REF="$(realpath "$REF")"; HEAD="$(realpath "$HEAD")"
echo "REF = $REF"
echo "NEW = $HEAD"
echo "cutechess: tc=${TC} games=${GAMES} srand=${SEED}"

cutechess-cli \
  -engine name=REF cmd="$REF" proto=xboard dir="$(dirname "$REF")" \
  -engine name=NEW cmd="$HEAD" proto=xboard dir="$(dirname "$HEAD")" \
  -each tc="$TC" -games "$GAMES" -maxmoves 100 -pgnout "$OUT" \
  -repeat -rounds 1 -srand "$SEED" 2>&1 | grep -E "Score of|Elo|LOS|Finished match"
echo "PGN: $OUT"
