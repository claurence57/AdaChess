--
--  AdaChess-BB : alpha-beta search (body)
--
--  Iterative deepening with a transposition table, PVS at the root and at
--  every node, move ordering (hash move, MVV-LVA captures, killers, history),
--  a light LMR, null-move pruning and reverse futility pruning, plus a
--  bounded quiescence search on tactical moves. The search is interruptible
--  (a deadline is polled inside the recursion), which bounds the worst-case
--  duration of a move.
--
--  Lazy SMP: the transposition table is shared between the search threads
--  while the move-ordering heuristics (killers, history), the search path and
--  the node/time counters live in a per-thread Search_Context. Threads are
--  Ada tasks; the primary thread (1) produces the reported result.
--

with Ada.Real_Time;
use Ada.Real_Time;

with Ada.Text_IO;
with Ada.Characters.Handling;

with Ada.Numerics.Elementary_Functions;

with System;

with Ada.Unchecked_Deallocation;

with Ada.Task_Identification;

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Movegen;
use BBChess.Movegen;

with BBChess.Eval;
use BBChess.Eval;

with BBChess.Piece_Values;
use BBChess.Piece_Values;

with BBChess.See;
use BBChess.See;

with BBChess.Syzygy;

with BBChess.Notation;
use BBChess.Notation;

with BBChess.Tunable;

