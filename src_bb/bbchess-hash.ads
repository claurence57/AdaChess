--
--  AdaChess-BB : Zobrist hashing
--
--  Provides a 64-bit key for a position. The key is recomputed from the
--  position snapshot (simple and safe); make/unmake refresh it this way.
--  The key is stored in Position.Key and used by the transposition table.
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Hash is

   pragma Elaborate_Body (BBChess.Hash);

   function Compute (Position : in Position_Type) return Bitboard;
   -- Deterministic key of the whole position state.

   procedure Set_Keys_Enabled (On : in Boolean);
   function  Keys_Enabled return Boolean;
   -- When enabled, Make_Move refreshes Position.Key (used by the search /
   -- transposition table). Disabled by default so move generation and perft
   -- do not pay for hashing.

end BBChess.Hash;
