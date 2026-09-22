--
--  AdaChess-BB : absolute pin detection (shared bitboard routine)
--
--  A piece of the defender is "absolutely pinned" when it is the only blocker
--  between its own king and an enemy sliding piece of matching direction: it
--  may not leave the king's line. The computation works on plain bitboards so
--  it can serve both the full Position (move generation) and the compact
--  See_Board working copy (static exchange evaluation) from one place.
--
--  The potential pinners are the enemy sliders sitting on the king's empty
--  rays; a pin exists when exactly one friendly piece stands between the king
--  and such a slider.
--

with BBChess.Board;
use BBChess.Board;

package BBChess.Pin_Mask is

   function Pinned (Occ               : in Bitboard;
                    King_Sq           : in Square_Type;
                    Own               : in Bitboard;
                    Enemy_Rook_Queen  : in Bitboard;
                    Enemy_Bishop_Queen : in Bitboard) return Bitboard;
   -- Bitboard of the Own pieces that are absolutely pinned to King_Sq.
   -- Enemy_Rook_Queen / Enemy_Bishop_Queen are the enemy rook-or-queen and
   -- bishop-or-queen sets; Occ is the total occupancy; Own is the defender's
   -- colour occupancy.

   pragma Inline (Pinned);

end BBChess.Pin_Mask;
