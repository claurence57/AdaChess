--
--  AdaChess-BB : moves and make/unmake
--
--  A move is stored as a small record. Special moves are encoded through
--  the Flag field plus (for promotions) the Promotion field. Make/Unmake
--  keep the position as a plain snapshot: each Make returns an Undo_Info
--  that fully restores the previous state when passed back to Unmake.
--  This makes the position trivially copyable (useful for perft, search
--  and FEN handling).
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Moves is

   type Move_Flag_Type is
     (Quiet,
      Double_Push,
      En_Passant,
      King_Side_Castle,
      Queen_Side_Castle,
      Promotion);

   type Move_Type is
      record
         From      : Square_Type := 0;
         To        : Square_Type := 0;
         Piece     : Piece_Type := White_Pawn;
         Promotion : Piece_Type := White_Pawn;   -- valid when Flag = Promotion
         Flag      : Move_Flag_Type := Quiet;
      end record;

   Empty_Move : constant Move_Type := (others => <>);

   -- Compact 32-bit encoding of a move (transposition table storage). The
   -- layout is: from 6, to 6, piece 4, promotion 4, flag 3. Empty_Move
   -- packs to 0.
   type Packed_Move is mod 2 ** 32;
   function Pack_Move (Move : in Move_Type) return Packed_Move;
   function Unpack_Move (Value : in Packed_Move) return Move_Type;

   type Undo_Info is
      record
         Captured        : Piece_Type := White_Pawn;
         Has_Captured    : Boolean := False;
         Captured_Square : Square_Type := 0;
         En_Passant      : Integer := Ep_None;
         Castle          : Castle_Rights_Type;
         Halfmove        : Natural := 0;
         Fullmove        : Positive := 1;
         Key             : Bitboard := 0;
         Material        : Integer := 0;
      end record;

   procedure Make_Move
     (Position : in out Position_Type;
      Move      : in Move_Type;
      Undo      : out Undo_Info);
   -- Apply Move to Position (moving side = Color (Move.Piece)). Undo holds
   -- enough data for Unmake_Move to restore Position exactly.

   procedure Unmake_Move
     (Position : in out Position_Type;
      Move      : in Move_Type;
      Undo      : in Undo_Info);
   -- Restore Position to the state it had before Make_Move (Position, Move, Undo).

   function Start_Position return Position_Type;
   -- The standard chess starting position (all castle rights, no en-passant).

private

   -- Rook origin/destination squares used when castling.
   function Rook_From (Side : in Color_Type; Flag : in Move_Flag_Type)
     return Square_Type;
   function Rook_To (Side : in Color_Type; Flag : in Move_Flag_Type)
     return Square_Type;

end BBChess.Moves;
