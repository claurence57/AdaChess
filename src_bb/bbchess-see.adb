--
--  AdaChess-BB : static exchange evaluation (body)
--
--  The sequence is explored with a small recursive minimax over a working
--  copy of the position: each step removes the chosen attacker from its
--  square, removes the piece standing on the target square and settles the
--  attacker on it, then lets the opponent answer. The occupancy is therefore
--  always up to date, which makes x-ray (sliding) attackers appear as soon
--  as the piece in front of them is gone.

with BBChess.Attacks;
use BBChess.Attacks;

with BBChess.Movegen;
use BBChess.Movegen;

package body BBChess.See is

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
   -- Attackers_Of --
   -----------------

   -- Every piece of Side that attacks To on the current board, including
   -- x-ray sliders (the board occupancy already reflects the captures made
   -- so far). Pinned pieces are filtered out by the caller.
   function Attackers_Of (Work : in Position_Type;
                          To   : in Square_Type;
                          Side : in Color_Type) return Bitboard
   is
      Occ : constant Bitboard := Occupancy (Work);
      Result : Bitboard := 0;
   begin
      -- A Side pawn attacking To sits on a square that a pawn of the
      -- opposite color standing on To would attack.
      Result := Result or
        (Pawn_Attacks (Opposite (Side), To) and Work.Pieces (Make (Side, Pawn)));

      Result := Result or
        (Knight_Attacks (To) and Work.Pieces (Make (Side, Knight)));

      Result := Result or
        (Bishop_Attacks (To, Occ) and
           (Work.Pieces (Make (Side, Bishop)) or Work.Pieces (Make (Side, Queen))));

      Result := Result or
        (Rook_Attacks (To, Occ) and
           (Work.Pieces (Make (Side, Rook)) or Work.Pieces (Make (Side, Queen))));

      Result := Result or
        (King_Attacks (To) and Work.Pieces (Make (Side, King)));

      return Result;
   end Attackers_Of;

   -------------
   -- Weakest --
   -------------

   -- Least valuable attacker of Side on To that is not absolutely pinned.
   -- The king is only returned when no other piece can take part.
   procedure Weakest (Work   : in Position_Type;
                      To     : in Square_Type;
                      Side   : in Color_Type;
                      Found  : out Boolean;
                      From   : out Square_Type;
                      Piece  : out Piece_Type)
   is
      Occ     : constant Bitboard := Occupancy (Work);
      Pinned  : constant Bitboard := Pin_Mask (Work, Side);
      Cand    : Bitboard;
   begin
      Found := False;
      From   := 0;
      Piece  := Make (Side, Pawn);

      Cand := (Pawn_Attacks (Opposite (Side), To)
                 and Work.Pieces (Make (Side, Pawn))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Pawn); return;
      end if;

      Cand := (Knight_Attacks (To) and Work.Pieces (Make (Side, Knight))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Knight); return;
      end if;

      Cand := (Bishop_Attacks (To, Occ) and Work.Pieces (Make (Side, Bishop))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Bishop); return;
      end if;

      Cand := (Rook_Attacks (To, Occ) and Work.Pieces (Make (Side, Rook))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Rook); return;
      end if;

      Cand := ((Bishop_Attacks (To, Occ) or Rook_Attacks (To, Occ))
                 and Work.Pieces (Make (Side, Queen))) and not Pinned;
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, Queen); return;
      end if;

      Cand := King_Attacks (To) and Work.Pieces (Make (Side, King));
      if Cand /= 0 then
         Found := True; From := Lowest_Bit (Cand); Piece := Make (Side, King);
      end if;
   end Weakest;

   ----------------
   -- Exchange --
   ----------------

   -- Best outcome (>= 0, a side may always decline) for Side of the capture
   -- sequence on To, knowing a piece of the opponent currently stands there.
   -- Work is consumed along the way: every capture removes a piece.
   function Exchange (Work : in out Position_Type;
                      To   : in Square_Type;
                      Side : in Color_Type) return Score_Type
   is
      On_Piece : Piece_Type;
      Present  : Boolean;
      Found    : Boolean;
      From     : Square_Type;
      Att      : Piece_Type;
      Value    : Score_Type;
   begin
      Present := Piece_At (Work, To, On_Piece);
      if not Present then
         -- Nothing to gain by capturing an empty square.
         return 0;
      end if;

      Weakest (Work, To, Side, Found, From, Att);
      if not Found then
         -- No attacker available: the opponent simply stands pat.
         return 0;
      end if;

      -- Make the recapture.
      Remove_Piece (Work, Att, From);
      Remove_Piece (Work, On_Piece, To);
      Put_Piece (Work, Att, To);

      if Kind (Att) = King then
         -- A king capture ends the sequence: the king itself cannot be
         -- taken back in a legal exchange.
         return Kind_Value (Kind (On_Piece));
      end if;

      Value := Kind_Value (Kind (On_Piece)) - Exchange (Work, To, Opposite (Side));
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
      Work        : Position_Type := Position;
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
         Remove_Piece (Work, Captured, Move.To);
      else
         Victim := Kind_Value (Pawn);
         -- The captured pawn stands just behind the (empty) target square.
         if Side = White then
            Victim_Square := Move.To - 8;
         else
            Victim_Square := Move.To + 8;
         end if;
         Remove_Piece (Work, Make (Opp, Pawn), Victim_Square);
      end if;

      -- The mover leaves its square and settles on the target square.
      Remove_Piece (Work, Move.Piece, Move.From);
      Put_Piece (Work, Move.Piece, Move.To);

      return Victim - Exchange (Work, Move.To, Opp);
   end Static_Exchange_Value;

end BBChess.See;
