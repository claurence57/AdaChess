--
--  AdaChess-BB : static exchange evaluation (SEE)
--
--  Estimates the material outcome of a capture sequence on a single square,
--  assuming both sides answer with their cheapest available attacker. The
--  value is used to avoid searching losing captures (SEE < 0) in the
--  quiescence search.
--
--  Model (shared with the mailbox engine for reference):
--    * both sides recapture only on the destination square, choosing their
--      least valuable attacker first (pinned pieces cannot take part);
--    * a recapture may be declined (standing pat at 0), so a losing line is
--      simply dropped;
--    * a king may be the last attacker only - the exchange stops right after
--      a king capture.
--
--  Sliding x-ray attackers are naturally revealed because the occupancy is
--  updated at every step of the sequence.

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Eval;
use BBChess.Eval;

package BBChess.See is

   function Static_Exchange_Value
     (Position : in Position_Type;
      Move     : in Move_Type) return Score_Type;
   -- Net centipawn outcome, from the point of view of the side to move, of
   -- playing Move (a capture, an en-passant or a promotion). Positive means
   -- the exchange wins material, negative that it loses some. Non-tactical
   -- moves return 0.

end BBChess.See;
