--
--  AdaChess-BB : legal move generation (body)
--

with BBChess.Attacks;
use BBChess.Attacks;
with BBChess.Pin_Mask;
use BBChess.Pin_Mask;

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
                         By       : in Color_Type;
                         Occ      : in Bitboard) return Boolean
   is
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

   function Is_Attacked (Position : in Position_Type;
                         Square   : in Square_Type;
                         By       : in Color_Type) return Boolean is
   begin
      return Is_Attacked (Position, Square, By, Occupancy (Position));
   end Is_Attacked;

   -- Every piece of By that attacks Square (used for check detection and
   -- check evasion).
   function Attackers_To (Position : in Position_Type;
                          Square   : in Square_Type;
                          By       : in Color_Type) return Bitboard
   is
      Occ : constant Bitboard := Occupancy (Position);
   begin
      return
        (Pawn_Attacks (Opposite (By), Square)
           and Position.Pieces (Make (By, Pawn)))
        or (Knight_Attacks (Square)
              and Position.Pieces (Make (By, Knight)))
        or (Bishop_Attacks (Square, Occ)
              and (Position.Pieces (Make (By, Bishop))
                     or Position.Pieces (Make (By, Queen))))
        or (Rook_Attacks (Square, Occ)
              and (Position.Pieces (Make (By, Rook))
                     or Position.Pieces (Make (By, Queen))))
        or (King_Attacks (Square)
              and Position.Pieces (Make (By, King)));
   end Attackers_To;

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
   -- The bitboard-level work is shared with SEE through BBChess.Pin_Mask.
   function Pin_Mask (Position : in Position_Type; Color : in Color_Type)
     return Bitboard
   is
      Enemy : constant Color_Type := Opposite (Color);
   begin
      return Pinned
        (Occ                => Occupancy (Position),
         King_Sq            => Lowest_Bit (Position.Pieces (Make (Color, King))),
         Own                => Position.Color_Occ (Color),
         Enemy_Rook_Queen   =>
           Position.Pieces (Make (Enemy, Rook))
           or Position.Pieces (Make (Enemy, Queen)),
         Enemy_Bishop_Queen =>
           Position.Pieces (Make (Enemy, Bishop))
           or Position.Pieces (Make (Enemy, Queen)));
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
   pragma Inline (Add);

   -----------------
   -- Pseudo moves --
   -----------------

   procedure Generate_Pseudo_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural;
      Tactical : in Boolean := False;
      King_First : out Natural)
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
      -- Legal targets of a leaper/slider: in tactical mode only enemy squares
      -- are kept, otherwise all non-own squares. The mask is loop-invariant,
      -- so it is built once instead of re-testing Tactical per piece.
      Target_Mask  : constant Bitboard :=
        (if Tactical then Enemy else not Own);

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
            Targets : Bitboard := Knight_Attacks (From) and Target_Mask;
begin
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
            Targets : Bitboard := Bishop_Attacks (From, Occ) and Target_Mask;
begin
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
            Targets : Bitboard := Rook_Attacks (From, Occ) and Target_Mask;
begin
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
            Targets : Bitboard := Queen_Attacks (From, Occ) and Target_Mask;
begin
            while Targets /= 0 loop
               Add (Moves, Count, From, Lowest_Bit (Targets), Queen_Piece);
               Targets := Targets and (Targets - 1);
            end loop;
         end;
         Pieces := Pieces and (Pieces - 1);
      end loop;

      -- King (quiet moves; castling is appended separately). Its index is
      -- reported so the legal filter can tell the (filtered) king moves from
      -- the plain non-king moves that precede them.
      King_First := Count + 1;
      From := Lowest_Bit (Position.Pieces (King_Piece));
      declare
         Targets : Bitboard := King_Attacks (From) and Target_Mask;
