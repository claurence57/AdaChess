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

with Ada.Numerics.Elementary_Functions;

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Eval;
use BBChess.Eval;

with BBChess.See;
use BBChess.See;

with BBChess.Notation;
use BBChess.Notation;

package body BBChess.Search is

   -- Raised (from Poll_Time) when the per-move time budget is exhausted or
   -- another thread asked the search to stop. The iterative loop catches it
   -- and falls back to the last fully completed iteration.
   Search_Interrupted : exception;

   -- Checking the clock only every Check_Interval nodes keeps the overhead
   -- negligible while still bounding the overshoot.
   Check_Interval : constant := 1024;
   Max_Ply        : constant := 128;

   -- Delta pruning margin (quiescence): a capture whose victim plus this
   -- margin cannot reach alpha is not searched.
   Delta_Margin : constant Score_Type := 200;

   ---------------
   -- TT helpers --
   ---------------

   type Bound_Type is (Exact, Lower_Bound, Upper_Bound);

   type TT_Entry is
      record
         Hash_Key : Bitboard := 0;
         Depth    : Integer := -1;
         Bound    : Bound_Type := Exact;
         Score    : Score_Type := 0;
         Move     : Packed_Move := 0;
         Age      : Natural := 0;
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

   function Adjust_Score (S : Score_Type; Ply : Natural) return Score_Type is
   begin
      if S >= Mate_Threshold then
         return S - Ply;
      elsif S <= -Mate_Threshold then
         return S + Ply;
      end if;
      return S;
   end Adjust_Score;

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
   -- Under Lazy SMP the table is written without locking: races are benign
   -- (a torn entry simply fails the key test on read).
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
           or else Depth >= Old.Depth
           or else Old.Age < TT_Generation;
      end;

      if Repl then
         Transposition_Table (Slot) :=
           (Hash_Key => Position.Key, Depth => Depth, Bound => Bound,
            Score => Saved, Move => Packed, Age => TT_Generation);
      end if;
   end Store;

   ---------------------
   -- Search context --
   ---------------------

   type Killer_Array is array (1 .. 2, 0 .. Max_Ply) of Move_Type;
   type History_Array is
     array (Color_Type, Square_Type, Square_Type) of Score_Type;
   type Path_Array is array (0 .. Max_Ply) of Bitboard;

   type Search_Context is
      record
         Killers          : Killer_Array := (others => (others => Empty_Move));
         History          : History_Array := (others => (others => (others => 0)));
         Search_Path      : Path_Array := (others => 0);
         Game_Keys        : Game_Key_Array := (others => 0);
         Game_Key_Count   : Natural := 0;
         Nodes_Count      : Natural := 0;
         Next_Checkpoint  : Natural := Check_Interval;
         Time_Limit_Armed : Boolean := False;
         Start_Time       : Time := Clock;
         Time_Budget      : Duration := 0.0;
      end record;
   type Context_Access is access all Search_Context;

   -- Keys of the game so far, copied into each thread's context.
   Init_Game_Keys  : Game_Key_Array := (others => 0);
   Init_Game_Key_Count : Natural := 0;

   -- Set by the primary thread to stop the helpers promptly.
   Stop_Search : Boolean := False;
   pragma Atomic (Stop_Search);

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
                           Budget : in Duration) is
   begin
      Ctx.Killers := (others => (others => Empty_Move));
      Ctx.History := (others => (others => (others => 0)));
      Ctx.Search_Path := (others => 0);
      Ctx.Game_Key_Count := Init_Game_Key_Count;
      for I in 0 .. Init_Game_Key_Count - 1 loop
         Ctx.Game_Keys (I) := Init_Game_Keys (I);
      end loop;
      Ctx.Nodes_Count := 0;
      Ctx.Next_Checkpoint := Check_Interval;
      Ctx.Time_Limit_Armed := Arm;
      Ctx.Time_Budget := Budget;
      Ctx.Start_Time := Clock;
   end Init_Context;

   procedure Poll_Time (Ctx : in Context_Access) is
   begin
      Ctx.Nodes_Count := Ctx.Nodes_Count + 1;
      if Ctx.Nodes_Count >= Ctx.Next_Checkpoint then
         Ctx.Next_Checkpoint := Ctx.Nodes_Count + Check_Interval;
         if Stop_Search then
            raise Search_Interrupted;
         end if;
         if Ctx.Time_Limit_Armed
           and then To_Duration (Clock - Ctx.Start_Time) >= Ctx.Time_Budget
         then
            raise Search_Interrupted;
         end if;
      end if;
   end Poll_Time;

   -------------------------------
   -- Move ordering helpers --
   -------------------------------

   -- Piece values in centipawns (mirrors the evaluation), used by MVV-LVA.
   function Kind_Value (Kind : in Kind_Type) return Score_Type is
   begin
      case Kind is
         when Pawn   => return 100;
         when Knight => return 320;
         when Bishop => return 330;
         when Rook   => return 500;
         when Queen  => return 900;
         when King   => return 0;
      end case;
   end Kind_Value;

   function Is_Tactical (Position : in Position_Type; Move : in Move_Type)
     return Boolean is
   begin
      if Move.Flag in En_Passant | Promotion then
         return True;
      end if;
      return (Color_Board (Position, Opposite (Position.Side)) and Bit (Move.To)) /= 0;
   end Is_Tactical;

   History_Max : constant Score_Type := 16_384;

   -- History bonus of a quiet move that produced a beta cutoff at Depth.
   -- Quadratic in the depth so that deep cutoffs dominate, and capped so a
   -- single update can never saturate the table (it stays far below the
   -- killer and capture scores used by Order).
   function History_Bonus (Depth : in Natural) return Score_Type is
      B : constant Score_Type := Score_Type (Depth) * Score_Type (Depth);
   begin
      if B > 1024 then
         return 1024;
      end if;
      return B;
   end History_Bonus;

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

   -- Move ordering score: hash move first, then captures (MVV-LVA), then
   -- promotions, then the killers, then quiet moves ordered by the history
   -- heuristic (moves that already produced beta cutoffs elsewhere).
   function Order (Ctx        : in Context_Access;
                   Position   : in Position_Type;
                   Move       : in Move_Type;
                   Hash_Move  : in Move_Type;
                   Ply        : in Natural) return Score_Type is
   begin
      if Move = Hash_Move then
         return 100_000_000;
      end if;

      if Move.Flag = Promotion then
         return 50_000_000 + Kind_Value (Kind (Move.Promotion));
      end if;

      if Is_Tactical (Position, Move) then
         declare
            Victim   : constant Score_Type :=
              Kind_Value (Captured_Kind (Position, Move));
            Attacker : constant Score_Type := Kind_Value (Kind (Move.Piece));
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
      end if;
      return Ctx.History (Color (Move.Piece), Move.From, Move.To);
   end Order;

   -- XBoard thinking output ("post"/"nopost"). When enabled, the primary
   -- thread prints one line per completed iteration:
   --    depth score time nodes bestmove
   Post_Output : Boolean := False;

   procedure Set_Post (On : in Boolean) is
   begin
      Post_Output := On;
   end Set_Post;

   procedure Report_Iteration (Depth      : in Natural;
                               Score      : in Score_Type;
                               Elapsed    : in Duration;
                               Nodes      : in Natural;
                               Best       : in Move_Type) is
      Centis : constant Long_Integer :=
        Long_Integer (Elapsed * 100.0);
      Disp   : Score_Type := Score;
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

      Ada.Text_IO.Put
        (Natural'Image (Depth) & " " & Score_Type'Image (Disp)
         & " " & Long_Integer'Image (Centis)
         & " " & Natural'Image (Nodes));
      if Best /= Empty_Move then
         Ada.Text_IO.Put (" " & To_String (Best));
      end if;
      Ada.Text_IO.New_Line;
      Ada.Text_IO.Flush;
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

   ----------------
   -- Quiescence --
   ----------------

   function Quiescence (Ctx        : in Context_Access;
                        Position   : in out Position_Type;
                        Alpha, Beta : in Score_Type;
                        Ply        : in Natural) return Score_Type
   is
      A        : Score_Type := Alpha;
      B        : Score_Type := Beta;
      In_Check : Boolean := King_In_Check (Position, Position.Side);
      Stand    : Score_Type := 0;
      Moves    : Move_List;
      Count    : Natural;
      Limit    : Natural;
   begin
      Poll_Time (Ctx);

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
         -- there is no need to generate the (numerous) quiet moves.
         Generate_Legal_Tactical_Moves (Position, Moves, Count);
      end if;

      if Count = 0 and then In_Check then
         return -(Mate_Score - Ply);
      end if;

      -- Move the tactical moves (captures / promotions) to the front, then
      -- order them by MVV so the most promising captures are tried first.
      declare
         T : Natural := 0;
      begin
         for I in 1 .. Count loop
            if Is_Tactical (Position, Moves (I)) then
               T := T + 1;
               declare
                  Tmp : constant Move_Type := Moves (T);
               begin
                  Moves (T) := Moves (I);
                  Moves (I) := Tmp;
               end;
            end if;
         end loop;

         for I in 1 .. T loop
            declare
               Best_J : Natural := I;
               Best_V : Score_Type :=
                 Kind_Value (Captured_Kind (Position, Moves (I)));
            begin
               for J in I + 1 .. T loop
                  declare
                     V : constant Score_Type :=
                       Kind_Value (Captured_Kind (Position, Moves (J)));
                  begin
                     if V > Best_V then
                        Best_V := V;
                        Best_J := J;
                     end if;
                  end;
               end loop;
               if Best_J /= I then
                  declare
                     Tmp : constant Move_Type := Moves (I);
                  begin
                     Moves (I) := Moves (Best_J);
                     Moves (Best_J) := Tmp;
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
            -- (promotions and evasions out of check are always kept).
            if (not In_Check)
              and then Moves (I).Flag /= Promotion
              and then (Static_Exchange_Value (Position, Moves (I)) < 0
                        or else Stand
                          + Kind_Value (Captured_Kind (Position, Moves (I)))
                          + Delta_Margin <= A)
            then
               null;
            else
               declare
                  Undo  : Undo_Info;
                  Score : Score_Type;
               begin
                  Make_Move (Position, Moves (I), Undo);
                  Score := -Quiescence (Ctx, Position, -B, -A, Ply + 1);
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

   -- Reverse futility margin at depth 1.
   Futility_Margin : constant Score_Type := 180;

   -- Futility pruning: a quiet move is not searched when the static eval
   -- plus this margin (scaled by the depth) is still below alpha.
   Futility_Base : constant Score_Type := 120;

   -- Razoring: below alpha by this margin (scaled by the depth) the node is
   -- resolved by a quiescence search instead of the full-width search.
   Razor_Margin : constant Score_Type := 300;

   -- Aspiration window around the previous iteration score (centipawns).
   Aspiration_Window : constant Score_Type := 40;

   -- Null move reduction.
   Null_Reduction  : constant := 2;

   -- Late-move reduction table: reduction applied to a late quiet move as a
   -- function of the remaining depth and the move index (both capped), from
   -- the classic log formula, precomputed once at elaboration.
   LMR_Max_Depth : constant := 64;
   LMR_Max_Move  : constant := 64;
   type LMR_Array is array (1 .. LMR_Max_Depth, 1 .. LMR_Max_Move) of Natural;

   function Compute_LMR return LMR_Array is
      use Ada.Numerics.Elementary_Functions;
      R : Float;
      T : LMR_Array := (others => (others => 0));
   begin
      for D in 1 .. LMR_Max_Depth loop
         for M in 1 .. LMR_Max_Move loop
            R := 0.75 + Log (Float (D)) * Log (Float (M)) / 2.25;
            if R < 0.0 then
               R := 0.0;
            end if;
            T (D, M) := Natural (R);
         end loop;
      end loop;
      return T;
   end Compute_LMR;

   LMR_Table : constant LMR_Array := Compute_LMR;

   function Negamax (Ctx        : in Context_Access;
                     Position   : in out Position_Type;
                     Depth, Ply : in Natural;
                     Alpha, Beta : in Score_Type;
                     Excluded   : in Move_Type := Empty_Move) return Score_Type
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
      TT_Bound    : Bound_Type := Exact;
      TT_Depth    : Integer := -1;
      Have_TT     : Boolean := False;
      Singular_Ext : Natural := 0;
   begin
      Poll_Time (Ctx);

      -- Terminal draws: the fifty-move rule and dead positions are scored
      -- as draws before anything else, including the quiescence call.
      if Position.Halfmove >= 100
        or else Insufficient_Material (Position)
      then
         return 0;
      end if;

      if Depth = 0 then
         return Quiescence (Ctx, Position, A, B, Ply);
      end if;

      -- Record the current node on the search path (for the repetition
      -- detection of its descendants) and claim a draw on a repetition
      -- before trusting the transposition table.
      if Ply <= Max_Ply then
         Ctx.Search_Path (Ply) := Position.Key;
      end if;
      if Is_Repetition (Ctx, Position, Ply) then
         return 0;
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

      -- Transposition table probe (two-way bucket).
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
            TT_Bound := E.Bound;
            TT_Depth := E.Depth;
            Have_TT  := True;
            if E.Depth >= Depth and then Excluded = Empty_Move then
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
            if Hash_Move = Excluded then
               Hash_Move := Empty_Move;
            end if;
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
            Q : constant Score_Type := Quiescence (Ctx, Position, A, B, Ply);
         begin
            if Q < Alpha then
               return Q;
            end if;
         end;
      end if;

      -- Check extension: evasions are forced, so an in-check node is
      -- searched one ply deeper than a quiet one. Bounded by Ply so that a
      -- long checking sequence cannot explode the search.
      if In_Check and then Depth >= 1 and then Ply <= Max_Ply - 4 then
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
            Saved   : Position_Type := Position;
            N_Score : Score_Type;
         begin
            Position.Side := Opposite (Position.Side);
            if Position.En_Passant /= Ep_None then
               Position.Key :=
                 Position.Key xor Hash.Ep_Key (Position.En_Passant mod 8);
            end if;
            Position.En_Passant := Ep_None;
            Position.Key := Position.Key xor Hash.Side_Key;

            N_Score := -Negamax (Ctx, Position, Depth - 1 - Null_Reduction,
                                 Ply + 1, -B, -B + 1);

            Position := Saved;
            if N_Score >= B then
               return N_Score;
            end if;
         end;
      end if;

      -- Singular extension: when the transposition-table move is clearly
      -- better than every alternative at reduced depth, search it one ply
      -- deeper. The probe searches this position with the reference move
      -- excluded; Excluded also disables the TT cutoff and the TT store.
      if Depth >= 8 and then Excluded = Empty_Move
        and then Hash_Move /= Empty_Move and then not In_Check
        and then Have_TT and then TT_Depth >= Depth - 3
        and then TT_Bound /= Upper_Bound
      then
         declare
            Sing_Beta  : constant Score_Type :=
              TT_Score - 2 * Score_Type (Depth);
            Sing_Score : constant Score_Type :=
              Negamax (Ctx, Position, (Depth - 1) / 2, Ply,
                       Sing_Beta - 1, Sing_Beta, Excluded => Hash_Move);
         begin
            if Sing_Score < Sing_Beta then
               Singular_Ext := 1;
            end if;
         end;
      end if;

      -- Move ordering, then PVS over the children.
      declare
         Ord : array (1 .. 256) of Score_Type;
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Ctx, Position, Moves (J), Hash_Move, Ply);
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
               Tactical : constant Boolean := Is_Tactical (Position, Moves (I));
               Reduction : Natural := 0;
               Move_Depth : Natural := Child_Depth;
            begin
               -- In a singular-extension probe the reference move is excluded.
               if Moves (I) = Excluded then
                  goto Next_Move;
               end if;

               -- Late move pruning: at low depth the late quiet moves are
               -- simply skipped (they are ordered last and almost never
               -- improve on the already searched moves).
               if not In_Check and then not Tactical
                 and then Depth <= 3
                 and then Best_Score > -Mate_Threshold
                 and then I > 4 + Depth * Depth
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

               -- Singular hash move: search it one ply deeper.
               if Moves (I) = Hash_Move and then Singular_Ext > 0 then
                  Move_Depth := Child_Depth + Singular_Ext;
               end if;

               Make_Move (Position, Moves (I), Undo);

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
               -- the history heuristic learns to avoid it.
               if not Tactical and then Ply <= Max_Ply
                 and then Score <= Alpha
               then
                  Bump_History (Ctx, Position.Side, Moves (I).From,
                                Moves (I).To, -History_Bonus (Depth));
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
                  end if;
                  if Excluded = Empty_Move then
                     Store (Position, Depth, Lower_Bound, Score,
                            Best_Move_Here, Ply);
                  end if;
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
         if Excluded = Empty_Move then
            Store (Position, Depth, Bound, A, Best_Move_Here, Ply);
         end if;
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
      B          : Score_Type := Beta;
      Best       : Move_Type := Empty_Move;
      Best_Sc    : Score_Type := -Infinity;
   begin
      Generate_Legal_Moves (Position, Root_Moves, Count);

      if Count = 0 then
         Best_Score := 0;
         return Empty_Move;
      end if;

      declare
         Ord : array (1 .. 256) of Score_Type;
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Ctx, Position, Root_Moves (J), Prev_Best, 0);
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
                              Report     : in Boolean) return Thread_Result
   is
      Result     : Thread_Result;
      Work       : Position_Type := Position;
      Best       : Move_Type := Empty_Move;
      Best_Score : Score_Type := 0;
      Alpha      : Score_Type := -Infinity;
      Beta       : Score_Type := Infinity;
      Score      : Score_Type;
      T0         : constant Time := Clock;
      Nodes_Base : constant Natural := Ctx.Nodes_Count;
      Completed  : Boolean := False;
      Last_Depth : Natural := 0;
   begin
      Work.Key := Hash.Compute (Work);

      begin
         for D in 1 .. Max_Depth loop
            if Time_Alloc > 0.0
              and then To_Duration (Clock - Ctx.Start_Time) >= Time_Alloc
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

            if Report then
               Report_Iteration (D, Best_Score, To_Duration (Clock - T0),
                                 Ctx.Nodes_Count - Nodes_Base, Best);
            end if;

            exit when Abs (Best_Score) >= Mate_Score - 200;
         end loop;
      exception
         when Search_Interrupted =>
            -- Current iteration cut short by the deadline: keep the move of
            -- the last fully completed iteration (if any).
            null;
      end;

      if Completed then
         Result.Best := Best;
         Result.Score := Best_Score;
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

   -----------------
   -- Best_Move (fixed depth) --
   -----------------

   function Best_Move (Position : in Position_Type; Depth : in Natural)
     return Move_Type is
      Ctx    : constant Context_Access := new Search_Context;
      Result : Thread_Result;
   begin
      if Depth = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      Init_Context (Ctx, Arm => False, Budget => 0.0);
      TT_Generation := TT_Generation + 1;

      Result := Iterative_Search (Ctx, Position, Depth, 0.0, False);
      Accum_Nodes := Accum_Nodes + Ctx.Nodes_Count;

      if Result.Best = Empty_Move then
         return Quick_Move (Position);
      end if;
      return Result.Best;
   end Best_Move;

   -------------------------
   -- Lazy SMP (threads) --
   -------------------------

   Max_Threads : constant := 16;
   Num_Threads : Natural := 1;

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

   protected type Completion is
      procedure Reset;
      procedure Signal;
      entry Wait_All;
   private
      Count : Natural := 0;
   end Completion;

   protected body Completion is
      procedure Reset is
      begin
         Count := 0;
      end Reset;

      procedure Signal is
      begin
         Count := Count + 1;
      end Signal;

      entry Wait_All when Count >= Num_Threads is
      begin
         null;
      end Wait_All;
   end Completion;

   Done : Completion;

   Root_Position  : Position_Type;
   Root_Max_Depth : Natural := 1;
   Root_Time      : Duration := 0.0;
   Results        : array (1 .. Max_Threads) of Thread_Result;

   task type Searcher (Id : Positive);

   task body Searcher is
      Ctx : constant Context_Access := new Search_Context;
   begin
      Init_Context (Ctx, Arm => Root_Time > 0.0, Budget => Root_Time);
      Results (Id) := Iterative_Search (Ctx, Root_Position,
                                        Root_Max_Depth, Root_Time,
                                        Report => (Id = 1));
      -- The primary thread stops the helpers as soon as it is done.
      if Id = 1 then
         Stop_Search := True;
      end if;
      Done.Signal;
   end Searcher;

   type Searcher_Access is access Searcher;

   function Best_Move (Position   : in Position_Type;
                       Max_Depth  : in Natural;
                       Time_Alloc : in Duration) return Move_Type
   is
      Best : Move_Type := Empty_Move;
   begin
      if Max_Depth = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      TT_Generation := TT_Generation + 1;

      if Num_Threads <= 1 then
         declare
            Ctx    : constant Context_Access := new Search_Context;
            Result : Thread_Result;
         begin
            Init_Context (Ctx, Arm => Time_Alloc > 0.0, Budget => Time_Alloc);
            Result := Iterative_Search (Ctx, Position, Max_Depth,
                                        Time_Alloc, True);
            Accum_Nodes := Accum_Nodes + Ctx.Nodes_Count;
            if Result.Best = Empty_Move then
               return Quick_Move (Position);
            end if;
            return Result.Best;
         end;
      end if;

      -- Multi-threaded Lazy SMP.
      Root_Position := Position;
      Root_Max_Depth := Max_Depth;
      Root_Time := Time_Alloc;
      Stop_Search := False;
      Done.Reset;

      declare
         Workers : array (1 .. Num_Threads) of Searcher_Access;
      begin
         for I in 1 .. Num_Threads loop
            Results (I) := (Best => Empty_Move, Score => -Infinity,
                            Depth => 0, Nodes => 0);
            Workers (I) := new Searcher (I);
         end loop;

         Done.Wait_All;
      end;

      -- Node accounting and result selection (the deepest, then best score).
      declare
         Best_Depth : Natural := 0;
         Best_Score : Score_Type := -Infinity;
      begin
         for I in 1 .. Num_Threads loop
            Accum_Nodes := Accum_Nodes + Results (I).Nodes;
            if Results (I).Best /= Empty_Move
              and then (Results (I).Depth > Best_Depth
                        or else (Results (I).Depth = Best_Depth
                                 and then Results (I).Score > Best_Score))
            then
               Best_Depth := Results (I).Depth;
               Best_Score := Results (I).Score;
               Best := Results (I).Best;
            end if;
         end loop;
      end;

      if Best = Empty_Move then
         Best := Quick_Move (Position);
      end if;
      return Best;
   end Best_Move;

end BBChess.Search;
