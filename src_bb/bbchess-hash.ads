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

   -- Zobrist deltas used by Make_Move for incremental key updates. XORing
   -- these in/out reproduces exactly the value of Compute.
   function Piece_Key (Piece : in Piece_Type; Square : in Square_Type)
     return Bitboard;
   function Side_Key return Bitboard;
   function Castle_Key (Color : in Color_Type; Side : in Castle_Side_Type)
     return Bitboard;
   function Ep_Key (File : in Natural) return Bitboard;

   pragma Inline (Piece_Key);
   pragma Inline (Side_Key);
   pragma Inline (Castle_Key);
   pragma Inline (Ep_Key);

   procedure Set_Keys_Enabled (On : in Boolean);
   function  Keys_Enabled return Boolean;
   -- When enabled, Make_Move updates Position.Key incrementally (used by the
   -- search / transposition table). Disabled by default so move generation
   -- and perft do not pay for hashing.

end BBChess.Hash;
