--
--  AdaChess-BB : moves and make/unmake (body)
--

with BBChess.Hash;
use BBChess.Hash;

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
               Key             => Position.Key);

      -- Remove the moving piece from its origin square.
      Remove_Piece (Position, Move.Piece, Move.From);

      -- Captures.
      if Move.Flag = En_Passant then
         declare
            Cap_Sq : constant Square_Type :=
              (if Moving = White then Move.To - 8 else Move.To + 8);
         begin
            Undo.Captured        := Make (Opp, Pawn);
            Undo.Has_Captured    := True;
            Undo.Captured_Square := Cap_Sq;
            Remove_Piece (Position, Make (Opp, Pawn), Cap_Sq);
         end;
      else
         -- A capture is detected with the opponent's occupancy (O(1)); the
         -- victim kind is only looked up for the (few) captures.
         if (Position.Color_Occ (Opp) and Bit (Move.To)) /= 0 then
            declare
               Victim : Piece_Type := Make (Opp, Pawn);
            begin
               for K in Kind_Type loop
                  if (Position.Pieces (Make (Opp, K)) and Bit (Move.To)) /= 0 then
                     Victim := Make (Opp, K);
                     exit;
                  end if;
               end loop;
               Undo.Captured        := Victim;
               Undo.Has_Captured    := True;
               Undo.Captured_Square := Move.To;
               Remove_Piece (Position, Victim, Move.To);
            end;
         end if;
      end if;

      -- Place the moving (or promoted) piece on the destination.
      Put_Piece (Position, To_Board, Move.To);

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
            declare
               Cap_Color : constant Color_Type := Color (Undo.Captured);
            begin
               case Undo.Captured_Square is
                  when 0 =>  Position.Castle (White, Queen_Side) := False; -- a1
                  when 7 =>  Position.Castle (White, King_Side)  := False; -- h1
                  when 56 => Position.Castle (Black, Queen_Side) := False; -- a8
                  when 63 => Position.Castle (Black, King_Side)  := False; -- h8
                  when others => null;
               end case;
            end;
         end if;
      end;

      -- En-passant target square after a double pawn push.
      if Move.Flag = Double_Push then
         Position.En_Passant :=
           (if Moving = White then Move.From + 8 else Move.From - 8);
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

            -- Castling rights that were just lost.
            for C in Color_Type loop
               for CS in Castle_Side_Type loop
                  if Undo.Castle (C, CS)
                    and then not Position.Castle (C, CS)
                  then
                     K := K xor Hash.Castle_Key (C, CS);
                  end if;
               end loop;
            end loop;

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
      -- Remove the piece that stands on the destination square...
      Remove_Piece (Position, To_Board, Move.To);

      -- ... and put the moving piece back on its origin square.
      Put_Piece (Position, Move.Piece, Move.From);

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
      return Pos;
   end Start_Position;

end BBChess.Moves;
