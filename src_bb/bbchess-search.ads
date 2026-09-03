--
--  AdaChess-BB : alpha-beta search
--
--  Negamax framework with fail-hard alpha-beta, quiescence search on
--  captures/promotions, and mate/stalemate detection at the leaves.
--  The root simply tries every legal move (single fixed depth for now;
--  iterative deepening + transposition table come next).
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
   -- Iterative deepening up to Max_Depth, stopping as soon as Time_Alloc
   -- has elapsed (checked between iterations). Used for XBoard play.

end BBChess.Search;
