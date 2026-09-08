--
--  AdaChess-BB : legal move generation
--
--  Strategy (correctness first, optimization later):
--    1. generate every pseudo-legal move;
--    2. keep a move only when, after making it, the mover's own king is
--       not in check.
--
--  Castling gets explicit preconditions (path empty, king not in check,
--  king does not cross attacked squares) before it is generated.
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Attacks;
use BBChess.Attacks;

with BBChess.Moves;
use BBChess.Moves;

package BBChess.Movegen is

   type Move_List is array (1 .. 256) of Move_Type;

   procedure Generate_Legal_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural);
   -- Fill Moves (1..Count) with every legal move of the side to move.

   procedure Generate_Legal_Tactical_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural);
   -- Fill Moves with the legal tactical moves only (captures, en passant,
   -- promotions). Cheaper than the full generator: used by quiescence.

   function King_In_Check (Position : in Position_Type; Color : in Color_Type)
     return Boolean;
   -- True when the king of the given color is attacked by the opponent.

   function Is_Attacked (Position : in Position_Type;
                         Square   : in Square_Type;
                         By       : in Color_Type) return Boolean;
   -- True when Square is attacked by any piece of color By.

end BBChess.Movegen;
