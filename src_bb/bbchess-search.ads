--
--  AdaChess-BB : alpha-beta search
--
--  Iterative deepening with a transposition table, PVS, move ordering
--  (hash move, MVV-LVA captures, killers), light LMR, null-move and
--  reverse-futility pruning, and a quiescence search on captures and
--  promotions. Mate/stalemate are detected at the leaves.
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Movegen;
use BBChess.Movegen;

with BBChess.Eval;
use BBChess.Eval;

package BBChess.Search is

   function Best_Move (Position : in Position_Type; Depth : in Natural)
     return Move_Type;
   -- Best move found by a fixed-depth iterative search from Position.
   -- Returns Empty_Move when the side to move has no legal move.

   function Best_Move (Position   : in Position_Type;
                       Max_Depth  : in Natural;
                       Time_Alloc : in Duration) return Move_Type;
   -- Iterative deepening up to Max_Depth that stops at Time_Alloc. The
   -- search is interruptible (the deadline is polled inside the recursion),
   -- so a move is always returned close to the budget even when a single
   -- iteration would need much longer. Used for XBoard play.

end BBChess.Search;
