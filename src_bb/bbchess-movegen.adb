--
--  AdaChess-BB : legal move generation (body)
--

package body BBChess.Movegen is

   -------------
   -- Helpers --
   -------------

   function King_Square (Position : in Position_Type; Color : in Color_Type)
     return Square_Type is
   begin
      return Lowest_Bit (Position.Pieces (Make (Color, King)));
   end King_Square;

   function Is_Attacked (Position : in Position_Type;
                         Square   : in Square_Type;
                         By       : in Color_Type) return Boolean
   is
      Occ : constant Bitboard := Occupancy (Position);
   begin
      -- Pawns: a White pawn attacks upward, so a White attacker of Square
      -- sits on the squares a Black pawn standing on Square would attack
      -- (and vice versa).
      if By = White then
         if (Pawn_Attacks (Black, Square) and Position.Pieces (White_Pawn)) /= 0 then
            return True;
         end if;
      else
         if (Pawn_Attacks (White, Square) and Position.Pieces (Black_Pawn)) /= 0 then
            return True;
         end if;
      end if;

      if (Knight_Attacks (Square) and Position.Pieces (Make (By, Knight))) /= 0 then
         return True;
      end if;

      if (King_Attacks (Square) and Position.Pieces (Make (By, King))) /= 0 then
         return True;
      end if;

      if (Bishop_Attacks (Square, Occ) and
          (Position.Pieces (Make (By, Bishop)) or Position.Pieces (Make (By, Queen)))) /= 0 then
         return True;
      end if;

      if (Rook_Attacks (Square, Occ) and
          (Position.Pieces (Make (By, Rook)) or Position.Pieces (Make (By, Queen)))) /= 0 then
         return True;
      end if;

      return False;
   end Is_Attacked;

   function King_In_Check (Position : in Position_Type; Color : in Color_Type)
     return Boolean is
   begin
      return Is_Attacked (Position, King_Square (Position, Color), Opposite (Color));
   end King_In_Check;

   -----------------
   -- Pinned mask --
   -----------------

   -- A piece of Color is "absolutely pinned" when it is the only blocker
   -- between its own king and an enemy sliding piece of matching direction.
   -- Computed from the full (empty-board) rays of the king rather than a
   -- per-square walk: the potential pinners are the enemy sliders on those
   -- rays, and a pin exists when exactly one friendly piece stands between.
   function Pin_Mask (Position : in Position_Type; Color : in Color_Type)
     return Bitboard
   is
      Enemy    : constant Color_Type := Opposite (Color);
      King_Sq  : constant Square_Type :=
        Lowest_Bit (Position.Pieces (Make (Color, King)));
      Occ      : constant Bitboard := Occupancy (Position);
      Own      : constant Bitboard := Position.Color_Occ (Color);
      Rook_Q   : constant Bitboard :=
        Position.Pieces (Make (Enemy, Rook))
        or Position.Pieces (Make (Enemy, Queen));
      Bish_Q   : constant Bitboard :=
        Position.Pieces (Make (Enemy, Bishop))
        or Position.Pieces (Make (Enemy, Queen));
      Rook_Ray : constant Bitboard := Rook_Attacks (King_Sq, 0);
      Bish_Ray : constant Bitboard := Bishop_Attacks (King_Sq, 0);
      Pinners  : Bitboard := (Rook_Ray and Rook_Q) or (Bish_Ray and Bish_Q);
      Result   : Bitboard := 0;
   begin
      while Pinners /= 0 loop
         declare
            P        : constant Square_Type := Lowest_Bit (Pinners);
            Blockers : Bitboard;
         begin
            Blockers := Between (King_Sq, P) and Occ;
            if Blockers /= 0
              and then (Blockers and (Blockers - 1)) = 0
              and then (Blockers and Own) /= 0
            then
               Result := Result or Blockers;
            end if;
         end;
         Pinners := Pinners and (Pinners - 1);
      end loop;
      return Result;
   end Pin_Mask;

   ---------------------
   -- Pseudo move add --
   ---------------------

   procedure Add (Moves    : in out Move_List;
                  Count    : in out Natural;
                  From, To : in Square_Type;
                  Piece    : in Piece_Type;
                  Flag     : in Move_Flag_Type := Quiet;
                  Promo    : in Piece_Type := White_Pawn)
   is
   begin
      Count := Count + 1;
      Moves (Count) := (From => From, To => To, Piece => Piece,
                        Promotion => Promo, Flag => Flag);
   end Add;

   -----------------
   -- Pseudo moves --
   -----------------

   procedure Generate_Pseudo_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural;
      Tactical : in Boolean := False)
   is
      Side  : constant Color_Type := Position.Side;
      Opp   : constant Color_Type := Opposite (Side);
      Own   : constant Bitboard := Color_Board (Position, Side);
      Enemy : constant Bitboard := Color_Board (Position, Opp);
      Occ   : constant Bitboard := Occupancy (Position);
      Pawn_Piece : constant Piece_Type := Make (Side, Pawn);
      Knight_Piece : constant Piece_Type := Make (Side, Knight);
      Bishop_Piece : constant Piece_Type := Make (Side, Bishop);
      Rook_Piece   : constant Piece_Type := Make (Side, Rook);
      Queen_Piece  : constant Piece_Type := Make (Side, Queen);
      King_Piece   : constant Piece_Type := Make (Side, King);

      function Board_Of (Kind : in Kind_Type) return Bitboard is
        (Position.Pieces (Make (Side, Kind)));

      From : Square_Type;
      Pieces : Bitboard;

      procedure Emit_Promotions (From, To : in Square_Type) is
      begin
         Add (Moves, Count, From, To, Pawn_Piece, Promotion, Make (Side, Queen));
         Add (Moves, Count, From, To, Pawn_Piece, Promotion, Make (Side, Rook));
         Add (Moves, Count, From, To, Pawn_Piece, Promotion, Make (Side, Bishop));
         Add (Moves, Count, From, To, Pawn_Piece, Promotion, Make (Side, Knight));
      end Emit_Promotions;

   begin
      Count := 0;

      -- Pawns: bulk shift generation (all destinations computed at once).
      declare
         Pawns : constant Bitboard := Board_Of (Pawn);
         Empty : constant Bitboard := not Occ;
         Rank_1 : constant Bitboard := 16#00000000000000FF#;   -- black promo
         Rank_8 : constant Bitboard := 16#FF00000000000000#;   -- white promo
         White_Push_Rank : constant Bitboard := 16#0000000000FF0000#;
         Black_Push_Rank : constant Bitboard := 16#0000FF0000000000#;

         procedure Emit (Targets : in Bitboard; D : in Integer;
                         Flag : in Move_Flag_Type := Quiet) is
            T : Bitboard := Targets;
         begin
            while T /= 0 loop
               declare
                  To : constant Square_Type := Lowest_Bit (T);
               begin
                  Add (Moves, Count, Square_Type (Integer (To) + D),
                       To, Pawn_Piece, Flag);
               end;
               T := T and (T - 1);
            end loop;
         end Emit;

         procedure Emit_Promo (Targets : in Bitboard; D : in Integer) is
            T : Bitboard := Targets;
         begin
            while T /= 0 loop
               declare
                  To : constant Square_Type := Lowest_Bit (T);
               begin
                  Emit_Promotions (Square_Type (Integer (To) + D), To);
               end;
               T := T and (T - 1);
            end loop;
         end Emit_Promo;

         Push1, Dbl, Caps_L, Caps_R : Bitboard;
      begin
         if Side = White then
            Push1 := (Pawns * 256) and Empty;
            Dbl   := ((Push1 and White_Push_Rank) * 256) and Empty;
            Caps_L := ((Pawns and not File_A_BB) * 128) and Enemy;
            Caps_R := ((Pawns and not File_H_BB) * 512) and Enemy;

            Emit_Promo (Push1 and Rank_8, -8);
            Emit_Promo (Caps_L and Rank_8, -7);
            Emit_Promo (Caps_R and Rank_8, -9);
            if not Tactical then
               Emit (Push1 and not Rank_8, -8);
               Emit (Dbl, -16, Double_Push);
            end if;
            Emit (Caps_L and not Rank_8, -7);
            Emit (Caps_R and not Rank_8, -9);
         else
            Push1 := (Pawns / 256) and Empty;
            Dbl   := ((Push1 and Black_Push_Rank) / 256) and Empty;
            Caps_L := ((Pawns and not File_A_BB) / 512) and Enemy;
            Caps_R := ((Pawns and not File_H_BB) / 128) and Enemy;

            Emit_Promo (Push1 and Rank_1, 8);
            Emit_Promo (Caps_L and Rank_1, 9);
            Emit_Promo (Caps_R and Rank_1, 7);
            if not Tactical then
               Emit (Push1 and not Rank_1, 8);
               Emit (Dbl, 16, Double_Push);
            end if;
            Emit (Caps_L and not Rank_1, 9);
            Emit (Caps_R and not Rank_1, 7);
         end if;

         -- En passant: the target square is empty, so it is not part of the
         -- bulk captures. A friendly pawn attacking it sits on a square that
         -- an opposite-color pawn standing there would attack.
         if Position.En_Passant /= Ep_None then
            declare
               Ep_Sq     : constant Square_Type := Square_Type (Position.En_Passant);
               Attackers : Bitboard :=
                 Pawn_Attacks (Opposite (Side), Ep_Sq) and Pawns;
            begin
               while Attackers /= 0 loop
                  declare
                     From_Sq : constant Square_Type := Lowest_Bit (Attackers);
                  begin
                     Add (Moves, Count, From_Sq, Ep_Sq, Pawn_Piece, En_Passant);
                  end;
                  Attackers := Attackers and (Attackers - 1);
               end loop;
            end;
         end if;
      end;

      -- Knights.
      Pieces := Board_Of (Knight);
      while Pieces /= 0 loop
         From := Lowest_Bit (Pieces);
         declare
            Targets : Bitboard := Knight_Attacks (From) and not Own;
