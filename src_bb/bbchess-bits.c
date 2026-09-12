/*
 * AdaChess-BB : bit intrinsics.
 *
 * The Ada runtime does not expose the GCC builtins, so the hot bit operations
 * are provided here and imported from Ada (see BBChess.Board).
 *
 * The "release" build compiles this file with -mpopcnt -mbmi -mbmi2 so the
 * compiler emits the hardware instructions. The "portable" build compiles it
 * without those switches: popcount/ctz fall back to the libgcc routines and
 * PEXT to a bit loop, so the binary runs on any x86-64 CPU (no POPCNT/BMI
 * requirement), at the cost of speed.
 */

#include <stdint.h>
#include <immintrin.h>

int bb_popcountll (uint64_t x) {
   return __builtin_popcountll (x);
}

int bb_ctzll (uint64_t x) {
   return __builtin_ctzll (x);
}

/* Parallel bit extract, used by the sliding-attack lookup. */
uint64_t bb_pext (uint64_t x, uint64_t mask) {
#if defined(__BMI2__)
   return _pext_u64 (x, mask);
#else
   uint64_t res = 0;
   for (uint64_t bit = 1; mask != 0; bit <<= 1) {
      uint64_t lsb = mask & (~mask + 1);
      if (x & lsb) {
         res |= bit;
      }
      mask ^= lsb;
   }
   return res;
#endif
}
