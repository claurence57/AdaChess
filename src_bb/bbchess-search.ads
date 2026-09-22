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

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

package BBChess.Search is

   -- History of the positions of the current game (Zobrist keys), used for
   -- the threefold-repetition detection inside the search.
   Max_Game_Keys : constant := 512;
   type Game_Key_Array is array (0 .. Max_Game_Keys - 1) of Bitboard;

   procedure Set_Game_History (Keys  : in Game_Key_Array;
                               Count : in Natural);
   -- Record the keys of every position of the game so far (including the
   -- current one). Called before each timed search.

   procedure Set_Post (On : in Boolean);
   -- Enable/disable the XBoard "thinking output" (the "post"/"nopost"
   -- commands): when on, each completed iterative-deepening iteration
   -- prints a line "depth score time nodes bestmove".

   procedure Set_Threads (N : in Natural);
   -- Number of parallel search threads (Lazy SMP). 1 = single threaded.
   -- The transposition table is shared; the heuristics are per thread.

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

   function Best_Move (Position   : in Position_Type;
                        Max_Depth  : in Natural;
                        Time_Alloc : in Duration;
                        Node_Cap   : in Natural) return Move_Type;
   -- Same as above plus a node cap: the search also stops once Node_Cap
   -- nodes have been visited (0 = no cap). The cap is polled inside the
   -- recursion like the deadline, so a move is returned within one poll
   -- interval of the cap. Used by the UCI "go nodes" command.

   function Best_Move (Position   : in Position_Type;
                        Max_Depth  : in Natural;
                        Soft_Alloc : in Duration;
                        Hard_Alloc : in Duration) return Move_Type;
   -- Soft/hard time management. Hard_Alloc is the deadline an iteration
   -- already started may not run past (polled inside the recursion, like
   -- Time_Alloc above). Soft_Alloc is the iteration-level target: no new
   -- iteration is started once it is reached, nor when the elapsed time plus
   -- the previous iteration's duration would clearly overshoot it. A single
   -- early iteration is always allowed to run (up to Hard_Alloc). With
   -- Hard_Alloc = 0 the call behaves like the fixed-time entry point.

   procedure Request_Stop;
   -- Ask the running timed Best_Move to return as soon as possible (polled
   -- inside the recursion). The caller keeps the last completed iteration.
   -- Used by the UCI "stop" and "quit" commands.

   procedure Clear_Stop;
   -- Cancel a pending stop request before starting a new search.

   procedure Locked_Put_Line (S : in String);
   -- Print one line to standard output under the package-wide console lock.
   -- Ada.Text_IO is not task-safe and the Phase 5 UCI search runs in a task,
   -- so the command loop ("readyok", "bestmove") and the XBoard "post"
   -- iteration reports go through this single lock.

   procedure Reset_Search;
   -- Clear the per-search heuristics (transposition table, killers and
   -- history) between games. The position-independent data must not leak
   -- from one game to the next.

   function Nodes_Searched return Natural;
   -- Number of nodes visited since the last Reset_Nodes (or the last timed
   -- search started). Used by the benchmark harness to report nodes/second.

   procedure Reset_Nodes;
   -- Reset the node counter (benchmarking).

   function Transposition_Size_MB return Natural;
   -- Size in mebibytes of the transposition table. The table is a
   -- compile-time-fixed array (not resizable at run time), so this is the
   -- value reported through the UCI "Hash" option.

   ---------------------------------
   -- Tunable search parameters --
   ---------------------------------

   -- The scalar search constants are held in these tables so the SPSA tuner
   -- can override them by name at run time, following the same interface as
   -- the evaluation parameters (Set / Load / Dump below, "--params" file).
   -- The defaults equal the former hard-coded constants exactly, so an
   -- unmodified run is bit-identical.

   -- Integer margins / ordering scores.
   type Search_Param_Id is
     (S_Futility_Margin,
      S_Futility_Base,
      S_Razor_Margin,
      S_Aspiration_Window,
      S_Delta_Margin,
      S_Max_Q_Depth,
      S_Null_Red_Base,
      S_Null_Red_Div,
      S_Lmp_Base,
      S_Lmp_Quad,
      S_Check_Ext_Min_Depth,
      S_Check_Ext_Ply_Guard,
      S_Counter_Score,
      S_Cont_History_Weight,
      S_History_Max);

   type Search_Param_Array is array (Search_Param_Id) of Integer;

   -- Real constants of the late-move-reduction log formula
   -- R = Lmr_Base + Log(depth) * Log(move) / Lmr_Divisor.
   type Search_Real_Param_Id is
     (S_Lmr_Base,
      S_Lmr_Divisor);

   type Search_Real_Param_Array is array (Search_Real_Param_Id) of Float;

   procedure Set_Search_Param (Name : in String; Value : in Integer);
   -- Override one integer search parameter by name ("S_FUTILITY_BASE 120").
   -- An unknown name is ignored; the LMR table is rebuilt when needed.

   procedure Set_Search_Real_Param (Name : in String; Value : in Float);
   -- Override one real search parameter by name ("S_LMR_DIVISOR 2.25").

   procedure Load_Search_Params (File_Name : in String);
   -- Read "Name Value" lines (same format as the evaluation parameters) and
   -- apply every integer / real search parameter found. An unreadable file
   -- is reported and ignored.

   procedure Dump_Search_Params;
   -- Print every search parameter as "NAME value", one per line (the same
   -- two-column format as the evaluation-parameter dump, so the tuner's
   -- "--dump-params" parser reads them unchanged).

end BBChess.Search;