begin
             if Tactical then
                Targets := Targets and Enemy;
             end if;
            while Targets /= 0 loop
               Add (Moves, Count, From, Lowest_Bit (Targets), Knight_Piece);
               Targets := Targets and (Targets - 1);
            end loop;
         end;
         Pieces := Pieces and (Pieces - 1);
      end loop;

      -- Bishops.
      Pieces := Board_Of (Bishop);
      while Pieces /= 0 loop
         From := Lowest_Bit (Pieces);
         declare
            Targets : Bitboard := Bishop_Attacks (From, Occ) and not Own;
begin
             if Tactical then
                Targets := Targets and Enemy;
             end if;
            while Targets /= 0 loop
               Add (Moves, Count, From, Lowest_Bit (Targets), Bishop_Piece);
               Targets := Targets and (Targets - 1);
            end loop;
         end;
         Pieces := Pieces and (Pieces - 1);
      end loop;

      -- Rooks.
      Pieces := Board_Of (Rook);
      while Pieces /= 0 loop
         From := Lowest_Bit (Pieces);
         declare
            Targets : Bitboard := Rook_Attacks (From, Occ) and not Own;
begin
             if Tactical then
                Targets := Targets and Enemy;
             end if;
            while Targets /= 0 loop
               Add (Moves, Count, From, Lowest_Bit (Targets), Rook_Piece);
               Targets := Targets and (Targets - 1);
            end loop;
         end;
         Pieces := Pieces and (Pieces - 1);
      end loop;

      -- Queens.
      Pieces := Board_Of (Queen);
      while Pieces /= 0 loop
         From := Lowest_Bit (Pieces);
         declare
            Targets : Bitboard := Queen_Attacks (From, Occ) and not Own;
