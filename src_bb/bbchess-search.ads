--
--  AdaChess-BB : alpha-beta search
--
--  Iterative deepening with a transposition table, PVS, move ordering
--  (hash move, MVV-LVA captures, killers, history), light LMR, null-move
--  and reverse-futility pruning, a check extension at the horizon and a
--  quiescence search on captures and promotions. Mate/stalemate are
--  detected at the leaves. The timed entry point runs the iteration in
--  aspiration windows around the previous score.
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

   -- History of the positions of the current game (Zobrist keys), used for
   -- the threefold-repetition detection inside the search.
   Max_Game_Keys : constant := 512;
   type Game_Key_Array is array (0 .. Max_Game_Keys - 1) of Bitboard;

   procedure Set_Game_History (Keys  : in Game_Key_Array;
                               Count : in Natural);
   -- Record the keys of every position of the game so far (including the
   -- current one). Called before each timed search.

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

   procedure Reset_Search;
   -- Clear the per-search heuristics (transposition table, killers and
   -- history) between games. The position-independent data must not leak
   -- from one game to the next.

end BBChess.Search;
