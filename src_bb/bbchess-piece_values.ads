--
--  AdaChess-BB : piece values
--
--  Two distinct value tables, formerly duplicated (and subtly different)
--  inside BBChess.Search and BBChess.See:
--
--    * Ordering_Value : move ordering / MVV-LVA / quiescence victim values.
--      The king is 0 because it never takes part in a material comparison.
--    * SEE_Value : static exchange evaluation. The king is huge so that a
--      king capture is never preferred to another recapture; a king is only
--      ever the last attacker of a sequence.
--
--  Both tables share the same non-king values (100/320/330/500/900).
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Eval;
use BBChess.Eval;

package BBChess.Piece_Values is

   function Ordering_Value (Kind : in Kind_Type) return Score_Type;
   -- Centipawn value used by the search move ordering (King = 0).

   function SEE_Value (Kind : in Kind_Type) return Score_Type;
   -- Centipawn value used by the static exchange evaluation (King = 10_000).

   pragma Inline (Ordering_Value);
   pragma Inline (SEE_Value);

end BBChess.Piece_Values;
