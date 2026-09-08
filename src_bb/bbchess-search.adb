--
--  AdaChess-BB : alpha-beta search (body)
--
--  Iterative deepening with a transposition table (single slot per index)
--  and quiescence search. The best move of the previous iteration is tried
--  first at the root.
--

with Ada.Real_Time;

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Eval;
use BBChess.Eval;

package body BBChess.Search is

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

   TT_Size   : constant := 65_536;
   TT_Mask   : constant := TT_Size - 1;
   type TT_Table is array (0 .. TT_Size - 1) of TT_Entry;
   Transposition_Table : TT_Table := (others => <>);

   Mate_Threshold : constant Score_Type := Mate_Score - 1000;

   function TT_Index (Position : in Position_Type) return Natural is
   begin
      return Natural (Position.Key and TT_Mask);
   end TT_Index;

   procedure Clear_Transposition_Table is
   begin
      Transposition_Table := (others => <>);
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

   ----------------
   -- Quiescence --
   ----------------

   Quiescence_Limit : constant Natural := 4;

   function Quiescence (Position : in out Position_Type;
                        Alpha, Beta : in Score_Type;
                        Ply, Q_Left : in Natural) return Score_Type
   is
      A     : Score_Type := Alpha;
      B     : Score_Type := Beta;
      Stand : Score_Type := Evaluate (Position);
   begin
      if Stand >= B then
         return Stand;
      end if;
      if Stand > A then
         A := Stand;
      end if;

      -- Hard bound on the quiescence depth: after too many quiet-off
      -- plies, simply stand pat (avoids search explosions).
      if Q_Left = 0 then
         return A;
      end if;

      declare
         Moves : Move_List;
         Count : Natural;
      begin
         Generate_Legal_Tactical_Moves (Position, Moves, Count);

         for I in 1 .. Count loop
            if Is_Tactical (Position, Moves (I)) then
               declare
                  Undo  : Undo_Info;
                  Score : Score_Type;
               begin
                  Make_Move (Position, Moves (I), Undo);
                  Score := -Quiescence (Position, -B, -A, Ply + 1, Q_Left - 1);
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

   function Negamax (Position : in out Position_Type;
                     Depth, Ply : in Natural;
                     Alpha, Beta : in Score_Type) return Score_Type
   is
      A          : Score_Type := Alpha;
      B          : Score_Type := Beta;
      Moves      : Move_List;
      Count      : Natural;
      Hash_Move  : Move_Type := Empty_Move;
      Best_Move_Here : Move_Type := Empty_Move;
      Best_Score : Score_Type := -Infinity;
   begin
      if Depth = 0 then
         return Quiescence (Position, A, B, Ply, Quiescence_Limit);
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

      Generate_Legal_Moves (Position, Moves, Count);

      if Count = 0 then
         if King_In_Check (Position, Position.Side) then
            return -(Mate_Score - Ply);
         else
            return 0;
         end if;
      end if;

      -- Bring the hash move to the front (move ordering).
      if Hash_Move /= Empty_Move then
         for I in 1 .. Count loop
            if Moves (I) = Hash_Move and then I /= 1 then
               declare
                  Tmp : constant Move_Type := Moves (1);
               begin
                  Moves (1) := Moves (I);
                  Moves (I) := Tmp;
               end;
               exit;
            end if;
         end loop;
      end if;

      -- Tactical moves first (captures, en passant, promotions): they prune
      -- the alpha-beta tree much earlier than quiet moves.
      if Count > 2 then
         declare
            Next_Tact : Natural := 2;
            Tmp       : Move_Type;
         begin
            for I in 2 .. Count loop
               if Is_Tactical (Position, Moves (I)) then
                  Tmp := Moves (Next_Tact);
                  Moves (Next_Tact) := Moves (I);
                  Moves (I) := Tmp;
                  Next_Tact := Next_Tact + 1;
               end if;
            end loop;
         end;
      end if;

      for I in 1 .. Count loop
         declare
            Undo  : Undo_Info;
            Score : Score_Type;
         begin
            Make_Move (Position, Moves (I), Undo);
            Score := -Negamax (Position, Depth - 1, Ply + 1, -B, -A);
            Unmake_Move (Position, Moves (I), Undo);

            if Score > Best_Score then
               Best_Score    := Score;
               Best_Move_Here := Moves (I);
            end if;
            if Score >= B then
               Store (Position, Depth, Lower_Bound, Score, Best_Move_Here, Ply);
               return Score;
            end if;
            if Score > A then
               A := Score;
            end if;
         end;
      end loop;

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
      Best       : Move_Type := Empty_Move;
      Best_Sc    : Score_Type := -Infinity;
   begin
      Generate_Legal_Moves (Position, Root_Moves, Count);
      if Count = 0 then
         Best_Score := 0;
         return Empty_Move;
      end if;

      -- Try the previous iteration best move first.
      if Prev_Best /= Empty_Move then
         for I in 1 .. Count loop
            if Root_Moves (I) = Prev_Best and then I /= 1 then
               declare
                  Tmp : constant Move_Type := Root_Moves (1);
               begin
                  Root_Moves (1) := Root_Moves (I);
                  Root_Moves (I) := Tmp;
               end;
               exit;
            end if;
         end loop;
      end if;

      for I in 1 .. Count loop
         declare
            Undo  : Undo_Info;
            Score : Score_Type;
         begin
            Make_Move (Position, Root_Moves (I), Undo);
            Score := -Negamax (Position, Depth - 1, 1, -Infinity, Infinity);
            Unmake_Move (Position, Root_Moves (I), Undo);

            if Score > Best_Sc then
               Best_Sc := Score;
               Best    := Root_Moves (I);
            end if;
         end;
      end loop;

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

      Hash.Set_Keys_Enabled (True);
      Work.Key := Hash.Compute (Work);
      Clear_Transposition_Table;

      for D in 1 .. Depth loop
         Best := Root_Search (Work, D, Best, Best_Score);
         exit when Abs (Best_Score) >= Mate_Score - 200;
      end loop;

      return Best;
   end Best_Move;

   ------------------------
   -- Best_Move (time) --
   ------------------------

   function Best_Move (Position   : in Position_Type;
                        Max_Depth  : in Natural;
                        Time_Alloc : in Duration) return Move_Type is
      use Ada.Real_Time;
      Start      : constant Time := Clock;
      Best       : Move_Type := Empty_Move;
      Best_Score : Score_Type := 0;
      Work       : Position_Type := Position;
      Depth_Cap  : constant Natural := Natural'Min (Max_Depth, 5);
   begin
      if Depth_Cap = 0 then
         return Empty_Move;
      end if;

      Hash.Set_Keys_Enabled (True);
      Work.Key := Hash.Compute (Work);
      Clear_Transposition_Table;

      for D in 1 .. Depth_Cap loop
         if To_Duration (Clock - Start) >= Time_Alloc then
            exit;
         end if;
         Best := Root_Search (Work, D, Best, Best_Score);
         exit when Abs (Best_Score) >= Mate_Score - 200;
      end loop;

      return Best;
   end Best_Move;

end BBChess.Search;