begin
             if Tactical then
                Targets := Targets and Enemy;
             end if;
            while Targets /= 0 loop
               Add (Moves, Count, From, Lowest_Bit (Targets), Queen_Piece);
               Targets := Targets and (Targets - 1);
            end loop;
         end;
         Pieces := Pieces and (Pieces - 1);
      end loop;

      -- King (quiet moves; castling is appended separately).
      From := Lowest_Bit (Position.Pieces (King_Piece));
      declare
         Targets : Bitboard := King_Attacks (From) and not Own;
begin
             if Tactical then
                Targets := Targets and Enemy;
             end if;
         while Targets /= 0 loop
            Add (Moves, Count, From, Lowest_Bit (Targets), King_Piece);
            Targets := Targets and (Targets - 1);
         end loop;
      end;

      -- Castling.
      if not Tactical and then Position.Castle (Side, King_Side) then
         declare
            G : constant Square_Type := (if Side = White then 6 else 62);
            F : constant Square_Type := (if Side = White then 5 else 61);
         begin
            if (Occ and (Bit (F) or Bit (G))) = 0
              and then not Is_Attacked (Position, From, Opp)
              and then not Is_Attacked (Position, F, Opp)
              and then not Is_Attacked (Position, G, Opp)
            then
               Add (Moves, Count, From, G, King_Piece, King_Side_Castle);
            end if;
         end;
      end if;

      if not Tactical and then Position.Castle (Side, Queen_Side) then
         declare
            B : constant Square_Type := (if Side = White then 1 else 57);
            C : constant Square_Type := (if Side = White then 2 else 58);
            D : constant Square_Type := (if Side = White then 3 else 59);
         begin
            if (Occ and (Bit (B) or Bit (C) or Bit (D))) = 0
              and then not Is_Attacked (Position, From, Opp)
              and then not Is_Attacked (Position, D, Opp)
              and then not Is_Attacked (Position, C, Opp)
            then
               Add (Moves, Count, From, C, King_Piece, Queen_Side_Castle);
            end if;
         end;
      end if;
   end Generate_Pseudo_Moves;

   ---------------------------
   -- Generate_Legal_Moves --
   ---------------------------

   procedure Generate_Legal_Common
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural;
      Tactical : in Boolean;
      In_Check : out Boolean)
   is
      Pseudo  : Move_List;
      P_Count : Natural;
      Undo    : Undo_Info;
      Work    : Position_Type := Position;
      Pinned   : Bitboard;
      Need_Test : Boolean;
   begin
      Count := 0;
      In_Check := King_In_Check (Position, Position.Side);
      Generate_Pseudo_Moves (Position, Pseudo, P_Count, Tactical);

      -- When the side to move is not in check, a pseudo-legal move can only
      -- be illegal if it moves the king, an absolutely pinned piece, or an
      -- en-passant capture. Everything else is legal without further testing.
      if In_Check then
         Pinned := 0;
      else
         Pinned := Pin_Mask (Position, Position.Side);
      end if;

      for I in 1 .. P_Count loop
         if In_Check
           or else Kind (Pseudo (I).Piece) = King
           or else Pseudo (I).Flag = En_Passant
           or else (Bit (Pseudo (I).From) and Pinned) /= 0
         then
            Need_Test := True;
         else
            Need_Test := False;
         end if;

         if not Need_Test then
            Count := Count + 1;
            Moves (Count) := Pseudo (I);
         else
            Make_Move (Work, Pseudo (I), Undo);
            if not King_In_Check (Work, Position.Side) then
               Count := Count + 1;
               Moves (Count) := Pseudo (I);
            end if;
            Unmake_Move (Work, Pseudo (I), Undo);
         end if;
      end loop;
   end Generate_Legal_Common;

   procedure Generate_Legal_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural) is
      In_Check : Boolean;
   begin
      Generate_Legal_Common (Position, Moves, Count,
                             Tactical => False, In_Check => In_Check);
   end Generate_Legal_Moves;

   procedure Generate_Legal_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural;
      In_Check : out Boolean) is
   begin
      Generate_Legal_Common (Position, Moves, Count,
                             Tactical => False, In_Check => In_Check);
   end Generate_Legal_Moves;

   procedure Generate_Legal_Tactical_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural) is
      In_Check : Boolean;
   begin
      Generate_Legal_Common (Position, Moves, Count,
                             Tactical => True, In_Check => In_Check);
   end Generate_Legal_Tactical_Moves;

end BBChess.Movegen;
