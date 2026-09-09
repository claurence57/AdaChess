--
--  AdaChess-BB : alpha-beta search (body)
--
--  Iterative deepening with a transposition table, PVS at the root and at
--  every node, move ordering (hash move, MVV-LVA captures, killers), a
--  light LMR, null-move pruning and reverse futility pruning, plus a
--  bounded quiescence search on tactical moves. The search is interruptible
--  (a deadline is polled inside the recursion), which bounds the worst-case
--  duration of a move.
--

with Ada.Real_Time;
use Ada.Real_Time;

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Eval;
use BBChess.Eval;

package body BBChess.Search is

   -- Raised (from Poll_Time) when the per-move time budget is exhausted
   -- while the search is still running. Best_Move (the timed variant)
   -- catches it and falls back to the last fully completed iteration.
   Search_Interrupted : exception;

   -- Deadline shared between the iterative loop and the recursive search.
   -- A deadline is armed only for the timed Best_Move; the fixed-depth
   -- Best_Move (analysis / self tests) runs without any limit.
   Check_Interval   : constant := 1024;
   Nodes_Count      : Natural := 0;
   Next_Checkpoint  : Natural := Check_Interval;
   Time_Limit_Armed : Boolean := False;
   Start_Time       : Time;
   Time_Budget      : Duration := 0.0;

   procedure Arm_Time_Limit (Budget : in Duration) is
   begin
      Time_Limit_Armed := True;
      Time_Budget      := Budget;
      Start_Time       := Clock;
      Nodes_Count      := 0;
      Next_Checkpoint  := Check_Interval;
   end Arm_Time_Limit;

   procedure Disarm_Time_Limit is
   begin
      Time_Limit_Armed := False;
   end Disarm_Time_Limit;

   -- Called at every search node. Checking the clock only every
   -- Check_Interval nodes keeps the overhead negligible while still
   -- bounding the overshoot to about one interval worth of nodes.
   procedure Poll_Time is
   begin
      Nodes_Count := Nodes_Count + 1;
      if Nodes_Count >= Next_Checkpoint then
         Next_Checkpoint := Nodes_Count + Check_Interval;
         if Time_Limit_Armed
           and then To_Duration (Clock - Start_Time) >= Time_Budget
         then
            raise Search_Interrupted;
         end if;
      end if;
   end Poll_Time;

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
         Move     : Move_Type := Empty_Move;
      end record;

   TT_Size   : constant := 1_048_576;
   TT_Mask   : constant := TT_Size - 1;
   type TT_Table is array (0 .. TT_Size - 1) of TT_Entry;
   Transposition_Table : TT_Table;

   Mate_Threshold : constant Score_Type := Mate_Score - 1000;

   function TT_Index (Position : in Position_Type) return Natural is
   begin
      return Natural (Position.Key and TT_Mask);
   end TT_Index;

   procedure Clear_Transposition_Table is
   begin
      -- Cleared entry by entry: an aggregate assignment of the whole table
      -- would be built on the (limited) main-thread stack.
      for I in Transposition_Table'Range loop
         Transposition_Table (I) :=
           (Hash_Key => 0, Depth => -1, Bound => Exact,
            Score => 0, Move => Empty_Move);
      end loop;
   end Clear_Transposition_Table;

   -- Store a node. Mate scores are normalized by the distance to the root
   -- so they stay comparable across different depths.
   procedure Store (Position : in Position_Type;
                    Depth     : in Natural;
                    Bound     : in Bound_Type;
                    Score     : in Score_Type;
                    Move      : in Move_Type;
                    Ply       : in Natural)
   is
      Idx   : constant Natural := TT_Index (Position);
      Saved : Score_Type := Score;
   begin
      if Saved >= Mate_Threshold then
         Saved := Saved + Ply;
      elsif Saved <= -Mate_Threshold then
         Saved := Saved - Ply;
      end if;

      if Transposition_Table (Idx).Depth < 0
        or else Depth >= Transposition_Table (Idx).Depth
      then
         Transposition_Table (Idx) :=
           (Hash_Key => Position.Key, Depth => Depth, Bound => Bound,
            Score => Saved, Move => Move);
      end if;
   end Store;

   function Stored_Score (Position : in Position_Type; Ply : in Natural)
     return Score_Type is
      S : Score_Type := Transposition_Table (TT_Index (Position)).Score;
   begin
      if S >= Mate_Threshold then
         S := S - Ply;
      elsif S <= -Mate_Threshold then
         S := S + Ply;
      end if;
      return S;
   end Stored_Score;

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

   ---------------
   -- Capture ? --
   ---------------

   function Is_Tactical (Position : in Position_Type; Move : in Move_Type)
     return Boolean is
   begin
      if Move.Flag in En_Passant | Promotion then
         return True;
      end if;
      return (Color_Board (Position, Opposite (Position.Side)) and Bit (Move.To)) /= 0;
   end Is_Tactical;

   -- Killers for the current search (cleared between moves).
   Max_Ply : constant := 128;
   Killers : array (1 .. 2, 0 .. Max_Ply) of Move_Type :=
     (others => (others => Empty_Move));

   procedure Reset_Killers is
   begin
      Killers := (others => (others => Empty_Move));
   end Reset_Killers;

   function Has_Non_Pawn (Position : in Position_Type; Color : in Color_Type)
     return Boolean is
   begin
      return (Position.Pieces (Make (Color, Knight))
              or Position.Pieces (Make (Color, Bishop))
              or Position.Pieces (Make (Color, Rook))
              or Position.Pieces (Make (Color, Queen))) /= 0;
   end Has_Non_Pawn;

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
   -- promotions, then the killers, then everything else.
   function Order (Position   : in Position_Type;
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
         if Move = Killers (1, Ply) then
            return 1_000_000;
         elsif Move = Killers (2, Ply) then
            return 900_000;
         end if;
      end if;
      return 0;
   end Order;

   ----------------
   -- Quiescence --
   ----------------

   function Quiescence (Position : in out Position_Type;
                        Alpha, Beta : in Score_Type;
                        Ply        : in Natural) return Score_Type
   is
      A     : Score_Type := Alpha;
      B     : Score_Type := Beta;
      Stand : Score_Type := Evaluate (Position);
      Moves : Move_List;
      Count : Natural;
   begin
      Poll_Time;
      if Stand >= B then
         return Stand;
      end if;
      if Stand > A then
         A := Stand;
      end if;

      Hash.Set_Keys_Enabled (False);
      Generate_Legal_Moves (Position, Moves, Count);
      Hash.Set_Keys_Enabled (True);

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

         for I in 1 .. T loop
            declare
               Undo  : Undo_Info;
               Score : Score_Type;
            begin
               Make_Move (Position, Moves (I), Undo);
               Score := -Quiescence (Position, -B, -A, Ply + 1);
               Unmake_Move (Position, Moves (I), Undo);

               if Score >= B then
                  return Score;
               end if;
               if Score > A then
                  A := Score;
               end if;
            end;
         end loop;
      end;

      return A;
   end Quiescence;

   -------------
   -- Negamax --
   -------------

   -- Reverse futility margin at depth 1.
   Futility_Margin : constant Score_Type := 180;

   -- Null move reduction.
   Null_Reduction  : constant := 2;

   function Negamax (Position : in out Position_Type;
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
   begin
      Poll_Time;
      if Depth = 0 then
         return Quiescence (Position, A, B, Ply);
      end if;

      -- Transposition table probe.
      declare
         E : TT_Entry renames Transposition_Table (TT_Index (Position));
      begin
         if E.Hash_Key = Position.Key and then E.Depth >= Depth then
            declare
               S : constant Score_Type := Stored_Score (Position, Ply);
            begin
               case E.Bound is
                  when Exact =>
                     return S;
                  when Lower_Bound =>
                     if S >= B then
                        return S;
                     end if;
                  when Upper_Bound =>
                     if S <= A then
                        return S;
                     end if;
               end case;
            end;
         end if;
         Hash_Move := E.Move;
      end;

      -- Move generation does not need the Zobrist key: keep it disabled so
      -- that the per-candidate make/unmake legality tests stay cheap.
      Hash.Set_Keys_Enabled (False);
      Generate_Legal_Moves (Position, Moves, Count);
      Hash.Set_Keys_Enabled (True);

      if Count = 0 then
         if King_In_Check (Position, Position.Side) then
            return -(Mate_Score - Ply);
         else
            return 0;
         end if;
      end if;

      if Depth = 1 or else Depth >= 3 then
         In_Check := King_In_Check (Position, Position.Side);
      end if;

      -- Reverse futility pruning: a quiet, already decisive advantage at the
      -- horizon can be returned without searching.
      if Depth = 1 and then not In_Check then
         declare
            Eval_Now : constant Score_Type := Evaluate (Position);
         begin
            if Eval_Now - Futility_Margin >= B then
               return Eval_Now;
            end if;
         end;
      end if;

      -- Null-move pruning (skip in pawn-only endgames / when in check).
      if Depth >= 3 and then not In_Check
        and then Has_Non_Pawn (Position, Position.Side)
      then
         declare
            Saved   : Position_Type := Position;
            N_Score : Score_Type;
         begin
            -- Give the move to the opponent for a reduced search.
            Position.Side := Opposite (Position.Side);
            Position.En_Passant := Ep_None;
            Position.Key := Hash.Compute (Position);

            N_Score := -Negamax (Position, Depth - 1 - Null_Reduction,
                                 Ply + 1, -B, -B + 1);

            Position := Saved;
            if N_Score >= B then
               return N_Score;
            end if;
         end;
      end if;

      -- Move ordering, then PVS over the children.
      declare
         Ord : array (1 .. 256) of Score_Type;
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Position, Moves (J), Hash_Move, Ply);
         end loop;

         for I in 1 .. Count loop
            -- Select the best remaining move (cheap for the small branching
            -- factor here, keeps the list itself unmodified for the TT).
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
            begin
               Make_Move (Position, Moves (I), Undo);

               if I = 1 then
                  Score := -Negamax (Position, Depth - 1, Ply + 1, -B, -A);
               else
                  -- PVS: null-window first, re-searched on a fail high.
                  -- Late quiet moves get a one-ply LMR.
                  if not Tactical and then Depth >= 3 and then I >= 4
                    and then not In_Check
                  then
                     Score := -Negamax (Position, Depth - 2, Ply + 1,
                                        -A - 1, -A);
                     if Score > A and then Score < B then
                        Score := -Negamax (Position, Depth - 1, Ply + 1,
                                           -B, -A);
                     end if;
                  else
                     Score := -Negamax (Position, Depth - 1, Ply + 1,
                                        -A - 1, -A);
                     if Score > A and then Score < B then
                        Score := -Negamax (Position, Depth - 1, Ply + 1,
                                           -B, -A);
                     end if;
                  end if;
               end if;

               Unmake_Move (Position, Moves (I), Undo);

               if Score > Best_Score then
                  Best_Score := Score;
                  Best_Move_Here := Moves (I);
               end if;
               if Score >= B then
                  if not Tactical and then Ply <= Max_Ply then
                     if Killers (1, Ply) /= Moves (I) then
                        Killers (2, Ply) := Killers (1, Ply);
                        Killers (1, Ply) := Moves (I);
                     end if;
                  end if;
                  Store (Position, Depth, Lower_Bound, Score, Best_Move_Here, Ply);
                  return Score;
               end if;
               if Score > A then
                  A := Score;
               end if;
            end;
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

   function Root_Search (Position : in out Position_Type;
                         Depth     : in Natural;
                         Prev_Best : in Move_Type;
                         Best_Score : out Score_Type) return Move_Type
   is
      Root_Moves : Move_List;
      Count      : Natural;
      Alpha      : Score_Type := -Infinity;
      Beta       : Score_Type := Infinity;
      Best       : Move_Type := Empty_Move;
      Best_Sc    : Score_Type := -Infinity;
   begin
      Hash.Set_Keys_Enabled (False);
      Generate_Legal_Moves (Position, Root_Moves, Count);
      Hash.Set_Keys_Enabled (True);

      if Count = 0 then
         Best_Score := 0;
         return Empty_Move;
      end if;

      declare
         Ord : array (1 .. 256) of Score_Type;
      begin
         for J in 1 .. Count loop
            Ord (J) := Order (Position, Root_Moves (J), Prev_Best, 0);
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
                  Score := -Negamax (Position, Depth - 1, 1, -Beta, -Alpha);
               else
                  Score := -Negamax (Position, Depth - 1, 1, -Alpha - 1, -Alpha);
                  if Score > Alpha and then Score < Beta then
                     Score := -Negamax (Position, Depth - 1, 1, -Beta, -Alpha);
                  end if;
               end if;

               Unmake_Move (Position, Root_Moves (I), Undo);

               if Score > Best_Sc then
                  Best_Sc := Score;
                  Best    := Root_Moves (I);
               end if;
               if Score > Alpha then
                  Alpha := Score;
               end if;
            end;
         end loop;
      end;

      if Best /= Empty_Move then
         -- Feed the root best move back to the TT for the next iteration.
         Store (Position, Depth, Exact, Best_Sc, Best, 0);
      end if;

      Best_Score := Best_Sc;
      return Best;
   end Root_Search;

   -----------------
   -- Best_Move --
   -----------------

   function Best_Move (Position : in Position_Type; Depth : in Natural)
     return Move_Type is
      Best       : Move_Type := Empty_Move;
      Best_Score : Score_Type := 0;
      Work       : Position_Type := Position;
   begin
      if Depth = 0 then
         return Empty_Move;
      end if;

      Disarm_Time_Limit;
      Hash.Set_Keys_Enabled (True);
      Work.Key := Hash.Compute (Work);
      Clear_Transposition_Table;
      Reset_Killers;

      for D in 1 .. Depth loop
         Best := Root_Search (Work, D, Best, Best_Score);
         exit when Abs (Best_Score) >= Mate_Score - 200;
      end loop;

      return Best;
   end Best_Move;

   ---------------------
   -- Quick_Move --
   ---------------------

   -- Safety net used when the time budget is so small that not even the
   -- first iteration completes: return a legal move without searching.
   -- Tactical moves (captures / promotions) are preferred, otherwise the
   -- first legal move of the list.
   function Quick_Move (Position : in Position_Type) return Move_Type is
      Moves    : Move_List;
      Count    : Natural;
      Fallback : Move_Type := Empty_Move;
   begin
      Hash.Set_Keys_Enabled (False);
      Generate_Legal_Moves (Position, Moves, Count);
      Hash.Set_Keys_Enabled (True);
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

   ------------------------
   -- Best_Move (time) --
   ------------------------

   function Best_Move (Position   : in Position_Type;
                       Max_Depth  : in Natural;
                       Time_Alloc : in Duration) return Move_Type is
      Best        : Move_Type := Empty_Move;
      Best_Score  : Score_Type := 0;
      Work        : Position_Type := Position;
      Completed   : Boolean := False;
   begin
      if Max_Depth = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      Work.Key := Hash.Compute (Work);
      Clear_Transposition_Table;
      Reset_Killers;

      Disarm_Time_Limit;
      if Time_Alloc > 0.0 then
         Arm_Time_Limit (Time_Alloc);
      end if;

      begin
         for D in 1 .. Max_Depth loop
            if Time_Alloc > 0.0
              and then To_Duration (Clock - Start_Time) >= Time_Alloc
            then
               exit;
            end if;

            Best := Root_Search (Work, D, Best, Best_Score);
            Completed := True;

            exit when Abs (Best_Score) >= Mate_Score - 200;
         end loop;
      exception
         when Search_Interrupted =>
            -- Current iteration cut short by the deadline: keep the move of
            -- the last fully completed iteration (if any).
            null;
      end;

      Disarm_Time_Limit;

      if not Completed or else Best = Empty_Move then
         -- No iteration completed within the budget (or the side to move has
         -- no legal move). Return something legal without searching more.
         Best := Quick_Move (Position);
      end if;

      return Best;
   end Best_Move;

end BBChess.Search;