begin
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
      In_Check : out Boolean;
      Known_Not_In_Check : in Boolean := False)
   is
      P_Count  : Natural;
      King_First : Natural;
      Side     : constant Color_Type := Position.Side;
      Opp      : constant Color_Type := Opposite (Side);
      Occ      : constant Bitboard := Occupancy (Position);
      King_Sq  : constant Square_Type := King_Square (Position, Side);
      -- The caller may already know the side is not in check (quiescence
      -- tests it at node entry). Recomputing Attackers_To there would repeat
      -- the same two PEXT lookups for nothing, so it is skipped: no checker
      -- means Checkers = 0 and In_Check = False, which is exactly what the
      -- full computation would produce.
      Checkers : constant Bitboard :=
        (if Known_Not_In_Check
         then 0
         else Attackers_To (Position, King_Sq, Opp));
      Pinned   : constant Bitboard := Pin_Mask (Position, Side);
      -- Squares a non-king move must reach to resolve a check (all squares
      -- when there is no check).
      Check_Mask : Bitboard;
      -- Occupancy seen by the king after it leaves its square (reveals
      -- discovered attacks along its ray).
      Occ_No_King : constant Bitboard := Occ and not Bit (King_Sq);
      -- With no checker and no absolutely pinned piece, every non-king move
      -- is legal. En passant is the only exception: capturing the pawn can
      -- uncover a rook/queen on the vacated rank, so an ep move is still
      -- tested with a make/unmake. When there is no ep target either, the
      -- whole non-king prefix is legal and is kept as generated.
      Fast : constant Boolean := Checkers = 0 and then Pinned = 0;
   begin
      Count := 0;
      In_Check := Checkers /= 0;
      -- The pseudo-legal moves are generated straight into the output
      -- buffer; the legal filter then compacts them in place (Count <= I for
      -- every kept move, so no element is overwritten before it is read).
      -- This avoids a second 256-move scratch buffer (a 3 KB stack copy).
      Generate_Pseudo_Moves (Position, Moves, P_Count, Tactical, King_First);

      if In_Check then
         if (Checkers and (Checkers - 1)) = 0 then
            -- Single check: capture the checker or interpose.
            Check_Mask := Bit (Lowest_Bit (Checkers))
                          or Between (King_Sq, Lowest_Bit (Checkers));
         else
            -- Double check: only the king can move.
            Check_Mask := 0;
         end if;
      else
         Check_Mask := not Bitboard (0);
      end if;

      -- Fast path without en passant: the non-king prefix (everything before
      -- the king moves, which the generator appends last) is legal as
      -- generated, so only the king moves (and castling) are tested. Count is
      -- advanced past the prefix without copying a single move, and the king
      -- moves are walked from King_First exactly as the generic loop would.
      if Fast and then Position.En_Passant = Ep_None then
         Count := King_First - 1;
         for I in King_First .. P_Count loop
            declare
               M : Move_Type renames Moves (I);
            begin
               if not Is_Attacked (Position, M.To, Opp, Occ_No_King) then
                  Count := Count + 1;
                  if Count /= I then
                     Moves (Count) := M;
                  end if;
               end if;
            end;
         end loop;
         return;
      end if;

      for I in 1 .. P_Count loop
         declare
            M : Move_Type renames Moves (I);
         begin
            -- Only White_King / Black_King have Kind = King, so the two
            -- direct comparisons avoid the (mod 6) decomposition of Kind.
            if M.Piece = White_King or else M.Piece = Black_King then
               -- A king may not step onto an attacked square (with the king
               -- removed from the occupancy so discovered attacks count).
               if not Is_Attacked (Position, M.To, Opp, Occ_No_King) then
                  Count := Count + 1;
                  if Count /= I then
                     Moves (Count) := M;
                  end if;
               end if;
            elsif M.Flag = En_Passant then
               -- Rare: the make/unmake test covers the rank-discovered and
               -- check-resolving cases uniformly. The working copy is only
               -- made here (a full Position copy, off the common path).
               declare
                  Undo : Undo_Info;
                  Work : Position_Type := Position;
               begin
                  Make_Move (Work, M, Undo);
                  if not King_In_Check (Work, Side) then
                     Count := Count + 1;
                     if Count /= I then
                        Moves (Count) := M;
                     end if;
                  end if;
                  Unmake_Move (Work, M, Undo);
               end;
            elsif Fast then
               -- No check and no pin: the move is legal as generated.
               Count := Count + 1;
               if Count /= I then
                  Moves (Count) := M;
               end if;
            else
               -- Non-king move: must resolve the check and, when the piece is
               -- absolutely pinned, stay on its pin line.
               if (Check_Mask and Bit (M.To)) /= 0
                 and then
                   ((Bit (M.From) and Pinned) = 0
                    or else (Line (King_Sq, M.From) and Bit (M.To)) /= 0)
               then
                  Count := Count + 1;
                  if Count /= I then
                     Moves (Count) := M;
                  end if;
               end if;
            end if;
         end;
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

   procedure Generate_Legal_Tactical_Moves
     (Position : in Position_Type;
      Moves    : out Move_List;
      Count    : out Natural;
      Not_In_Check : in Boolean) is
      In_Check : Boolean;
   begin
      Generate_Legal_Common (Position, Moves, Count,
                             Tactical => True, In_Check => In_Check,
                             Known_Not_In_Check => Not_In_Check);
   end Generate_Legal_Tactical_Moves;

end BBChess.Movegen;
