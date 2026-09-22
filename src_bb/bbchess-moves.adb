--
--  AdaChess-BB : moves and make/unmake (body)
--

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Eval;
use BBChess.Eval;

package body BBChess.Moves is

   -- Castle-relevant squares.
   D1 : constant Square_Type := 3;
   F1 : constant Square_Type := 5;
   H1 : constant Square_Type := 7;
   A1 : constant Square_Type := 0;

   D8 : constant Square_Type := 59;
   F8 : constant Square_Type := 61;
   H8 : constant Square_Type := 63;
   A8 : constant Square_Type := 56;

   ---------------
   -- Rook_From --
   ---------------

   function Rook_From (Side : in Color_Type; Flag : in Move_Flag_Type)
     return Square_Type is
   begin
      case Side is
         when White =>
            return (if Flag = King_Side_Castle then H1 else A1);
         when Black =>
            return (if Flag = King_Side_Castle then H8 else A8);
      end case;
   end Rook_From;

   ---------------
   -- Pack_Move --
   ---------------

   function Pack_Move (Move : in Move_Type) return Packed_Move is
   begin
      return Packed_Move (Move.From)
        + Packed_Move (Move.To) * 2 ** 6
        + Packed_Move (Piece_Type'Pos (Move.Piece)) * 2 ** 12
        + Packed_Move (Piece_Type'Pos (Move.Promotion)) * 2 ** 16
        + Packed_Move (Move_Flag_Type'Pos (Move.Flag)) * 2 ** 20;
   end Pack_Move;

   -----------------
   -- Unpack_Move --
   -----------------

   function Unpack_Move (Value : in Packed_Move) return Move_Type is
      V : constant Natural := Natural (Value);
   begin
      return
        (From      => Square_Type (V mod 2 ** 6),
         To        => Square_Type ((V / 2 ** 6) mod 2 ** 6),
         Piece     => Piece_Type'Val ((V / 2 ** 12) mod 2 ** 4),
         Promotion => Piece_Type'Val ((V / 2 ** 16) mod 2 ** 4),
         Flag      => Move_Flag_Type'Val ((V / 2 ** 20) mod 2 ** 3));
   end Unpack_Move;

   -------------
   -- Rook_To --
   -------------

   function Rook_To (Side : in Color_Type; Flag : in Move_Flag_Type)
     return Square_Type is
   begin
      case Side is
         when White =>
            return (if Flag = King_Side_Castle then F1 else D1);
         when Black =>
            return (if Flag = King_Side_Castle then F8 else D8);
      end case;
   end Rook_To;

   --------------
   -- Make_Move --
   --------------

   procedure Make_Move
     (Position : in out Position_Type;
      Move      : in Move_Type;
      Undo      : out Undo_Info)
   is
      Moving : constant Color_Type := Color (Move.Piece);
      Opp    : constant Color_Type := Opposite (Moving);
      To_Board : constant Piece_Type :=
        (if Move.Flag = Promotion then Move.Promotion else Move.Piece);
   begin
      Undo := (Captured        => White_Pawn,
               Has_Captured    => False,
               Captured_Square => 0,
               En_Passant      => Position.En_Passant,
               Castle          => Position.Castle,
               Halfmove        => Position.Halfmove,
                Fullmove        => Position.Fullmove,
                Key             => Position.Key,
                Material        => Position.Material);

      -- Remove the moving piece from its origin square, then (below) place it
      -- on the destination. For a non-promotion move the two are fused after
      -- the capture handling; a promotion changes the piece kind, so it keeps
      -- the separate remove / put pair.
      if Move.Flag = Promotion then
         Remove_Piece (Position, Move.Piece, Move.From);
      end if;

      -- Captures.
      if Move.Flag = En_Passant then
         -- The captured pawn stands directly behind the destination: one rank
         -- "south" (minus 8) for White, one rank "north" (plus 8) for Black,
         -- i.e. the ep target square itself. A legal en-passant move always
         -- has Move.To on rank 6 (White) or rank 3 (Black), so the captured
         -- square is a valid 0 .. 63 index. The release build is compiled with
         -- -gnatp (run-time checks off), so this arithmetic is nevertheless
         -- carried in Integer and range-checked by hand: a malformed move
         -- would otherwise wrap out of Square_Type and corrupt the board.
         -- A malformed en-passant move is treated as a non-capture (the board
         -- is left untouched); every legal move is unaffected.
         declare
            Cap_Value : constant Integer :=
              (if Moving = White then Move.To - 8 else Move.To + 8);
         begin
            pragma Assert
              ((if Moving = White then Rank_Of (Move.To) = 5
                                     else Rank_Of (Move.To) = 2),
               "en passant: target must be on rank 6 (White) / rank 3 (Black)");
            if Cap_Value in 0 .. 63 then
               declare
                  Cap_Sq : constant Square_Type := Square_Type (Cap_Value);
               begin
                  pragma Assert
                    (Rank_Of (Cap_Sq) = (if Moving = White then 4 else 3),
                     "en passant: captured pawn must sit on rank 5 / rank 4");
                  Undo.Captured        := Make (Opp, Pawn);
                  Undo.Has_Captured    := True;
                  Undo.Captured_Square := Cap_Sq;
                  Remove_Piece (Position, Make (Opp, Pawn), Cap_Sq);
               end;
            end if;
         end;
      else
         -- A capture is detected with the opponent's occupancy (O(1)); the
         -- victim kind is read from the incremental square map (also O(1)),
         -- instead of rescanning the six opponent kind-bitboards.
         if (Position.Color_Occ (Opp) and Bit (Move.To)) /= 0 then
            declare
               Victim : Piece_Type;
               Ignored : Boolean;
            begin
               Ignored := Piece_At (Position, Move.To, Victim);
               Undo.Captured        := Victim;
               Undo.Has_Captured    := True;
               Undo.Captured_Square := Move.To;
               Remove_Piece (Position, Victim, Move.To);
            end;
         end if;
      end if;

      -- Place the moving (or promoted) piece on the destination.
      if Move.Flag = Promotion then
         Put_Piece (Position, To_Board, Move.To);
      else
         Move_Piece (Position, Move.Piece, Move.From, Move.To);
      end if;

      -- Castling also relocates the rook.
      if Move.Flag in King_Side_Castle | Queen_Side_Castle then
         declare
            Rook_Piece : constant Piece_Type := Make (Moving, Rook);
         begin
            Remove_Piece (Position, Rook_Piece, Rook_From (Moving, Move.Flag));
            Put_Piece (Position, Rook_Piece, Rook_To (Moving, Move.Flag));
         end;
      end if;

      -- Update the castling rights. These are event-driven (a right is lost
      -- when the king moves, when the home rook moves, or when a home rook
      -- is captured). They are NOT derived from the board placement: a king
      -- that left e8 and later returned has no castling rights anymore.
      declare
         Moved_King  : constant Boolean := Kind (Move.Piece) = King;
         Moved_Rook  : constant Boolean := Kind (Move.Piece) = Rook;
      begin
         if Moved_King then
            Position.Castle (Moving, King_Side)  := False;
            Position.Castle (Moving, Queen_Side) := False;
         elsif Moved_Rook then
            case Move.From is
               when 0 =>  Position.Castle (White, Queen_Side) := False; -- a1
               when 7 =>  Position.Castle (White, King_Side)  := False; -- h1
               when 56 => Position.Castle (Black, Queen_Side) := False; -- a8
               when 63 => Position.Castle (Black, King_Side)  := False; -- h8
               when others => null;
            end case;
         end if;

         if Undo.Has_Captured and then Kind (Undo.Captured) = Rook then
            case Undo.Captured_Square is
               when 0 =>  Position.Castle (White, Queen_Side) := False; -- a1
               when 7 =>  Position.Castle (White, King_Side)  := False; -- h1
               when 56 => Position.Castle (Black, Queen_Side) := False; -- a8
               when 63 => Position.Castle (Black, King_Side)  := False; -- h8
               when others => null;
            end case;
         end if;
      end;

      -- En-passant target square after a double pawn push. A legal double
      -- push starts on rank 2 (White, index 8..15) or rank 7 (Black, index
      -- 48..55), so the target is always a valid square. As for the en-passant
      -- capture above, the computation is done in Integer and range-checked by
      -- hand rather than relying on the (disabled) run-time checks; a
      -- malformed move simply leaves no en-passant target.
      if Move.Flag = Double_Push then
         declare
            Ep_Value : constant Integer :=
              (if Moving = White then Move.From + 8 else Move.From - 8);
         begin
            pragma Assert
              ((if Moving = White then Rank_Of (Move.From) = 1
                                     else Rank_Of (Move.From) = 6),
               "double push: origin must be on rank 2 (White) / rank 7 (Black)");
            if Ep_Value in 0 .. 63 then
               Position.En_Passant := Ep_Value;
            else
               Position.En_Passant := Ep_None;
            end if;
         end;
      else
         Position.En_Passant := Ep_None;
      end if;

      -- Clocks.
      if Kind (Move.Piece) = Pawn or else Undo.Has_Captured then
         Position.Halfmove := 0;
      else
         Position.Halfmove := Position.Halfmove + 1;
      end if;

      if Moving = Black then
         Position.Fullmove := Position.Fullmove + 1;
      end if;

      Position.Side := Opp;

      -- Incremental Zobrist update: XOR out the old state and XOR in the new
      -- one. This reproduces Hash.Compute exactly (checked by a self test)
      -- without rescanning the whole board on every node.
      if Hash.Keys_Enabled then
         declare
            K : Bitboard := Position.Key;
         begin
            -- The moving (or promoted) piece and the captured one.
            K := K xor Hash.Piece_Key (Move.Piece, Move.From);
            K := K xor Hash.Piece_Key (To_Board, Move.To);
            if Undo.Has_Captured then
               K := K xor Hash.Piece_Key (Undo.Captured, Undo.Captured_Square);
            end if;

            -- Castling also relocates the rook.
            if Move.Flag in King_Side_Castle | Queen_Side_Castle then
               K := K xor Hash.Piece_Key (Make (Moving, Rook),
                                          Rook_From (Moving, Move.Flag));
               K := K xor Hash.Piece_Key (Make (Moving, Rook),
                                          Rook_To (Moving, Move.Flag));
            end if;

            -- Castling rights that were just lost. The rights change only
            -- when the king/rook moved or a rook was captured, i.e. rarely;
            -- comparing the before/after rights tables (four booleans) lets
            -- the common case skip the loop entirely.
            if Position.Castle /= Undo.Castle then
               for C in Color_Type loop
                  for CS in Castle_Side_Type loop
                     if Undo.Castle (C, CS)
                       and then not Position.Castle (C, CS)
                     then
                        K := K xor Hash.Castle_Key (C, CS);
                     end if;
                  end loop;
               end loop;
            end if;

            -- En-passant file: remove the old one, add the new one.
            if Undo.En_Passant /= Ep_None then
               K := K xor Hash.Ep_Key (Undo.En_Passant mod 8);
            end if;
            if Position.En_Passant /= Ep_None then
               K := K xor Hash.Ep_Key (Position.En_Passant mod 8);
            end if;

            -- The side to move always flips.
            K := K xor Hash.Side_Key;

            Position.Key := K;
         end;
      end if;

      -- Incremental material + PST (White-positive). The delta mirrors the
      -- piece removals/additions performed above.
      declare
         function Signed (P : in Piece_Type; S : in Square_Type)
           return Integer is
           (if Color (P) = White
            then Material_PST_Value (P, S)
            else -Material_PST_Value (P, S));
         D : Integer := Signed (To_Board, Move.To)
                            - Signed (Move.Piece, Move.From);
      begin
         if Undo.Has_Captured then
            D := D - Signed (Undo.Captured, Undo.Captured_Square);
         end if;
         if Move.Flag in King_Side_Castle | Queen_Side_Castle then
            D := D
              + Signed (Make (Moving, Rook), Rook_To (Moving, Move.Flag))
              - Signed (Make (Moving, Rook), Rook_From (Moving, Move.Flag));
         end if;
         Position.Material := Position.Material + D;
      end;
   end Make_Move;

   ----------------
   -- Unmake_Move --
   ----------------

   procedure Unmake_Move
     (Position : in out Position_Type;
      Move      : in Move_Type;
      Undo      : in Undo_Info)
   is
      Moving : constant Color_Type := Color (Move.Piece);
      To_Board : constant Piece_Type :=
        (if Move.Flag = Promotion then Move.Promotion else Move.Piece);
   begin
      if Move.Flag = Promotion then
         -- Remove the piece that stands on the destination square...
         Remove_Piece (Position, To_Board, Move.To);

         -- ... and put the moving piece back on its origin square.
         Put_Piece (Position, Move.Piece, Move.From);
      else
         -- ... or move it straight back in one pass.
         Move_Piece (Position, Move.Piece, Move.To, Move.From);
      end if;

      -- Restore the captured piece, if any.
      if Undo.Has_Captured then
         Put_Piece (Position, Undo.Captured, Undo.Captured_Square);
      end if;

      -- Castling: move the rook back to its corner.
      if Move.Flag in King_Side_Castle | Queen_Side_Castle then
         declare
            Rook_Piece : constant Piece_Type := Make (Moving, Rook);
         begin
            Remove_Piece (Position, Rook_Piece, Rook_To (Moving, Move.Flag));
            Put_Piece (Position, Rook_Piece, Rook_From (Moving, Move.Flag));
         end;
      end if;

      -- Restore the remaining state.
      Position.Castle     := Undo.Castle;
      Position.En_Passant := Undo.En_Passant;
      Position.Halfmove   := Undo.Halfmove;
      Position.Fullmove   := Undo.Fullmove;
      Position.Side       := Moving;
      Position.Key        := Undo.Key;
      Position.Material   := Undo.Material;
   end Unmake_Move;

   --------------------
   -- Start_Position --
   --------------------

   function Start_Position return Position_Type is
      Pos : Position_Type;
   begin
      Pos.Side := White;

      -- White back rank (rank 1, squares 0..7).
      Put_Piece (Pos, Make (White, Rook), 0);
      Put_Piece (Pos, Make (White, Knight), 1);
      Put_Piece (Pos, Make (White, Bishop), 2);
      Put_Piece (Pos, Make (White, Queen), 3);
      Put_Piece (Pos, Make (White, King), 4);
      Put_Piece (Pos, Make (White, Bishop), 5);
      Put_Piece (Pos, Make (White, Knight), 6);
      Put_Piece (Pos, Make (White, Rook), 7);

      -- Black back rank (rank 8, squares 56..63).
      Put_Piece (Pos, Make (Black, Rook), 56);
      Put_Piece (Pos, Make (Black, Knight), 57);
      Put_Piece (Pos, Make (Black, Bishop), 58);
      Put_Piece (Pos, Make (Black, Queen), 59);
      Put_Piece (Pos, Make (Black, King), 60);
      Put_Piece (Pos, Make (Black, Bishop), 61);
      Put_Piece (Pos, Make (Black, Knight), 62);
      Put_Piece (Pos, Make (Black, Rook), 63);

      -- Pawns.
      for File in 0 .. 7 loop
         Put_Piece (Pos, Make (White, Pawn), Square_Type (8 + File));
         Put_Piece (Pos, Make (Black, Pawn), Square_Type (48 + File));
      end loop;

      Pos.Castle := (others => (others => True));
      Pos.Key := Hash.Compute (Pos);
      Pos.Material := Compute_Material (Pos);
      return Pos;
   end Start_Position;

end BBChess.Moves;
