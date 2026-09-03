--
--  AdaChess-BB : move notation (coordinate / XBoard style)
--
--  Converts moves to/from coordinate notation such as "e2e4", "e7e8q".
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

package BBChess.Notation is

   function To_String (Move : in Move_Type) return String;
   -- Coordinate notation; a promotion appends the piece letter (q/r/b/n).

   function From_String (Position : in Position_Type; Text : in String)
     return Move_Type;
   -- Resolve Text against the legal moves of Position. Returns Empty_Move
   -- when no legal move matches.

end BBChess.Notation;
