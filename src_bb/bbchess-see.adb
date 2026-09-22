--
--  AdaChess-BB : static exchange evaluation (body)
--
--  The sequence is explored over a working copy of the board: each step
--  removes the chosen attacker from its square, removes the piece standing on
--  the target square and settles the attacker on it, then lets the opponent
--  answer. The occupancy is therefore always up to date, which makes x-ray
--  (sliding) attackers appear as soon as the piece in front of them is gone.
--  The sequence is generated forward once (Exchange), then folded backward
--  from the deepest reply with the same "a side may decline" rule the former
--  recursion used.
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

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Piece_Values;
use BBChess.Piece_Values;

with BBChess.Pin_Mask;
use BBChess.Pin_Mask;

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
   -- Pin_Mask_See --
   -----------------

   -- Pin_Mask on the compact board (the bitboard-level work is shared with
   -- Movegen through BBChess.Pin_Mask).
   function Pin_Mask_See (B : in See_Board; Color : in Color_Type)
     return Bitboard
   is
      Enemy : constant Color_Type := Opposite (Color);
   begin
      return Pinned
        (Occ                => B.All_Occ,
         King_Sq            => Lowest_Bit (B.Pieces (Make (Color, King))),
         Own                => B.Color_Occ (Color),
         Enemy_Rook_Queen   =>
           B.Pieces (Make (Enemy, Rook)) or B.Pieces (Make (Enemy, Queen)),
         Enemy_Bishop_Queen =>
           B.Pieces (Make (Enemy, Bishop)) or B.Pieces (Make (Enemy, Queen)));
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
   --
   -- The recursive minimax is unrolled into two passes whose result is
   -- identical:
   --   * forward, the capture sequence is generated exactly as before, each
   --     side answering with Weakest (which recomputes the pin mask on the
   --     mutated board, so pinned pieces still cannot recapture);
   --   * backward, the "a side may decline" rule is applied with the same
   --     max (0, value - reply) as the recursion, the king capture remaining
   --     terminal.
   -- This removes the per-ply call frames without changing any value.
   function Exchange (B        : in out See_Board;
                      To       : in Square_Type;
                      Side     : in Color_Type;
                      On_Piece : in Piece_Type) return Score_Type
   is
      Found     : Boolean;
      From      : Square_Type;
      Att       : Piece_Type;
      On_Now    : Piece_Type := On_Piece;
      Side_Now  : Color_Type := Side;
      King_Last : Boolean := False;
      Count     : Natural := 0;
      --  Value of the piece captured at each ply (ply 1 first). Only the
      --  1 .. Count prefix is read, so the array is left uninitialized.
      Gain      : array (1 .. 33) of Score_Type;
      Value     : Score_Type := 0;
   begin
      --  Forward pass: generate the sequence, mutating the working board.
      loop
         Weakest (B, To, Side_Now, Found, From, Att);
         exit when not Found;

         Count := Count + 1;
         Gain (Count) := SEE_Value (Kind (On_Now));

         --  Make the recapture.
         See_Remove (B, Att, From);
         See_Remove (B, On_Now, To);
         See_Put (B, Att, To);

         if Kind (Att) = King then
            --  A king capture ends the sequence: the king itself cannot be
            --  taken back in a legal exchange.
            King_Last := True;
            exit;
         end if;

         On_Now   := Att;
         Side_Now := Opposite (Side_Now);
      end loop;

      --  Backward pass: the recursive "max (0, value - reply)" unwind.
      for P in reverse 1 .. Count loop
         if P = Count and then King_Last then
            Value := Gain (P);
         else
            Value := Gain (P) - Value;
            if Value < 0 then
               --  Recapturing here would lose material: decline instead.
               Value := 0;
            end if;
         end if;
      end loop;

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
         return SEE_Value (Kind (Move.Promotion)) + 100;
      end if;

      -- Quiet (non-tactical) moves have no exchange to evaluate.
      if Move.Flag /= En_Passant then
         Present := Piece_At (Position, Move.To, Captured);
         if not Present then
            return 0;
         end if;
         Victim := SEE_Value (Kind (Captured));
      else
         Victim := SEE_Value (Pawn);
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
