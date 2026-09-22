/*
 * AdaChess-BB : portable PEXT fallback.
 *
 * Only the software parallel-bit-extract below lives here. The "release"
 * build imports the GCC builtin (_pext_u64 via -mbmi2) directly from Ada and
 * never calls into this file; the "portable" build, compiled without -mbmi2,
 * leaves __BMI2__ undefined so the bit-loop branch is used instead, letting
 * the binary run on any x86-64 CPU at the cost of speed.
 */

#include <stdint.h>
#include <immintrin.h>

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
