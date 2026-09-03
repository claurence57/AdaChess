--
--  AdaChess-BB : static evaluation
--
--  A deliberately simple evaluation: material plus a few positional
--  heuristics (pawn advancement, piece centralization). Scores are in
--  centipawns, positive from White's point of view.
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Eval is

   subtype Score_Type is Integer;
   -- Pseudo-infinite bounds for the search.
   Infinity   : constant Score_Type := 30_000;
   Mate_Score : constant Score_Type := 30_000;

   function Static (Position : in Position_Type) return Score_Type;
   -- Material + position, positive when White is better.

   function Evaluate (Position : in Position_Type) return Score_Type;
   -- Static evaluation from the point of view of the side to move
   -- (convenient for a negamax framework).

end BBChess.Eval;