package body BBChess.Search is

   -- Raised (from Poll_Time) when the per-move time budget is exhausted or
   -- another thread asked the search to stop. The iterative loop catches it
   -- and falls back to the last fully completed iteration.
   Search_Interrupted : exception;

   -- Checking the clock only every Check_Interval nodes keeps the overhead
   -- negligible while still bounding the overshoot.
   Check_Interval : constant := 1024;
   Max_Ply        : constant := 128;

   -- Tunable search parameters (declared in the spec, see the Set / Load /
   -- Dump interface). The defaults are exactly the former hard-coded
   -- constants, so an unmodified run is bit-identical.
   Search_Params : Search_Param_Array :=
     (S_Futility_Margin      => 180,
      S_Futility_Base        => 120,
      S_Razor_Margin         => 300,
      S_Aspiration_Window    => 40,
      S_Delta_Margin         => 200,
      S_Max_Q_Depth          => 8,
      S_Null_Red_Base        => 3,
      S_Null_Red_Div         => 4,
      S_Lmp_Base             => 4,
      S_Lmp_Quad             => 1,
      S_Check_Ext_Min_Depth  => 1,
      S_Check_Ext_Ply_Guard  => 4,
      S_Counter_Score        => 800_000,
      S_Cont_History_Weight  => 6,
      S_History_Max          => 16_384);

   Search_Real_Params : Search_Real_Param_Array :=
     (S_Lmr_Base     => 0.75,
      S_Lmr_Divisor  => 2.25);

   -- Allowed ranges: Set_Search_Param clamps a tuned value to them. The
   -- integer ranges also keep the arithmetic below (margins multiplied by the
   -- depth, quiescence depth, ordering scores) well inside a 32-bit Integer.
   Search_Param_Min : constant Search_Param_Array :=
     (S_Futility_Margin      => -32_000,
      S_Futility_Base        => -32_000,
      S_Razor_Margin         => -32_000,
      S_Aspiration_Window    => 0,
      S_Delta_Margin         => 0,
      S_Max_Q_Depth          => 0,
      S_Null_Red_Base        => 0,
      S_Null_Red_Div         => 1,
      S_Lmp_Base             => 0,
      S_Lmp_Quad             => 0,
      S_Check_Ext_Min_Depth  => 0,
      S_Check_Ext_Ply_Guard  => 0,
      S_Counter_Score        => 0,
      S_Cont_History_Weight  => 0,
      S_History_Max          => 0);

   Search_Param_Max : constant Search_Param_Array :=
     (S_Futility_Margin      => 32_000,
      S_Futility_Base        => 32_000,
      S_Razor_Margin         => 32_000,
      S_Aspiration_Window    => 32_000,
      S_Delta_Margin         => 32_000,
      S_Max_Q_Depth          => 128,
      S_Null_Red_Base        => 128,
      S_Null_Red_Div         => 128,
      S_Lmp_Base             => 256,
      S_Lmp_Quad             => 8,
      S_Check_Ext_Min_Depth  => 4,
      S_Check_Ext_Ply_Guard  => 64,
      S_Counter_Score        => 799_999,
      S_Cont_History_Weight  => 1_024,
      -- S_History_Max may exceed Cont_Value'Last (16_384): the continuation
      -- history is then saturated at 16_384 by the second clamp in
      -- Bump_Cont_History. Both values stay far inside a 32-bit Integer. The
      -- max is deliberately NOT lowered to 16_384 because a params file that
      -- requests a larger value is well-formed and its (already documented)
      -- behaviour must not change; History_Max is not tuned by spsa.py.
      S_History_Max          => 1_000_000);

   -- Named constants used by the rest of the search (the former hard-coded
   -- constants, now renames of the parameter table entries).
   Delta_Margin        : Score_Type
     renames Search_Params (S_Delta_Margin);
   Max_Q_Depth         : Score_Type
     renames Search_Params (S_Max_Q_Depth);
   Futility_Margin     : Score_Type
     renames Search_Params (S_Futility_Margin);
   Futility_Base       : Score_Type
     renames Search_Params (S_Futility_Base);
   Razor_Margin        : Score_Type
     renames Search_Params (S_Razor_Margin);
   Aspiration_Window   : Score_Type
     renames Search_Params (S_Aspiration_Window);
   Cont_History_Weight : Score_Type
     renames Search_Params (S_Cont_History_Weight);
   History_Max         : Score_Type
     renames Search_Params (S_History_Max);

   -- The LMR log-formula constants are read when the table is (re)built.
   LMR_Base    : Float renames Search_Real_Params (S_Lmr_Base);
   LMR_Divisor : Float renames Search_Real_Params (S_Lmr_Divisor);


   ---------------
   -- TT helpers --
   ---------------

   type Bound_Type is (Exact, Lower_Bound, Upper_Bound);

   --  Depth only ever holds 0 .. Max_Ply (128) on store and -1 as the empty
   --  marker, so it is carried in 16 bits. The wide members come first so the
   --  record still packs to 24 bytes (8 key + 4 move + 4 score + 4 age + 1
   --  bound + 2 depth + 1 padding) instead of 32; only Hash_Key moved to the
   --  end (see below). Field values, entry acceptance and the replacement
   --  policy are unchanged, so the search tree is bit-identical; the 32 MB
   --  table becomes 24 MB, closer to the 8 MB L3.
   type TT_Depth_Type is range -1 .. 32_767;
   for TT_Depth_Type'Size use 16;

   --  Hash_Key is deliberately the *last* field: Store writes the payload
   --  field-by-field and the key last, so under Lazy SMP a racing reader can
   --  never observe a new key paired with a stale payload. The reader checks
   --  the key only to *decide* whether to use the slot, and only then copies
   --  the entry, so a racing write is either seen whole or not at all (the
   --  write may still tear, but the key test rejects the stale key).
   type TT_Entry is
      record
         Move     : Packed_Move := 0;
         Score    : Score_Type := 0;
         Age      : Natural := 0;
         Bound    : Bound_Type := Exact;
         Depth    : TT_Depth_Type := -1;
         Hash_Key : Bitboard := 0;
      end record;

   TT_Size   : constant := 1_048_576;
   TT_Mask   : constant := TT_Size - 1;
   type TT_Table is array (0 .. TT_Size - 1) of TT_Entry;
   Transposition_Table : TT_Table;

   -- Current search generation, used to age entries: an entry left over from
   -- a previous search is replaced before a fresh one.
   TT_Generation : Natural := 0;

   Mate_Threshold : constant Score_Type := Mate_Score - 1000;

   -- Two entries form a bucket (even index and the next one).
   function TT_Bucket (Position : in Position_Type) return Natural is
     (Natural (Position.Key and Bitboard (TT_Mask - 1)));
   pragma Inline (TT_Bucket);

   --  Software prefetch of a TT slot, issued at node entry so the probe's
   --  cache miss overlaps with the prologue (draw / repetition / mate checks).
   --  A pure hint: it has no architectural effect and cannot change the search.
   procedure Prefetch_TT (P : in System.Address)
     with Import, Convention => Intrinsic, External_Name => "__builtin_prefetch";
   pragma Inline (Prefetch_TT);

   function Adjust_Score (S : Score_Type; Ply : Natural) return Score_Type is
   begin
      if S >= Mate_Threshold then
         return S - Ply;
      elsif S <= -Mate_Threshold then
         return S + Ply;
      end if;
      return S;
   end Adjust_Score;
   pragma Inline (Adjust_Score);

   procedure Clear_Transposition_Table is
   begin
      -- Cleared entry by entry: an aggregate assignment of the whole table
      -- would be built on the (limited) main-thread stack.
      for I in Transposition_Table'Range loop
         Transposition_Table (I) :=
           (Hash_Key => 0, Depth => -1, Bound => Exact,
            Score => 0, Move => 0, Age => 0);
      end loop;
   end Clear_Transposition_Table;

   -- Store a node. Mate scores are normalized by the distance to the root
   -- so they stay comparable across different depths. The two-way bucket
   -- keeps the deeper of the two entries and replaces stale ones first.
   -- Under Lazy SMP the table is written without locking. The key is written
   -- last (payload first, field-by-field) and checked before the payload is
   -- read, so a torn read can only pair the new key with an already-valid
   -- payload; the old key on a half-written slot simply fails the key test.
   -- The remaining races are accepted Lazy SMP behaviour: two threads may
   -- store different valid entries in the same slot (last key wins), and a
   -- slot may be replaced between the probe's key test and the copy, which
   -- only yields a shallower/deeper but still key-consistent node.
   procedure Store (Position : in Position_Type;
                    Depth     : in Natural;
                    Bound     : in Bound_Type;
                    Score     : in Score_Type;
                    Move      : in Move_Type;
                    Ply       : in Natural)
   is
      B      : constant Natural := TT_Bucket (Position);
      Packed : constant Packed_Move := Pack_Move (Move);
      Saved  : Score_Type := Score;
      Slot   : Natural;
      Repl   : Boolean;
   begin
      if Saved >= Mate_Threshold then
         Saved := Saved + Ply;
      elsif Saved <= -Mate_Threshold then
         Saved := Saved - Ply;
      end if;

      -- Prefer a matching key, then an empty slot, then a stale entry, then
      -- the shallower of the two.
      if Transposition_Table (B).Hash_Key = Position.Key then
         Slot := B;
      elsif Transposition_Table (B + 1).Hash_Key = Position.Key then
         Slot := B + 1;
      elsif Transposition_Table (B).Depth < 0 then
         Slot := B;
      elsif Transposition_Table (B + 1).Depth < 0 then
         Slot := B + 1;
      elsif Transposition_Table (B).Age < TT_Generation
        and then Transposition_Table (B + 1).Age >= TT_Generation
      then
         Slot := B;
      elsif Transposition_Table (B + 1).Age < TT_Generation
        and then Transposition_Table (B).Age >= TT_Generation
      then
         Slot := B + 1;
      elsif Transposition_Table (B + 1).Depth < Transposition_Table (B).Depth then
         Slot := B + 1;
      else
         Slot := B;
      end if;

      declare
         Old : TT_Entry renames Transposition_Table (Slot);
      begin
         Repl := Old.Depth < 0
           or else Old.Hash_Key = Position.Key
           or else TT_Depth_Type (Depth) >= Old.Depth
           or else Old.Age < TT_Generation;
      end;

      if Repl then
         --  Payload first, Hash_Key last. The key is the only field the probe
         --  tests, so publishing it last means a reader that sees the new key
         --  also sees a fully written payload. The write may tear, but a torn
         --  slot keeps either the old key (probe misses) or the new key only
         --  once the payload is consistent.
         Transposition_Table (Slot).Move  := Packed;
         Transposition_Table (Slot).Score := Saved;
         Transposition_Table (Slot).Age   := TT_Generation;
         Transposition_Table (Slot).Bound := Bound;
         Transposition_Table (Slot).Depth := TT_Depth_Type (Depth);
         Transposition_Table (Slot).Hash_Key := Position.Key;
      end if;
   end Store;

   ---------------------
   -- Search context --
   ---------------------

   type Killer_Array is array (1 .. 2, 0 .. Max_Ply) of Move_Type;
   type History_Array is
     array (Color_Type, Square_Type, Square_Type) of Score_Type;
   type Path_Array is array (0 .. Max_Ply) of Bitboard;

   -- Counter-move table: Counter (Side, From, To) is the move by Side that
   -- refuted the opponent's move From-To (i.e. the reply that produced a beta
   -- cutoff after From-To was played). Used as a quiet-move ordering term.
   type Counter_Array is
     array (Color_Type, Square_Type, Square_Type) of Move_Type;

   -- 1-ply continuation history: indexed by the (piece, to) of the previous
   -- move and the (piece, to) of the current move. Each pair is packed into a
   -- single 0 .. 767 index so the table is a flat 768 x 768 array.
   --
   -- The stored values are clamped to +/- History_Max (default 16_384), so
   -- they fit a 16-bit signed element. Halving the element size shrinks the
   -- table from 2.25 MB to 1.13 MB (closer to the 1 MB L2). Indices, clamping,
   -- bonus and weight are unchanged, and the value is widened back to
   -- Score_Type before any arithmetic, so with the default parameters every
   -- stored/read value - hence the search tree - is bit-identical.
   type Cont_Value is range -16_384 .. 16_384;
   for Cont_Value'Size use 16;

   -- Type bounds widened to Score_Type for the saturation test below.
   Cont_Value_Max : constant Score_Type := Score_Type (Cont_Value'Last);
   Cont_Value_Min : constant Score_Type := Score_Type (Cont_Value'First);

   type Cont_History_Array is array (0 .. 767, 0 .. 767) of Cont_Value;

   -- Move played at each ply of the current line: Move_Path (Ply) is the move
   -- made from ply Ply to Ply + 1. A node at ply P looks up Move_Path (P - 1)
   -- to recover the opponent's previous move (counter-move / continuation).
   type Move_Path_Array is array (0 .. Max_Ply) of Move_Type;

   type Search_Context is
      record
         Killers          : Killer_Array := (others => (others => Empty_Move));
         History          : History_Array := (others => (others => (others => 0)));
         Counter          : Counter_Array :=
           (others => (others => (others => Empty_Move)));
         Cont_History     : Cont_History_Array := (others => (others => 0));
         Move_Path        : Move_Path_Array := (others => Empty_Move);
         Search_Path      : Path_Array := (others => 0);
         Game_Keys        : Game_Key_Array := (others => 0);
         Game_Key_Count   : Natural := 0;
         Nodes_Count      : Natural := 0;
         Next_Checkpoint  : Natural := Check_Interval;
         Time_Limit_Armed : Boolean := False;
         Node_Limit       : Natural := 0;
         Start_Time       : Time := Clock;
         Time_Budget      : Duration := 0.0;
      end record;
   type Context_Access is access all Search_Context;

   -- The context is allocated once per search (stack size would be a problem
   -- inside the search tasks) and freed as soon as the search returns, so a
   -- long session cannot leak ~40 KB per move.
   procedure Free_Context is new
     Ada.Unchecked_Deallocation (Object => Search_Context,
                                 Name   => Context_Access);

   -- Keys of the game so far, copied into each thread's context.
   Init_Game_Keys  : Game_Key_Array := (others => 0);
   Init_Game_Key_Count : Natural := 0;

   -- Set by the primary thread to stop the helpers promptly.
   Stop_Search : Boolean := False;
   pragma Atomic (Stop_Search);

   -- External stop request (UCI "stop"/"quit"). Kept separate from
   -- Stop_Search, which the Lazy SMP primary thread clears between searches:
   -- the command loop may set this at any time and it is only cleared by an
   -- explicit Clear_Stop before a new search starts.
   Abort_Request : Boolean := False;
   pragma Atomic (Abort_Request);

   procedure Set_Game_History (Keys  : in Game_Key_Array;
                               Count : in Natural) is
   begin
      if Count > Max_Game_Keys then
         Init_Game_Key_Count := Max_Game_Keys;
      else
         Init_Game_Key_Count := Count;
      end if;
      for I in 0 .. Init_Game_Key_Count - 1 loop
         Init_Game_Keys (I) := Keys (I);
      end loop;
   end Set_Game_History;

   procedure Init_Context (Ctx    : in Context_Access;
                           Arm    : in Boolean;
                           Budget : in Duration;
                           Node_Cap : in Natural := 0) is
   begin
      Ctx.Killers := (others => (others => Empty_Move));
      Ctx.History := (others => (others => (others => 0)));
      Ctx.Counter := (others => (others => (others => Empty_Move)));
      Ctx.Cont_History := (others => (others => 0));
      Ctx.Move_Path := (others => Empty_Move);
      Ctx.Search_Path := (others => 0);
      Ctx.Game_Key_Count := Init_Game_Key_Count;
      for I in 0 .. Init_Game_Key_Count - 1 loop
         Ctx.Game_Keys (I) := Init_Game_Keys (I);
      end loop;
      Ctx.Nodes_Count := 0;
      Ctx.Next_Checkpoint := Check_Interval;
      Ctx.Time_Limit_Armed := Arm;
      Ctx.Time_Budget := Budget;
      Ctx.Node_Limit := Node_Cap;
      Ctx.Start_Time := Clock;
   end Init_Context;

   -- The node counter increment and checkpoint test are on the hot path
   -- (one call per search / quiescence node); the rare branch that actually
   -- checks the stop flags and the clock lives in this separate out-of-line
   -- procedure so Poll_Time stays small enough to inline. Same arithmetic and
   -- same exceptions as before, only the layout changed.
   procedure Poll_Time_Slow (Ctx : in Context_Access) is
   begin
      Ctx.Next_Checkpoint := Ctx.Nodes_Count + Check_Interval;
      if Stop_Search or else Abort_Request then
         raise Search_Interrupted;
      end if;
      if Ctx.Time_Limit_Armed
        and then To_Duration (Clock - Ctx.Start_Time) >= Ctx.Time_Budget
      then
         raise Search_Interrupted;
      end if;
      if Ctx.Node_Limit > 0 and then Ctx.Nodes_Count >= Ctx.Node_Limit then
         raise Search_Interrupted;
      end if;
   end Poll_Time_Slow;

   procedure Poll_Time (Ctx : in Context_Access) is
   begin
      Ctx.Nodes_Count := Ctx.Nodes_Count + 1;
      if Ctx.Nodes_Count >= Ctx.Next_Checkpoint then
         Poll_Time_Slow (Ctx);
      end if;
   end Poll_Time;
   pragma Inline (Poll_Time);

   -------------------------------
   -- Move ordering helpers --
   -------------------------------

   function Is_Tactical (Position : in Position_Type; Move : in Move_Type)
     return Boolean is
   begin
      if Move.Flag in En_Passant | Promotion then
         return True;
      end if;
      return (Color_Board (Position, Opposite (Position.Side)) and Bit (Move.To)) /= 0;
   end Is_Tactical;
   pragma Inline (Is_Tactical);

   -- History_Max and Cont_History_Weight are tunable search parameters
   -- (renames of Search_Params).

   --  Scratch array used by the movers. It is written for every move in
   --  1 .. Count before the corresponding entry is read, so the per-call
   --  default initialization (a 1 KB zero fill) is only overhead.
   type Order_Array is array (1 .. 256) of Score_Type;
   pragma Suppress_Initialization (Order_Array);

   -- History bonus of a quiet move that produced a beta cutoff at Depth.
   -- Quadratic in the depth so that deep cutoffs dominate, and capped so a
   -- single update can never saturate the table (it stays far below the
   -- killer and capture scores used by Order). Depth is at most Max_Ply (128),
   -- so Depth * Depth reaches 16_384 and the cap returns at most 1_024; the
   -- product never overflows.
   function History_Bonus (Depth : in Natural) return Score_Type is
      B : constant Score_Type := Score_Type (Depth) * Score_Type (Depth);
   begin
      if B > 1024 then
         return 1024;
      end if;
      return B;
   end History_Bonus;
   pragma Inline (History_Bonus);

   -- The stored value is clamped to +/- History_Max after every update, so it
   -- is at most History_Max before the next update. Adding a bonus of at most
   -- 1_024 therefore reaches at most History_Max + 1_024 (1_001_024 with the
   -- largest tunable History_Max, 1_000_000; 17_408 with the default 16_384):
   -- far inside a 32-bit Integer, no intermediate overflow.
   procedure Bump_History (Ctx        : in Context_Access;
                           Side       : in Color_Type;
                           From, To   : in Square_Type;
                           Bonus      : in Score_Type) is
      V : Score_Type := Ctx.History (Side, From, To) + Bonus;
   begin
      if V > History_Max then
         V := History_Max;
      elsif V < -History_Max then
         V := -History_Max;
      end if;
      Ctx.History (Side, From, To) := V;
   end Bump_History;

   -- Flat index of a move's (piece, destination) pair in the continuation
   -- history table: 12 pieces x 64 squares = 768 entries.
   function Cont_Index (Piece : in Piece_Type; To : in Square_Type)
     return Natural is
     (Piece_Type'Pos (Piece) * 64 + To);
   pragma Inline (Cont_Index);

   -- Continuation-history update for the current move, given the previous move
   -- on the line. Uses the same saturation range as the main history table.
   procedure Bump_Cont_History (Ctx        : in Context_Access;
                                Prev, Move : in Move_Type;
                                Bonus      : in Score_Type) is
      K : constant Natural := Cont_Index (Prev.Piece, Prev.To);
      J : constant Natural := Cont_Index (Move.Piece, Move.To);
      V : Score_Type := Score_Type (Ctx.Cont_History (K, J)) + Bonus;
   begin
      if V > History_Max then
         V := History_Max;
      elsif V < -History_Max then
         V := -History_Max;
      end if;
      -- Cont_Value_Max equals the default History_Max, so with the default
      -- parameters this second clamp is inert and the stored value is exactly
      -- the old 32-bit one. It only matters for a non-default History_Max
      -- (never tuned: see scripts/spsa.py).
      if V > Cont_Value_Max then
         V := Cont_Value_Max;
      elsif V < Cont_Value_Min then
         V := Cont_Value_Min;
      end if;
      Ctx.Cont_History (K, J) := Cont_Value (V);
   end Bump_Cont_History;

   -- Kind of the piece captured by Move (pawns for en-passant; the moving
   -- piece itself when Move is not a capture - only used for ordering).
   function Captured_Kind (Position : in Position_Type; Move : in Move_Type)
     return Kind_Type is
      P : Piece_Type;
   begin
      if Move.Flag = En_Passant then
         return Pawn;
      end if;
      if Piece_At (Position, Move.To, P) then
         return Kind (P);
      end if;
      return Pawn;
   end Captured_Kind;
   pragma Inline (Captured_Kind);

   -- Move ordering score: hash move first, then captures (MVV-LVA), then
   -- promotions, then the killers, then the counter-move (the reply that
   -- refuted the same previous move elsewhere), then quiet moves ordered by
   -- the history + continuation-history heuristics (moves that already
   -- produced beta cutoffs elsewhere).
   -- Tactical is the caller's Is_Tactical result for Move, passed in so the
   -- (cheap but repeated) test is not run twice per move during ordering.
   -- Prev is the move made on the previous ply (Empty_Move at the root).
   function Order (Ctx        : in Context_Access;
                   Position   : in Position_Type;
                   Move       : in Move_Type;
                   Hash_Move  : in Move_Type;
                   Prev       : in Move_Type;
                   Ply        : in Natural;
                   Tactical   : in Boolean) return Score_Type is
   begin
      if Move = Hash_Move then
         return 100_000_000;
      end if;

      if Move.Flag = Promotion then
         return 50_000_000 + Ordering_Value (Kind (Move.Promotion));
      end if;

      if Tactical then
         declare
            Victim   : constant Score_Type :=
              Ordering_Value (Captured_Kind (Position, Move));
            Attacker : constant Score_Type := Ordering_Value (Kind (Move.Piece));
         begin
            return 2_000_000 + Victim * 16 - Attacker;
         end;
      end if;

      -- Quiet move.
      if Ply <= Max_Ply then
         if Move = Ctx.Killers (1, Ply) then
            return 1_000_000;
         elsif Move = Ctx.Killers (2, Ply) then
            return 900_000;
         end if;
         -- Counter-move: the move by the side to move that refuted the
         -- opponent's previous move (From-To) in this thread's earlier search.
         -- Indexed by the mover of the previous move (the opponent).
         if Prev /= Empty_Move
           and then Move = Ctx.Counter (Color (Prev.Piece), Prev.From, Prev.To)
         then
            return Search_Params (S_Counter_Score);
         end if;
      end if;

      -- History + 1-ply continuation history. The continuation term is
      -- weighted up: it is the more selective predictor (keyed on the actual
      -- previous move), while the plain history stays as a fallback. The sum
      -- is bounded (History_Max * (1 + Cont_History_Weight)) and stays well
      -- below the counter-move and killer scores used above.
      if Prev /= Empty_Move then
         return Ctx.History (Color (Move.Piece), Move.From, Move.To)
           + Cont_History_Weight
             * Score_Type (Ctx.Cont_History (Cont_Index (Prev.Piece, Prev.To),
                                             Cont_Index (Move.Piece, Move.To)));
      end if;
      return Ctx.History (Color (Move.Piece), Move.From, Move.To);
   end Order;
   pragma Inline (Order);

   -- XBoard thinking output ("post"/"nopost"). When enabled, the primary
   -- thread prints one line per completed iteration:
   --    depth score time nodes bestmove
   Post_Output : Boolean := False;

   procedure Set_Post (On : in Boolean) is
   begin
      Post_Output := On;
   end Set_Post;

   -- Single console lock shared by the command loop and the search threads
   -- (Ada.Text_IO is not task-safe). Both the XBoard "post" iteration reports
   -- and the UCI "readyok"/"bestmove" lines go through it.
   protected Console is
      procedure Put_Line (S : in String);
   end Console;

   protected body Console is
      procedure Put_Line (S : in String) is
      begin
         Ada.Text_IO.Put_Line (S);
         Ada.Text_IO.Flush;
      end Put_Line;
   end Console;

   procedure Locked_Put_Line (S : in String) is
   begin
      Console.Put_Line (S);
   end Locked_Put_Line;

   procedure Report_Iteration (Depth      : in Natural;
                               Score      : in Score_Type;
                               Elapsed    : in Duration;
                               Nodes      : in Natural;
                               Best       : in Move_Type) is
      Centis : constant Long_Integer :=
        Long_Integer (Elapsed * 100.0);
      Disp   : Score_Type := Score;
      -- One iteration line: depth + score + centiseconds + nodes + move.
      -- Ample for any value the engine can print.
      Line   : String (1 .. 80);
      Last   : Natural := 0;

      procedure Append (S : in String) is
      begin
         Line (Last + 1 .. Last + S'Length) := S;
         Last := Last + S'Length;
      end Append;
   begin
      if not Post_Output then
         return;
      end if;

      -- Mate scores: emit 100000 - plies so cutechess/XBoard can display
      -- a proper "mate in N" (see XboardEngine::adaptScore).
      if Score >= Mate_Threshold then
         Disp := 100_000 - (Mate_Score - Score);
      elsif Score <= -Mate_Threshold then
         Disp := -(100_000 - (Mate_Score + Score));
      end if;

      Append (Natural'Image (Depth));
      Append (" " & Score_Type'Image (Disp));
      Append (" " & Long_Integer'Image (Centis));
      Append (" " & Natural'Image (Nodes));
      if Best /= Empty_Move then
         Append (" " & To_String (Best));
      end if;
      Console.Put_Line (Line (1 .. Last));
   end Report_Iteration;

   -- True when Position has already occurred on the current line. A single
   -- earlier occurrence among the ancestors of the node is enough (the side
   -- to move can force the repetition); otherwise the position must have
   -- been seen twice in the game history for a threefold repetition. The
   -- occurrences are looked up in the game history and among the ancestors
   -- of the current node (plies 1 .. Ply-1, the root being the last game
   -- key). Ply is the depth of the node below the search root.
   function Is_Repetition (Ctx      : in Context_Access;
                           Position : in Position_Type;
                           Ply      : in Natural) return Boolean
   is
      -- A position can only repeat since the last irreversible move (pawn
      -- move or capture), so only the last Halfmove plies have to be scanned.
      Window : constant Natural := Position.Halfmove;
      G      : Natural := 0;   -- occurrences already present in the game
      Start  : Natural;
      Lo     : Natural;
   begin
      if Window > 0 and then Ctx.Game_Key_Count > 0 then
         Start := (if Ctx.Game_Key_Count > Window
                   then Ctx.Game_Key_Count - Window
                   else 0);
         for I in Start .. Ctx.Game_Key_Count - 1 loop
            if Ctx.Game_Keys (I) = Position.Key then
               G := G + 1;
               exit when G >= 2;
            end if;
         end loop;
      end if;

      if G < 2 and then Ply > 1 then
         Lo := (if Ply > Window then Ply - Window else 1);
         for Q in Lo .. Ply - 1 loop
            if Ctx.Search_Path (Q) = Position.Key then
               return True;   -- repeated within the current search line
            end if;
         end loop;
      end if;

      return G >= 2;
   end Is_Repetition;

   procedure Reset_Search is
   begin
      -- A fresh game also gets a fresh transposition table: entries from a
      -- previous game must not leak into the next one.
      Clear_Transposition_Table;
      Init_Game_Key_Count := 0;
      TT_Generation := 0;
   end Reset_Search;

   function Has_Non_Pawn (Position : in Position_Type; Color : in Color_Type)
     return Boolean is
   begin
      return (Position.Pieces (Make (Color, Knight))
              or Position.Pieces (Make (Color, Bishop))
              or Position.Pieces (Make (Color, Rook))
              or Position.Pieces (Make (Color, Queen))) /= 0;
   end Has_Non_Pawn;
   pragma Inline (Has_Non_Pawn);

   -- True for dead positions: king vs king, king + lone minor vs king, and
   -- king + bishop vs king + bishop with both bishops on the same color
   -- complex. The occupancy guard keeps the expensive part off the hot path:
   -- no dead position has more than four men on the board.
   function Insufficient_Material (Position : in Position_Type) return Boolean is
      W_Minor : Bitboard;
      B_Minor : Bitboard;
   begin
      if Popcount (Position.All_Occ) > 4 then
         return False;
      end if;

      if (Position.Pieces (White_Pawn) or Position.Pieces (Black_Pawn)
          or Position.Pieces (White_Rook) or Position.Pieces (Black_Rook)
          or Position.Pieces (White_Queen) or Position.Pieces (Black_Queen)) /= 0
      then
         return False;
      end if;

      W_Minor := Position.Pieces (White_Knight)
        or Position.Pieces (White_Bishop);
      B_Minor := Position.Pieces (Black_Knight)
        or Position.Pieces (Black_Bishop);

      -- King vs king, or a lone minor against a bare king.
      if Popcount (W_Minor) <= 1 and then Popcount (B_Minor) = 0 then
         return True;
      end if;
      if Popcount (B_Minor) <= 1 and then Popcount (W_Minor) = 0 then
         return True;
      end if;

      -- Bishops on the same color complex cannot mate.
      if Position.Pieces (White_Knight) = 0
        and then Position.Pieces (Black_Knight) = 0
        and then Popcount (Position.Pieces (White_Bishop)) = 1
        and then Popcount (Position.Pieces (Black_Bishop)) = 1
        and then (Lowest_Bit (Position.Pieces (White_Bishop)) mod 2)
                   = (Lowest_Bit (Position.Pieces (Black_Bishop)) mod 2)
      then
         return True;
      end if;

      return False;
   end Insufficient_Material;
   pragma Inline (Insufficient_Material);

   ----------------
   -- Quiescence --
   ----------------

   -- The QDepth parameter counts quiescence plies below the root of this
   -- quiescence call. At Max_Q_Depth the node is not expanded further: a quiet
   -- node returns its alpha-updated stand-pat score, while an in-check node
   -- only checks for mate and otherwise fails low. A static eval of an in-check
   -- position is never returned.
   function Quiescence (Ctx        : in Context_Access;
                        Position   : in out Position_Type;
                        Alpha, Beta : in Score_Type;
                        Ply        : in Natural;
                        QDepth     : in Natural) return Score_Type
   is
      A        : Score_Type := Alpha;
      B        : constant Score_Type := Beta;
      In_Check : constant Boolean := King_In_Check (Position, Position.Side);
      Stand    : Score_Type := 0;
      Moves    : Move_List;
      Count    : Natural;
      Limit    : Natural;
   begin
      Poll_Time (Ctx);

      -- Depth bound: stop expanding once the quiescence cap is reached.
      if QDepth >= Max_Q_Depth then
         if In_Check then
            -- In check at the cap: the evasions cannot be searched (that would
            -- defeat the bound), so only mate is detected. If evasions exist,
            -- the opponent's recapture (or any deeper continuation) is not
            -- searched, so the real value is unknown: return alpha as a
            -- fail-low bound instead of a static-based score the parent would
            -- treat as exact.
            Generate_Legal_Moves (Position, Moves, Count);
            if Count = 0 then
               return -(Mate_Score - Ply);
            end if;
            return A;
         else
            -- Not in check: the alpha-updated stand-pat score is the safe
            -- truncation (exactly the score the unbounded search would use
            -- as its floor before trying more captures).
            Stand := Evaluate (Position);
            if Stand >= B then
               return Stand;
            end if;
            if Stand > A then
               A := Stand;
            end if;
            return A;
         end if;
      end if;

      -- Stand pat is only legal when not in check: a side that is in check
      -- must play an evasion, so the static evaluation cannot be returned.
      if not In_Check then
         Stand := Evaluate (Position);
         if Stand >= B then
            return Stand;
         end if;
         if Stand > A then
            A := Stand;
         end if;
      end if;

      if In_Check then
         -- Every evasion must be tried.
         Generate_Legal_Moves (Position, Moves, Count);
      else
         -- Only captures / promotions are searched in a quiet position, so
         -- there is no need to generate the (numerous) quiet moves. In_Check
         -- is already known to be False here, so the generator is told to skip
         -- the check-detection lookup it would otherwise repeat.
         Generate_Legal_Tactical_Moves (Position, Moves, Count,
                                        Not_In_Check => True);
      end if;

      if Count = 0 and then In_Check then
         return -(Mate_Score - Ply);
      end if;

      -- Move the tactical moves (captures / promotions) to the front, then
      -- order them by MVV so the most promising captures are tried first.
      -- The victim value is computed once per tactical move (and carried
      -- through the selection swaps) instead of once per comparison. In a
      -- quiet position the generator already yields only tactical moves, so
      -- the partition (and its per-move Is_Tactical test) is skipped; the
      -- selection sort below then sees the same T = Count prefix.
      declare
         T : Natural := 0;
         Vic : Order_Array;
      begin
         if In_Check then
            for I in 1 .. Count loop
               if Is_Tactical (Position, Moves (I)) then
                  T := T + 1;
                  Vic (T) := Ordering_Value (Captured_Kind (Position, Moves (I)));
                  declare
                     Tmp : constant Move_Type := Moves (T);
                  begin
                     Moves (T) := Moves (I);
                     Moves (I) := Tmp;
                  end;
               end if;
            end loop;
         else
            T := Count;
            for I in 1 .. Count loop
               Vic (I) := Ordering_Value (Captured_Kind (Position, Moves (I)));
            end loop;
         end if;

         for I in 1 .. T loop
            declare
               Best_J : Natural := I;
               Best_V : Score_Type := Vic (I);
            begin
               for J in I + 1 .. T loop
                  if Vic (J) > Best_V then
                     Best_V := Vic (J);
                     Best_J := J;
                  end if;
               end loop;
               if Best_J /= I then
                  declare
                     Tmp : constant Move_Type := Moves (I);
                     Tmp_V : constant Score_Type := Vic (I);
                  begin
                     Moves (I) := Moves (Best_J);
                     Moves (Best_J) := Tmp;
                     Vic (I) := Vic (Best_J);
                     Vic (Best_J) := Tmp_V;
                  end;
               end if;
            end;
         end loop;

         -- When in check every legal move is an evasion and must be tried
         -- (a quiet king move is a legal answer to a check), not just the
         -- tactical subset searched in quiet positions.
         if In_Check then
            Limit := Count;
         else
            Limit := T;
         end if;

         for I in 1 .. Limit loop
            -- A capture that the static exchange evaluation scores as losing
            -- cannot improve on the stand-pat score, so it is not searched
            -- (promotions and evasions out of check are always kept). For a
            -- non-check node the loop only walks the tactical prefix, whose
            -- victim value is already in Vic.
            if (not In_Check)
              and then Moves (I).Flag /= Promotion
              and then (Static_Exchange_Value (Position, Moves (I)) < 0
                        or else Stand + Vic (I) + Delta_Margin <= A)
            then
               null;
            else
               declare
                  Undo  : Undo_Info;
                  Score : Score_Type;
               begin
                  Make_Move (Position, Moves (I), Undo);
                  Score := -Quiescence (Ctx, Position, -B, -A, Ply + 1,
                                        QDepth + 1);
                  Unmake_Move (Position, Moves (I), Undo);

                  if Score >= B then
                     return Score;
                  end if;
                  if Score > A then
                     A := Score;
                  end if;
               end;
            end if;
         end loop;
      end;

      return A;
   end Quiescence;

   -------------
   -- Negamax --
   -------------

   -- Futility_Margin, Futility_Base, Razor_Margin and Aspiration_Window are
   -- tunable search parameters (renames of Search_Params, see the top of the
   -- body and the Set / Load / Dump interface in the spec).

   -- Late-move reduction table: reduction applied to a late quiet move as a
   -- function of the remaining depth and the move index (both capped), from
   -- the classic log formula R = LMR_Base + Log(depth) * Log(move) /
   -- LMR_Divisor. The table is rebuilt at elaboration and whenever a
   -- "S_LMR_*" parameter changes, so a tuned formula is applied immediately.
   LMR_Max_Depth : constant := 64;
   LMR_Max_Move  : constant := 64;
   type LMR_Array is array (1 .. LMR_Max_Depth, 1 .. LMR_Max_Move) of Natural;

   LMR_Table : LMR_Array := (others => (others => 0));

   procedure Rebuild_LMR is
      use Ada.Numerics.Elementary_Functions;
      R : Float;
   begin
      for D in 1 .. LMR_Max_Depth loop
         for M in 1 .. LMR_Max_Move loop
            R := LMR_Base + Log (Float (D)) * Log (Float (M)) / LMR_Divisor;
            if R < 0.0 then
               R := 0.0;
            end if;
            LMR_Table (D, M) := Natural (R);
         end loop;
      end loop;
   end Rebuild_LMR;

   function Negamax (Ctx        : in Context_Access;
                     Position   : in out Position_Type;
                     Depth, Ply : in Natural;
                     Alpha, Beta : in Score_Type) return Score_Type
   is
      A           : Score_Type := Alpha;
      B           : Score_Type := Beta;
      Moves       : Move_List;
      Count       : Natural;
      Hash_Move   : Move_Type := Empty_Move;
      In_Check    : Boolean := False;
      Best_Move_Here : Move_Type := Empty_Move;
      Best_Score  : Score_Type := -Infinity;
      Child_Depth : Natural := 0;
      Eval_Now    : Score_Type := 0;
      Have_Eval   : Boolean := False;
      TT_Score    : Score_Type := 0;
      -- Move made on the previous ply (the move that led to this node); the
      -- counter-move and continuation-history orderings key on it.
      Prev        : Move_Type := Empty_Move;
   begin
      Poll_Time (Ctx);

      -- Recover the previous move from this thread's per-ply move path. The
      -- value is a by-value copy and every parent writes its own slot just
      -- before recursing, so no stale pointer survives an Unmake.
      if Ply >= 1 and then Ply - 1 <= Max_Ply then
         Prev := Ctx.Move_Path (Ply - 1);
      end if;

      -- Terminal draws: the fifty-move rule and dead positions are scored
      -- as draws before anything else, including the quiescence call.
      if Position.Halfmove >= 100
        or else Insufficient_Material (Position)
      then
         return 0;
      end if;

      if Depth = 0 then
         return Quiescence (Ctx, Position, A, B, Ply, 0);
      end if;

      -- Prefetch the transposition-table bucket now, so its cache miss is
      -- resolved by the time the probe below reads it (the prologue and the
      -- repetition/syzygy/mate-distance checks in between hide the latency).
      Prefetch_TT (Transposition_Table (TT_Bucket (Position))'Address);

      -- Record the current node on the search path (for the repetition
      -- detection of its descendants) and claim a draw on a repetition
      -- before trusting the transposition table.
      if Ply <= Max_Ply then
         Ctx.Search_Path (Ply) := Position.Key;
      end if;
      if Is_Repetition (Ctx, Position, Ply) then
         return 0;
      end if;

      -- Syzygy tablebase: an exact WDL result, when the loaded tables cover
      -- this material. Only positions without castling rights and with a zero
      -- halfmove clock are probed (Fathom rejects the others).
      if BBChess.Syzygy.Enabled
        and then Popcount (Position.All_Occ) <= BBChess.Syzygy.Largest
      then
         declare
            W : constant Integer := BBChess.Syzygy.Probe_WDL (Position);
         begin
            case W is
               when 4 =>                     -- TB_WIN
                  return BBChess.Syzygy.TB_Win - Ply;
               when 0 =>                     -- TB_LOSS
                  return -(BBChess.Syzygy.TB_Win - Ply);
               when 1 | 2 | 3 =>             -- draw / blessed / cursed
                  return 0;
               when others =>
                  null;
            end case;
         end;
      end if;

      -- Mate-distance pruning: no node can score better than a mate found
      -- at the current ply, nor worse than being mated right now.
      declare
         M_Alpha : constant Score_Type := -Mate_Score + Ply;
         M_Beta  : constant Score_Type := Mate_Score - Ply - 1;
      begin
         if A < M_Alpha then
            A := M_Alpha;
         end if;
         if B > M_Beta then
            B := M_Beta;
         end if;
         if A >= B then
            return A;
         end if;
      end;

      -- Transposition table probe (two-way bucket). Each slot's Hash_Key is
      -- checked *before* its payload is copied, and Store publishes the key
      -- last, so a slot is only used once its payload is consistent.
      declare
         Bk    : constant Natural := TT_Bucket (Position);
         Found : Boolean := False;
         E     : TT_Entry;
      begin
         if Transposition_Table (Bk).Hash_Key = Position.Key then
            E := Transposition_Table (Bk);
            Found := True;
         elsif Transposition_Table (Bk + 1).Hash_Key = Position.Key then
            E := Transposition_Table (Bk + 1);
            Found := True;
         end if;

         if Found then
            TT_Score := Adjust_Score (E.Score, Ply);
            if E.Depth >= TT_Depth_Type (Depth) then
               case E.Bound is
                  when Exact =>
                     return TT_Score;
                  when Lower_Bound =>
                     if TT_Score >= B then
                        return TT_Score;
                     end if;
                  when Upper_Bound =>
                     if TT_Score <= A then
                        return TT_Score;
                     end if;
               end case;
            end if;
            Hash_Move := Unpack_Move (E.Move);
         end if;
      end;

      Generate_Legal_Moves (Position, Moves, Count, In_Check);

      if Count = 0 then
         if In_Check then
            return -(Mate_Score - Ply);
         else
            return 0;
         end if;
      end if;

      -- Static evaluation for the pruning decisions (only needed at low
      -- depth and out of check).
      if not In_Check and then Depth <= 3 then
         Eval_Now := Evaluate (Position);
         Have_Eval := True;
      end if;

      -- Razoring: when the static evaluation is far below alpha, verify with
      -- a quiescence search and return it if it does not reach alpha.
      if Depth <= 2 and then not In_Check and then Have_Eval
        and then Eval_Now + Razor_Margin * Score_Type (Depth) < Alpha
      then
         declare
            Q : constant Score_Type := Quiescence (Ctx, Position, A, B, Ply, 0);
         begin
            if Q < Alpha then
               return Q;
            end if;
         end;
      end if;

      -- Check extension: evasions are forced, so an in-check node is
      -- searched one ply deeper than a quiet one. Bounded by Ply so that a
      -- long checking sequence cannot explode the search.
      if In_Check and then Depth >= Natural (Search_Params (S_Check_Ext_Min_Depth))
        and then Ply <= Max_Ply
          - Search_Params (S_Check_Ext_Ply_Guard)
      then
         Child_Depth := Depth;
      else
         Child_Depth := Depth - 1;
      end if;

      -- Reverse futility pruning.
      if Depth = 1 and then not In_Check and then Have_Eval then
         if Eval_Now - Futility_Margin >= B then
            return Eval_Now;
         end if;
      end if;

      -- Null-move pruning (skip in pawn-only endgames / when in check).
      if Depth >= 3 and then not In_Check
        and then Has_Non_Pawn (Position, Position.Side)
      then
         declare
            -- Only Side, En_Passant and Key are touched here (the recursive
            -- call restores the board through Unmake), so saving just those
            -- three fields avoids copying the whole Position.
            Saved_Side : constant Color_Type := Position.Side;
            Saved_Ep   : constant Integer := Position.En_Passant;
            Saved_Key  : constant Bitboard := Position.Key;
            -- Standard adaptive null-move reduction: deeper nodes get a
            -- larger reduction (R = 3 + Depth / 4, integer division).
            N_Reduction : constant Natural :=
              Search_Params (S_Null_Red_Base)
              + Depth / Natural (Search_Params (S_Null_Red_Div));
            N_Depth     : Natural;
            N_Score    : Score_Type;
         begin
            -- Guard the child depth so it stays a valid Natural: at shallow
            -- depth the adaptive formula can reach or exceed Depth - 1.
            if N_Reduction >= Depth - 1 then
               N_Depth := 0;
            else
               N_Depth := Depth - 1 - N_Reduction;
            end if;
            if Position.En_Passant /= Ep_None then
               Position.Key :=
                 Position.Key xor Hash.Ep_Key (Position.En_Passant mod 8);
            end if;
            Position.En_Passant := Ep_None;
            Position.Side := Opposite (Position.Side);
            Position.Key := Position.Key xor Hash.Side_Key;

            -- A null move has no real predecessor: clear this node's move
            -- slot so the null child does not pick up a stale move (from an
            -- unrelated subtree at the same ply) as its previous move.
            if Ply <= Max_Ply then
               Ctx.Move_Path (Ply) := Empty_Move;
            end if;

            N_Score := -Negamax (Ctx, Position, N_Depth,
                                 Ply + 1, -B, -B + 1);

            Position.Side := Saved_Side;
            Position.En_Passant := Saved_Ep;
            Position.Key := Saved_Key;
            if N_Score >= B then
               return N_Score;
            end if;
         end;
      end if;

      -- Move ordering, then PVS over the children.
      declare
         Ord : Order_Array;
         -- Occupancy of the side not to move, loop-invariant during the
         -- ordering pass; the per-move tactical test is then a single bit
         -- test against it (same predicate as Is_Tactical).
         Enemy_Occ : constant Bitboard :=
           Color_Board (Position, Opposite (Position.Side));
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Ctx, Position, Moves (J), Hash_Move, Prev, Ply,
                              (Moves (J).Flag in En_Passant | Promotion
                               or else (Enemy_Occ and Bit (Moves (J).To)) /= 0));
         end loop;

         for I in 1 .. Count loop
            declare
               Best_J : Natural := I;
               Best_O : Score_Type := Ord (I);
            begin
               for J in I + 1 .. Count loop
                  if Ord (J) > Best_O then
                     Best_O := Ord (J);
                     Best_J := J;
                  end if;
               end loop;
               if Best_J /= I then
                  declare
                     Tmp_M : constant Move_Type := Moves (I);
                  begin
                     Moves (I) := Moves (Best_J);
                     Moves (Best_J) := Tmp_M;
                  end;
                  Ord (Best_J) := Ord (I);
                  Ord (I) := Best_O;
               end if;
            end;

            declare
               Undo    : Undo_Info;
               Score   : Score_Type;
               -- Same predicate the ordering pass uses; recomputed here so the
               -- tactical flag is not carried through the sort in a third
               -- array (only Moves and Ord need to be permuted).
               Tactical : constant Boolean :=
                 Moves (I).Flag in En_Passant | Promotion
                 or else (Enemy_Occ and Bit (Moves (I).To)) /= 0;
               Reduction : Natural := 0;
               Move_Depth : constant Natural := Child_Depth;
            begin
               -- Late move pruning: at low depth the late quiet moves are
               -- simply skipped (they are ordered last and almost never
               -- improve on the already searched moves).
                if not In_Check and then not Tactical
                  and then Depth <= 3
                  and then Best_Score > -Mate_Threshold
                  and then I > Search_Params (S_Lmp_Base)
                    + Search_Params (S_Lmp_Quad) * Depth * Depth
                then
                  goto Next_Move;
               end if;

               -- Futility pruning: a quiet move whose static evaluation plus
               -- a depth-scaled margin cannot reach alpha is not searched.
               if not In_Check and then not Tactical and then Have_Eval
                 and then Depth <= 2
                 and then Best_Score > -Mate_Threshold
                 and then Eval_Now + Futility_Base * Score_Type (Depth) <= Alpha
               then
                  goto Next_Move;
               end if;

               -- Late move reduction for late quiet moves (log formula).
               if not Tactical and then Depth >= 3 and then I >= 4
                 and then not In_Check
               then
                  Reduction :=
                    LMR_Table (Natural'Min (Depth, LMR_Max_Depth),
                               Natural'Min (I, LMR_Max_Move));
                  if Reduction >= Child_Depth then
                     Reduction := Child_Depth - 1;
                  end if;
               end if;

               Make_Move (Position, Moves (I), Undo);

               -- Record the move for the child's previous-move lookup. The
               -- parent rewrites its own slot on every iteration and the child
               -- copies it by value at node entry, so the value is always the
               -- move actually on the board above it.
               if Ply <= Max_Ply then
                  Ctx.Move_Path (Ply) := Moves (I);
               end if;

               if I = 1 then
                  Score := -Negamax (Ctx, Position, Move_Depth, Ply + 1, -B, -A);
               else
                  Score := -Negamax (Ctx, Position, Move_Depth - Reduction,
                                     Ply + 1, -A - 1, -A);
                  if Reduction > 0 and then Score > A then
                     -- Verify a reduced fail-high at full depth.
                     Score := -Negamax (Ctx, Position, Move_Depth, Ply + 1,
                                        -A - 1, -A);
                  end if;
                  if Score > A and then Score < B then
                     Score := -Negamax (Ctx, Position, Move_Depth, Ply + 1,
                                        -B, -A);
                  end if;
               end if;

               Unmake_Move (Position, Moves (I), Undo);

               -- Penalize a quiet move that failed to raise the window, so
               -- the history (and continuation history) heuristics learn to
               -- avoid it.
               if not Tactical and then Ply <= Max_Ply
                 and then Score <= Alpha
               then
                  Bump_History (Ctx, Position.Side, Moves (I).From,
                                Moves (I).To, -History_Bonus (Depth));
                  if Prev /= Empty_Move then
                     Bump_Cont_History (Ctx, Prev, Moves (I),
                                        -History_Bonus (Depth));
                  end if;
               end if;

               if Score > Best_Score then
                  Best_Score := Score;
                  Best_Move_Here := Moves (I);
               end if;
               if Score >= B then
                  if not Tactical and then Ply <= Max_Ply then
                     if Ctx.Killers (1, Ply) /= Moves (I) then
                        Ctx.Killers (2, Ply) := Ctx.Killers (1, Ply);
                        Ctx.Killers (1, Ply) := Moves (I);
                     end if;
                     Bump_History (Ctx, Position.Side, Moves (I).From,
                                   Moves (I).To, History_Bonus (Depth));
                     -- Learn the refutation of the opponent's previous move:
                     -- Counter is keyed by the mover of that previous move.
                     if Prev /= Empty_Move then
                        Ctx.Counter (Opposite (Position.Side), Prev.From,
                                     Prev.To) := Moves (I);
                        Bump_Cont_History (Ctx, Prev, Moves (I),
                                           History_Bonus (Depth));
                     end if;
                  end if;
                  Store (Position, Depth, Lower_Bound, Score,
                         Best_Move_Here, Ply);
                  return Score;
               end if;
               if Score > A then
                  A := Score;
               end if;
            end;
            <<Next_Move>>
            null;
         end loop;
      end;

      declare
         Bound : Bound_Type;
      begin
         if A <= Alpha then
            Bound := Upper_Bound;
         elsif A >= B then
            Bound := Lower_Bound;
         else
            Bound := Exact;
         end if;
         Store (Position, Depth, Bound, A, Best_Move_Here, Ply);
      end;

      return A;
   end Negamax;

   -------------
   -- Root    --
   -------------

   function Root_Search (Ctx        : in Context_Access;
                         Position   : in out Position_Type;
                         Depth      : in Natural;
                         Prev_Best  : in Move_Type;
                         Alpha      : in Score_Type;
                         Beta       : in Score_Type;
                         Best_Score : out Score_Type) return Move_Type
   is
      Root_Moves : Move_List;
      Count      : Natural;
      A          : Score_Type := Alpha;
      B          : constant Score_Type := Beta;
      Best       : Move_Type := Empty_Move;
      Best_Sc    : Score_Type := -Infinity;
   begin
      Generate_Legal_Moves (Position, Root_Moves, Count);

      if Count = 0 then
         Best_Score := 0;
         return Empty_Move;
      end if;

      declare
         Ord : Order_Array;
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Ctx, Position, Root_Moves (J), Prev_Best,
                              Empty_Move, 0,
                              Is_Tactical (Position, Root_Moves (J)));
         end loop;

         for I in 1 .. Count loop
            declare
               Best_J : Natural := I;
               Best_O : Score_Type := Ord (I);
            begin
               for J in I + 1 .. Count loop
                  if Ord (J) > Best_O then
                     Best_O := Ord (J);
                     Best_J := J;
                  end if;
               end loop;
               if Best_J /= I then
                  declare
                     Tmp_M : constant Move_Type := Root_Moves (I);
                  begin
                     Root_Moves (I) := Root_Moves (Best_J);
                     Root_Moves (Best_J) := Tmp_M;
                  end;
                  Ord (Best_J) := Ord (I);
                  Ord (I) := Best_O;
               end if;
            end;

            declare
               Undo  : Undo_Info;
               Score : Score_Type;
            begin
               Make_Move (Position, Root_Moves (I), Undo);

               -- Publish the root move so the children at ply 1 see it as their
               -- previous move (counter-move / continuation-history lookup).
               Ctx.Move_Path (0) := Root_Moves (I);

               if I = 1 then
                  Score := -Negamax (Ctx, Position, Depth - 1, 1, -B, -A);
               else
                  Score := -Negamax (Ctx, Position, Depth - 1, 1, -A - 1, -A);
                  if Score > A and then Score < B then
                     Score := -Negamax (Ctx, Position, Depth - 1, 1, -B, -A);
                  end if;
               end if;

               Unmake_Move (Position, Root_Moves (I), Undo);

               if Score > Best_Sc then
                  Best_Sc := Score;
                  Best    := Root_Moves (I);
               end if;
               if Score > A then
                  A := Score;
               end if;
               if A >= B then
                  exit;
               end if;
            end;
         end loop;
      end;

      if Best /= Empty_Move then
         declare
            Bound : Bound_Type;
         begin
            if Best_Sc >= B then
               Bound := Lower_Bound;
            elsif Best_Sc <= Alpha then
               Bound := Upper_Bound;
            else
               Bound := Exact;
            end if;
            Store (Position, Depth, Bound, Best_Sc, Best, 0);
         end;
      end if;

      Best_Score := Best_Sc;
      return Best;
   end Root_Search;

   ---------------------
   -- Iterative search --
   ---------------------

   type Thread_Result is
      record
         Best  : Move_Type := Empty_Move;
         Score : Score_Type := -Infinity;
         Depth : Natural := 0;
         Nodes : Natural := 0;
      end record;

   function Iterative_Search (Ctx        : in Context_Access;
                              Position   : in Position_Type;
                              Max_Depth  : in Natural;
                              Time_Alloc : in Duration;
                              Soft_Alloc : in Duration;
                              Report     : in Boolean) return Thread_Result
   is
      Result      : Thread_Result;
      Work        : Position_Type := Position;
      Best        : Move_Type := Empty_Move;
      Best_Score  : Score_Type := 0;
      --  Last *fully completed* iteration's move and score. Best/Best_Score
      --  are updated by Root_Search as the running ordering hint, but an
      --  aspiration re-search that is interrupted after its narrow pass has
      --  already overwritten Best with a move scored under an unverified
      --  bound. Only a completed iteration is allowed to be reported, so the
      --  result is snapshotted here at completion time.
      Done_Best   : Move_Type := Empty_Move;
      Done_Score  : Score_Type := 0;
      Alpha       : Score_Type := -Infinity;
      Beta        : Score_Type := Infinity;
      Score       : Score_Type;
      T0          : constant Time := Clock;
      Nodes_Base  : constant Natural := Ctx.Nodes_Count;
      Completed   : Boolean := False;
      Last_Depth  : Natural := 0;
      Elapsed     : Duration;
      Prev_Iter   : Duration := 0.0;
   begin
      Work.Key := Hash.Compute (Work);

      begin
         for D in 1 .. Max_Depth loop
            Elapsed := To_Duration (Clock - Ctx.Start_Time);
            --  Iteration-level (soft) stop: never start a new iteration
            --  once the soft target is reached, nor when the previous
            --  iteration would be repeated past it. The very first
            --  iteration is always attempted: it is the only one that can
            --  produce a move, and Hard_Alloc still cuts it short.
            if Time_Alloc > 0.0
              and then Elapsed >= Time_Alloc
            then
               exit;
            end if;
            if Soft_Alloc > 0.0
              and then D > 1
              and then (Elapsed >= Soft_Alloc
                        or else Elapsed + Prev_Iter > Soft_Alloc)
            then
               exit;
            end if;

            if D = 1 then
               Alpha := -Infinity;
               Beta  := Infinity;
               Best := Root_Search (Ctx, Work, D, Best, Alpha, Beta, Score);
            else
               Alpha := Best_Score - Aspiration_Window;
               Beta  := Best_Score + Aspiration_Window;
               Best := Root_Search (Ctx, Work, D, Best, Alpha, Beta, Score);
               if Score <= Alpha or else Score >= Beta then
                  Alpha := -Infinity;
                  Beta  := Infinity;
                  Best := Root_Search (Ctx, Work, D, Best, Alpha, Beta, Score);
               end if;
            end if;
            Best_Score := Score;
            Completed := True;
            Last_Depth := D;
            --  Snapshot the completed iteration: a later (aspiration) iteration
            --  that is interrupted must not leak its partial move/score into
            --  the reported result.
            Done_Best  := Best;
            Done_Score := Best_Score;
            --  Duration of the iteration just completed (used to estimate
            --  whether the next one can still fit under the soft target).
            Prev_Iter := To_Duration (Clock - Ctx.Start_Time) - Elapsed;

            if Report then
               Report_Iteration (D, Best_Score, To_Duration (Clock - T0),
                                 Ctx.Nodes_Count - Nodes_Base, Best);
            end if;

            exit when Abs (Best_Score) >= Mate_Score - 200
              or else Abs (Best_Score) >= BBChess.Syzygy.TB_Win - 100;
         end loop;
      exception
         when Search_Interrupted =>
            -- Current iteration cut short by the deadline: keep the move of
            -- the last fully completed iteration (if any).
            null;
      end;

      if Completed then
         Result.Best := Done_Best;
         Result.Score := Done_Score;
         Result.Depth := Last_Depth;
      end if;
      Result.Nodes := Ctx.Nodes_Count;
      return Result;
   end Iterative_Search;

   ---------------------
   -- Quick_Move --
   ---------------------

   -- Safety net used when the time budget is so small that not even the
   -- first iteration completes: return a legal move without searching.
   function Quick_Move (Position : in Position_Type) return Move_Type is
      Moves    : Move_List;
      Count    : Natural;
      Fallback : Move_Type := Empty_Move;
   begin
      Generate_Legal_Moves (Position, Moves, Count);
      for I in 1 .. Count loop
         if Is_Tactical (Position, Moves (I)) then
            return Moves (I);
         end if;
         if Fallback = Empty_Move then
            Fallback := Moves (I);
         end if;
      end loop;
      return Fallback;
   end Quick_Move;

   --------------------------------
   -- Node accounting (benchmark) --
   --------------------------------

   Accum_Nodes : Natural := 0;

   function Nodes_Searched return Natural is
   begin
      return Accum_Nodes;
   end Nodes_Searched;

   procedure Reset_Nodes is
   begin
      Accum_Nodes := 0;
   end Reset_Nodes;

   function Transposition_Size_MB return Natural is
      -- Fixed compile-time table: TT_Size entries of TT_Entry bytes.
      Bytes : constant Natural :=
        TT_Size * (TT_Entry'Size / 8);
   begin
      return Bytes / (1024 * 1024);
   end Transposition_Size_MB;

   -----------------------------
   -- Tunable search params --
   -----------------------------

   procedure Set_Search_Param (Name : in String; Value : in Integer) is
      use Ada.Characters.Handling;
      U : constant String := To_Upper (Name);
   begin
      for Id in Search_Param_Id loop
         if U = Search_Param_Id'Image (Id) then
            if Value < Search_Param_Min (Id) then
               Search_Params (Id) := Search_Param_Min (Id);
            elsif Value > Search_Param_Max (Id) then
               Search_Params (Id) := Search_Param_Max (Id);
            else
               Search_Params (Id) := Value;
            end if;
            return;
         end if;
      end loop;
   end Set_Search_Param;

   procedure Set_Search_Real_Param (Name : in String; Value : in Float) is
      use Ada.Characters.Handling;
      U : constant String := To_Upper (Name);
   begin
      for Id in Search_Real_Param_Id loop
         if U = Search_Real_Param_Id'Image (Id) then
            Search_Real_Params (Id) := Value;
            -- The reduction table depends on the real constants, so rebuild
            -- it immediately rather than at the next elaboration.
            Rebuild_LMR;
            return;
         end if;
      end loop;
   end Set_Search_Real_Param;

   procedure Load_Search_Params_File is new BBChess.Tunable.Load_File
     (Set_Integer => Set_Search_Param,
      Set_Real    => Set_Search_Real_Param);

   procedure Load_Search_Params (File_Name : in String) is
   begin
      Load_Search_Params_File (File_Name);
   end Load_Search_Params;

   procedure Dump_Search_Params is
   begin
      for Id in Search_Param_Id loop
         BBChess.Tunable.Put (Search_Param_Id'Image (Id), Search_Params (Id));
      end loop;
      for Id in Search_Real_Param_Id loop
         BBChess.Tunable.Put
           (Search_Real_Param_Id'Image (Id), Search_Real_Params (Id));
      end loop;
   end Dump_Search_Params;

   -----------------
   -- Best_Move (fixed depth) --
   -----------------

   function Best_Move (Position : in Position_Type; Depth : in Natural)
     return Move_Type is
      Result : Thread_Result;
   begin
      if Depth = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      TT_Generation := TT_Generation + 1;
      Stop_Search := False;

      declare
         Ctx : Context_Access := new Search_Context;
      begin
         Init_Context (Ctx, Arm => False, Budget => 0.0);
         Result := Iterative_Search (Ctx, Position, Depth, 0.0, 0.0, False);
         Accum_Nodes := Accum_Nodes + Ctx.Nodes_Count;
         Free_Context (Ctx);
      end;

      if Result.Best = Empty_Move then
         return Quick_Move (Position);
      end if;
      return Result.Best;
   end Best_Move;

   -------------------------
   -- Lazy SMP (threads) --
   -------------------------

   Max_Threads : constant := 16;
   --  Read by the search task when it snapshots the worker count, written by
   --  the UCI command loop (Set_Threads) possibly while a search is running:
   --  atomic so the snapshot never observes a torn value.
   Num_Threads : Natural := 1;
   pragma Atomic (Num_Threads);

   procedure Set_Threads (N : in Natural) is
   begin
      if N < 1 then
         Num_Threads := 1;
      elsif N > Max_Threads then
         Num_Threads := Max_Threads;
      else
         Num_Threads := N;
      end if;
   end Set_Threads;

   procedure Request_Stop is
   begin
      Abort_Request := True;
   end Request_Stop;

   procedure Clear_Stop is
   begin
      Abort_Request := False;
   end Clear_Stop;

   --  Number of workers actually launched for the current search. It is
   --  snapshotted from Num_Threads when the search starts (Root_Num_Threads)
   --  and is what the barrier waits for. The UCI command loop can change
   --  Num_Threads while a search is running (setoption Threads), and the
   --  barrier must not wait for workers that were never created: waiting for
   --  the *global* Num_Threads would deadlock a 4-thread search when the GUI
   --  raises it to 8 mid-search. The next search picks up the new value.
   protected type Completion is
      procedure Reset (N : in Natural);
      procedure Signal;
      entry Wait_All;
   private
      Count : Natural := 0;
      Target : Natural := 1;
   end Completion;

   protected body Completion is
      procedure Reset (N : in Natural) is
      begin
         Count := 0;
         Target := N;
      end Reset;

      procedure Signal is
      begin
         Count := Count + 1;
      end Signal;

      entry Wait_All when Count >= Target is
      begin
         null;
      end Wait_All;
   end Completion;

   Done : Completion;

   Root_Position  : Position_Type;
   Root_Max_Depth : Natural := 1;
   Root_Time      : Duration := 0.0;
   Root_Soft      : Duration := 0.0;
   Root_Node_Cap  : Natural := 0;
   --  Worker count for the current search, snapshotted from Num_Threads at
   --  launch: Set_Threads can run from the UCI command loop while the search
   --  is in progress, and the barrier / result loop must use the count that
   --  was actually started.
   Root_Num_Threads : Natural := 1;
   Results        : array (1 .. Max_Threads) of Thread_Result;

   task type Searcher (Id : Positive);

   task body Searcher is
      Ctx : Context_Access := new Search_Context;
   begin
      Init_Context (Ctx, Arm => Root_Time > 0.0, Budget => Root_Time,
                    Node_Cap => Root_Node_Cap);
      Results (Id) := Iterative_Search (Ctx, Root_Position,
                                        Root_Max_Depth, Root_Time, Root_Soft,
                                        Report => (Id = 1));
      Free_Context (Ctx);
      -- The primary thread stops the helpers as soon as it is done.
      if Id = 1 then
         Stop_Search := True;
      end if;
      Done.Signal;
   end Searcher;

   type Searcher_Access is access Searcher;

   --  The workers are heap-allocated (one task object per thread, with a
   --  distinct discriminant) and must be reclaimed after each search: the
   --  earlier code leaked one task object per thread and per search (~8 kB
   --  per search at 8 threads). Freeing an active task object is a bounded
   --  error, so the task is freed only once Ada confirms it terminated.
   procedure Free_Searcher is new
     Ada.Unchecked_Deallocation (Object => Searcher, Name => Searcher_Access);

   procedure Reclaim_Worker (W : in out Searcher_Access) is
   begin
      if W /= null then
         --  The task has signalled completion (Done.Signal) and run off the
         --  end of its body; wait for the runtime to mark it terminated
         --  before freeing the object it lives in.
         while not Ada.Task_Identification.Is_Terminated (W.all'Identity) loop
            delay 0.0;
         end loop;
         Free_Searcher (W);
      end if;
   end Reclaim_Worker;

   -- Shared implementation. Hard_Alloc is the interruptible deadline, Soft_Alloc
   -- the between-iteration target, Node_Cap the optional node ceiling. The
   -- public overloads below map onto it.
   function Best_Move_Impl (Position   : in Position_Type;
                            Max_Depth  : in Natural;
                            Hard_Alloc : in Duration;
                            Soft_Alloc : in Duration;
                            Node_Cap   : in Natural) return Move_Type
   is
      Best : Move_Type := Empty_Move;
   begin
      if Max_Depth = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      TT_Generation := TT_Generation + 1;

      -- Clear the Lazy SMP stop flag once for every search: the previous
      -- multi-threaded search leaves it set, and the single-threaded path
      -- (which never clears it) would otherwise abort at the first poll.
      Stop_Search := False;

      if Num_Threads <= 1 then
         declare
            Ctx    : Context_Access := new Search_Context;
            Result : Thread_Result;
         begin
            Init_Context (Ctx, Arm => Hard_Alloc > 0.0, Budget => Hard_Alloc,
                          Node_Cap => Node_Cap);
            Result := Iterative_Search (Ctx, Position, Max_Depth,
                                        Hard_Alloc, Soft_Alloc, True);
            Accum_Nodes := Accum_Nodes + Ctx.Nodes_Count;
            Free_Context (Ctx);
            if Result.Best = Empty_Move then
               return Quick_Move (Position);
            end if;
            return Result.Best;
         end;
      end if;

      -- Multi-threaded Lazy SMP.
      Root_Position := Position;
      Root_Max_Depth := Max_Depth;
      Root_Time := Hard_Alloc;
      Root_Soft := Soft_Alloc;
      Root_Node_Cap := Node_Cap;
      -- Snapshot the worker count for this search: Set_Threads may run
      -- concurrently from the command loop, but this search must only wait
      -- for (and read the results of) the workers it actually starts.
      Root_Num_Threads := Num_Threads;
      Done.Reset (Root_Num_Threads);

      declare
         Workers : array (1 .. Root_Num_Threads) of Searcher_Access;
      begin
         for I in 1 .. Root_Num_Threads loop
            Results (I) := (Best => Empty_Move, Score => -Infinity,
                            Depth => 0, Nodes => 0);
            Workers (I) := new Searcher (I);
         end loop;

         --  Wait for every worker, then reclaim the task objects. Done.Wait_All
         --  returns once Count reaches the launched count, which is after each
         --  worker has signalled completion (Done.Signal is the last statement
         --  of the task body), so the tasks are terminated and safe to free.
         Done.Wait_All;
         for I in 1 .. Root_Num_Threads loop
            Reclaim_Worker (Workers (I));
         end loop;
      end;

      --  Node accounting for every worker, then the move selection. The
      --  primary thread (1) owns the reported line: it is the only one whose
      --  iteration reports are printed, and its result is the one a GUI
      --  expects. A helper may have completed a deeper iteration on a
      --  different (stale) score, so taking the deepest across threads can
      --  report a move that does not match the primary's printed depth/score.
      --  Only a *completed* iteration sets Results.Best (Iterative_Search
      --  leaves it Empty otherwise), so an interrupted iteration can never
      --  contribute. Primacy is a preference, not a hard rule: if the primary
      --  has no completed result (it can be stopped before its first iteration
      --  finishes while a helper got one), fall back to the deepest completed
      --  result among the helpers.
      declare
         Best_Depth : Natural := 0;
         Best_Score : Score_Type := -Infinity;
      begin
         for I in 1 .. Root_Num_Threads loop
            Accum_Nodes := Accum_Nodes + Results (I).Nodes;
            if I > 1
              and then Results (I).Best /= Empty_Move
              and then (Results (I).Depth > Best_Depth
                        or else (Results (I).Depth = Best_Depth
                                 and then Results (I).Score > Best_Score))
            then
               Best_Depth := Results (I).Depth;
               Best_Score := Results (I).Score;
               Best := Results (I).Best;
            end if;
         end loop;

         --  The primary thread wins whenever it produced a move.
         if Results (1).Best /= Empty_Move then
            Best := Results (1).Best;
         end if;
      end;

      if Best = Empty_Move then
         Best := Quick_Move (Position);
      end if;
      return Best;
   end Best_Move_Impl;

   -- Fixed-depth + time + node cap: the actual implementation.
   function Best_Move (Position   : in Position_Type;
                        Max_Depth  : in Natural;
                        Time_Alloc : in Duration;
                        Node_Cap   : in Natural) return Move_Type is
   begin
      -- A single deadline doubles as both the hard and the soft limit.
      return Best_Move_Impl (Position, Max_Depth, Time_Alloc, Time_Alloc,
                             Node_Cap);
   end Best_Move;

   -- Soft/hard entry point. The hard limit is the interruptible deadline
   -- armed in the context; the soft limit is only consulted between
   -- iterations. Node cap disabled (0): a soft/hard search is a timed move.
   function Best_Move (Position   : in Position_Type;
                        Max_Depth  : in Natural;
                        Soft_Alloc : in Duration;
                        Hard_Alloc : in Duration) return Move_Type is
   begin
      return Best_Move_Impl (Position, Max_Depth, Hard_Alloc, Soft_Alloc, 0);
   end Best_Move;

   -- Timed entry point for XBoard play: no node cap.
   function Best_Move (Position   : in Position_Type;
                       Max_Depth  : in Natural;
                       Time_Alloc : in Duration) return Move_Type is
   begin
      return Best_Move_Impl (Position, Max_Depth, Time_Alloc, Time_Alloc, 0);
   end Best_Move;

begin
   -- Precompute the late-move reduction table from the default real
   -- parameters (rebuilt by Set_Search_Real_Param when they are tuned).
   Rebuild_LMR;

end BBChess.Search;
