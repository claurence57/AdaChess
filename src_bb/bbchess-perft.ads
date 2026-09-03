--
--  AdaChess-BB : perft
--
--  Perft counts the number of leaf nodes at a given depth, assuming
--  perfect legal move generation. It is the standard correctness oracle
--  for a move generator / make-unmake pair.
--

with BBChess.Board;
use BBChess.Board;

package BBChess.Perft is

   function Nodes (Position : in out Position_Type; Depth : in Natural)
     return Natural;
   -- Number of legal move sequences of length Depth from Position.

end BBChess.Perft;
