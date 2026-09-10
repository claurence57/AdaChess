/*
 * AdaChess-BB : bit intrinsics.
 *
 * The Ada runtime does not expose the GCC builtins, so the two hot bit
 * operations are provided here and imported from Ada (see BBChess.Board).
 * Built with -mpopcnt -mbmi so that the compiler emits the popcnt / bsf
 * instructions instead of a software loop.
 */

#include <stdint.h>

int bb_popcountll (uint64_t x) {
   return __builtin_popcountll (x);
}

int bb_ctzll (uint64_t x) {
   return __builtin_ctzll (x);
}
