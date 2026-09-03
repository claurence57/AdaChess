--
--  AdaChess-BB : FEN loading
--
--  Minimal FEN parser used to set a Position from its Forsyth-Edwards
--  notation. Enough for the perft suite and later for the XBoard "setboard"
--  command.
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Fen is

   procedure Load (Position : out Position_Type; Text : in String);
   -- Parse a FEN string into Position. Raises Constraint_Error on garbage.

end BBChess.Fen;
