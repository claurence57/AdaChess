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

      procedure Add_Pawn_Moves (From : in Square_Type) is
         F  : constant Natural := File_Of (From);
         R  : constant Natural := Rank_Of (From);
         Forward    : constant Integer := (if Side = White then 1 else -1);
         Start_Rank : constant Natural := (if Side = White then 1 else 6);
         Promo_Rank : constant Natural := (if Side = White then 7 else 0);
      begin
         -- Single push (or promotions when reaching the last rank).
         if R + Forward in 0 .. 7 then
            declare
               To : constant Square_Type := Square_Type ((R + Forward) * 8 + F);
            begin
                if (Occ and Bit (To)) = 0 then
                   if R + Forward = Promo_Rank then
                      Emit_Promotions (From, To);
                   elsif not Tactical then
                      Add (Moves, Count, From, To, Pawn_Piece);
                      if R = Start_Rank and then R + 2 * Forward in 0 .. 7 then
                         declare
                            To2 : constant Square_Type :=
                              Square_Type ((R + 2 * Forward) * 8 + F);
                         begin
                            if (Occ and Bit (To2)) = 0 then
                               Add (Moves, Count, From, To2, Pawn_Piece, Double_Push);
                            end if;
                         end;
                      end if;
                   end if;
                end if;
            end;
         end if;

         -- Captures (including en passant and capture-promotions).
         declare
            Targets : Bitboard := Pawn_Attacks (Side, From) and Enemy;
         begin
            if Position.En_Passant /= Ep_None then
               declare
                  Ep_Sq : constant Square_Type := Square_Type (Position.En_Passant);
               begin
                  if (Pawn_Attacks (Side, From) and Bit (Ep_Sq)) /= 0 then
                     Targets := Targets or Bit (Ep_Sq);
                  end if;
               end;
            end if;

            while Targets /= 0 loop
               declare
                  To : constant Square_Type := Lowest_Bit (Targets);
               begin
                  if Rank_Of (To) = Promo_Rank then
                     Emit_Promotions (From, To);
                  elsif Position.En_Passant /= Ep_None and then
                    Square_Type (Position.En_Passant) = To then
                     Add (Moves, Count, From, To, Pawn_Piece, En_Passant);
                  else
                     Add (Moves, Count, From, To, Pawn_Piece);
                  end if;
                  Targets := Targets and (Targets - 1);
               end;
            end loop;
         end;
      end Add_Pawn_Moves;

   begin
      Count := 0;

      -- Pawns.
      Pieces := Board_Of (Pawn);
      while Pieces /= 0 loop
         From := Lowest_Bit (Pieces);
         Add_Pawn_Moves (From);
         Pieces := Pieces and (Pieces - 1);
      end loop;

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
      Tactical : in Boolean)
   is
      Pseudo : Move_List;
      P_Count : Natural;
      Undo   : Undo_Info;
      Work   : Position_Type := Position;
   begin
      Count := 0;
      Generate_Pseudo_Moves (Position, Pseudo, P_Count, Tactical);

      for I in 1 .. P_Count loop
         Make_Move (Work, Pseudo (I), Undo);
         if not King_In_Check (Work, Position.Side) then
            Count := Count + 1;
            Moves (Count) := Pseudo (I);
         end if;
         Unmake_Move (Work, Pseudo (I), Undo);
      end loop;
   end Generate_Legal_Common;

   procedure Generate_Legal_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural) is
   begin
      Generate_Legal_Common (Position, Moves, Count, Tactical => False);
   end Generate_Legal_Moves;

   procedure Generate_Legal_Tactical_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural) is
   begin
      Generate_Legal_Common (Position, Moves, Count, Tactical => True);
   end Generate_Legal_Tactical_Moves;

end BBChess.Movegen;
