--
--  AdaChess-BB : static exchange evaluation (body)
--
--  The sequence is explored with a small recursive minimax over a working
--  copy of the board: each step removes the chosen attacker from its
--  square, removes the piece standing on the target square and settles the
--  attacker on it, then lets the opponent answer. The occupancy is therefore
--  always up to date, which makes x-ray (sliding) attackers appear as soon
--  as the piece in front of them is gone.
--
--  The working copy only needs the twelve piece bitboards, the total
--  occupancy and the two colour occupancies: the exchange never looks at the
--  square->piece map, and it always knows which piece stands on the target
--  square (it is the attacker it just settled there). Keeping a dedicated
--  compact record avoids copying the whole Position (clocks, castling rights,
--  key, material, 64-entry square map) on every call.
--

with BBChess.Attacks;
use BBChess.Attacks;

with BBChess.Movegen;
use BBChess.Movegen;

package body BBChess.See is

   --  Bitboard-only snapshot of a board, mutated by the exchange.
   type See_Board is
      record
         Pieces    : Piece_Board_Array := (others => 0);
         All_Occ   : Bitboard := 0;
         Color_Occ : Color_Board_Array := (others => 0);
      end record;

   procedure See_Put (B : in out See_Board; Piece : in Piece_Type;
                      Square : in Square_Type) is
      M : constant Bitboard := Bit (Square);
   begin
      B.Pieces (Piece) := B.Pieces (Piece) or M;
      B.All_Occ := B.All_Occ or M;
      B.Color_Occ (Pieces.Color (Piece)) :=
        B.Color_Occ (Pieces.Color (Piece)) or M;
   end See_Put;
   pragma Inline (See_Put);

   procedure See_Remove (B : in out See_Board; Piece : in Piece_Type;
                         Square : in Square_Type) is
      M : constant Bitboard := not Bit (Square);
   begin
      B.Pieces (Piece) := B.Pieces (Piece) and M;
      B.All_Occ := B.All_Occ and M;
      B.Color_Occ (Pieces.Color (Piece)) :=
        B.Color_Occ (Pieces.Color (Piece)) and M;
   end See_Remove;
   pragma Inline (See_Remove);

   -----------------
   -- Kind_Value --
   -----------------

   -- Values match the evaluation / search piece values. The king only ever
   -- appears as the last attacker of a sequence, so its magnitude is never
   -- part of a result.
   function Kind_Value (Kind : in Kind_Type) return Score_Type is
   begin
      case Kind is
         when Pawn   => return 100;
         when Knight => return 320;
         when Bishop => return 330;
         when Rook   => return 500;
         when Queen  => return 900;
         when King   => return 10_000;
      end case;
   end Kind_Value;

   -----------------
   -- Pin_Mask_See --
   -----------------

   -- Pin_Mask on the compact board (same computation as Movegen.Pin_Mask,
   -- only the fields used by the bitboard-only working copy).
   function Pin_Mask_See (B : in See_Board; Color : in Color_Type)
     return Bitboard
   is
      Enemy   : constant Color_Type := Opposite (Color);
      King_Sq : constant Square_Type :=
        Lowest_Bit (B.Pieces (Make (Color, King)));
      Occ     : constant Bitboard := B.All_Occ;
      Own     : constant Bitboard := B.Color_Occ (Color);
      Rook_Q  : constant Bitboard :=
        B.Pieces (Make (Enemy, Rook)) or B.Pieces (Make (Enemy, Queen));
      Bish_Q  : constant Bitboard :=
        B.Pieces (Make (Enemy, Bishop)) or B.Pieces (Make (Enemy, Queen));
      Pinners : Bitboard :=
        (Rook_Ray (King_Sq) and Rook_Q) or (Bishop_Ray (King_Sq) and Bish_Q);
      Result  : Bitboard := 0;
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
   end Pin_Mask_See;

   -------------
   -- Weakest --
   -------------

   -- Least valuable attacker of Side on To that is not absolutely pinned.
   -- The king is only returned when no other piece can take part.
   procedure Weakest (B      : in See_Board;
                      To     : in Square_Type;
                      Side   : in Color_Type;
                      Found  : out Boolean;
                      From   : out Square_Type;
                      Piece  : out Piece_Type)
   is
      Occ     : constant Bitboard := B.All_Occ;
      Pinned  : constant Bitboard := Pin_Mask_See (B, Side);
      Cand    : Bitboard;
   begin
      Found := False;
      From  := 0;
      Piece := Make (Side, Pawn);

      Cand := (Pawn_Attacks (Opposite (Side), To)
                 and B.Pieces (Make (Side, Pawn))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Pawn); return;
      end if;

      Cand := (Knight_Attacks (To) and B.Pieces (Make (Side, Knight))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Knight); return;
      end if;

      Cand := (Bishop_Attacks (To, Occ) and B.Pieces (Make (Side, Bishop))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Bishop); return;
      end if;

      Cand := (Rook_Attacks (To, Occ) and B.Pieces (Make (Side, Rook))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Rook); return;
      end if;

      Cand := ((Bishop_Attacks (To, Occ) or Rook_Attacks (To, Occ))
                 and B.Pieces (Make (Side, Queen))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Queen); return;
      end if;

      Cand := King_Attacks (To) and B.Pieces (Make (Side, King));
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, King);
      end if;
   end Weakest;

   ----------------
   -- Exchange --
   ----------------

   -- Best outcome (>= 0, a side may always decline) for Side of the capture
   -- sequence on To, knowing On_Piece (a piece of the opponent) currently
   -- stands there. B is consumed along the way: every capture removes a piece.
   function Exchange (B        : in out See_Board;
                      To       : in Square_Type;
                      Side     : in Color_Type;
                      On_Piece : in Piece_Type) return Score_Type
   is
      Found  : Boolean;
      From   : Square_Type;
      Att    : Piece_Type;
      Value  : Score_Type;
   begin
      Weakest (B, To, Side, Found, From, Att);
      if not Found then
         -- No attacker available: the opponent simply stands pat.
         return 0;
      end if;

      -- Make the recapture.
      See_Remove (B, Att, From);
      See_Remove (B, On_Piece, To);
      See_Put (B, Att, To);

      if Kind (Att) = King then
         -- A king capture ends the sequence: the king itself cannot be
         -- taken back in a legal exchange.
         return Kind_Value (Kind (On_Piece));
      end if;

      Value := Kind_Value (Kind (On_Piece))
                 - Exchange (B, To, Opposite (Side), Att);
      if Value < 0 then
         -- Recapturing here would lose material: decline instead.
         return 0;
      end if;
      return Value;
   end Exchange;

   --------------------------
   -- Static_Exchange_Value --
   --------------------------

   function Static_Exchange_Value
     (Position : in Position_Type;
      Move     : in Move_Type) return Score_Type
   is
      Side        : constant Color_Type := Position.Side;
      Opp         : constant Color_Type := Opposite (Side);
      Victim      : Score_Type := 0;
      Captured    : Piece_Type;
      Present     : Boolean;
      Victim_Square : Square_Type;
   begin
      -- Promotions (with or without capture) are always winning exchanges:
      -- the promoted piece is what decides the outcome, and they are ordered
      -- ahead of captures anyway.
      if Move.Flag = Promotion then
         return Kind_Value (Kind (Move.Promotion)) + 100;
      end if;

      -- Quiet (non-tactical) moves have no exchange to evaluate.
      if Move.Flag /= En_Passant then
         Present := Piece_At (Position, Move.To, Captured);
         if not Present then
            return 0;
         end if;
         Victim := Kind_Value (Kind (Captured));
      else
         Victim := Kind_Value (Pawn);
         -- The captured pawn stands just behind the (empty) target square.
         if Side = White then
            Victim_Square := Move.To - 8;
         else
            Victim_Square := Move.To + 8;
         end if;
         Captured := Make (Opp, Pawn);
      end if;

      -- Build the compact working board from the position, then play the
      -- capture: remove the victim, move the attacker onto the target.
      declare
         B : See_Board;
      begin
         B.Pieces    := Position.Pieces;
         B.All_Occ   := Position.All_Occ;
         B.Color_Occ := Position.Color_Occ;

         if Move.Flag = En_Passant then
            See_Remove (B, Captured, Victim_Square);
         else
            See_Remove (B, Captured, Move.To);
         end if;
         See_Remove (B, Move.Piece, Move.From);
         See_Put (B, Move.Piece, Move.To);

         return Victim - Exchange (B, Move.To, Opp, Move.Piece);
      end;
   end Static_Exchange_Value;

end BBChess.See;
