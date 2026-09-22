--
--  AdaChess-BB : board representation
--
--  Bitboard basics:
--    * Square_Type : Natural range 0 .. 63.
--    * A square index is computed as Rank * 8 + File, with Rank 0 = rank 1
--      (the white home rank) and File 0 = file A. Hence bit 0 = a1 and
--      bit 63 = h8. Increasing index = "north" is +8 (toward black).
--    * Bitboard : modular 64-bit type. Sets/unions/intersections are done
--      with the usual "or", "and", "not" operators on modular types.
--
--  A Position keeps the pieces as 12 separate bitboards plus the side to
--  move. Color occupancy and full occupancy are derived on demand.
--

with BBChess.Pieces;
use BBChess.Pieces;

package BBChess.Board is

   pragma Elaborate_Body (BBChess.Board);

   subtype Square_Type is Natural range 0 .. 63;

   type Bitboard is mod 2 ** 64;

   function File_Of (Square : in Square_Type) return Natural is (Square mod 8);
   function Rank_Of (Square : in Square_Type) return Natural is (Square / 8);

   pragma Inline (File_Of);
   pragma Inline (Rank_Of);

   -- Precomputed mask with exactly one bit set for each square.
   type Bit_Table_Type is array (Square_Type) of Bitboard;
   Bit : Bit_Table_Type;

   Ep_None : constant Integer := -1;

   type Castle_Side_Type is (King_Side, Queen_Side);
   type Castle_Rights_Type is array (Color_Type, Castle_Side_Type) of Boolean;

   -- Position data: twelve piece bitboards plus the full game state. The
   -- total and per-color occupancies are maintained incrementally by
   -- Put_Piece / Remove_Piece (every mutation goes through them).
   type Piece_Board_Array is array (Piece_Type) of Bitboard;
   type Color_Board_Array is array (Color_Type) of Bitboard;

   -- Square -> piece map, maintained incrementally by Put_Piece /
   -- Remove_Piece, so Piece_At is an O(1) lookup instead of a bitboard scan.
   --
   -- Invariant: Squares (S) is only meaningful while S is in All_Occ. There
   -- is no "empty" value in Piece_Type, so Remove_Piece and Move_Piece leave
   -- a stale value behind on the square they vacate (only Put_Piece and
   -- Move_Piece's destination write a fresh entry). Readers MUST therefore
   -- test All_Occ first -- exactly as Piece_At does -- and never use
   -- Squares (S) directly for an empty square.
   type Square_Piece_Array is array (Square_Type) of Piece_Type;
   type Position_Type is
      record
         Pieces      : Piece_Board_Array := (others => 0);
         All_Occ     : Bitboard := 0;
         Color_Occ   : Color_Board_Array := (others => 0);
         Squares     : Square_Piece_Array := (others => White_Pawn);
         Side        : Color_Type := White;
         Castle      : Castle_Rights_Type := (others => (others => False));
         En_Passant  : Integer := Ep_None;
         Halfmove    : Natural := 0;
         Fullmove    : Positive := 1;
         Key         : Bitboard := 0;
         Material    : Integer := 0;   -- White-positive material + PST
      end record;

   function Piece_Board (Position : in Position_Type; Piece : in Piece_Type)
     return Bitboard is (Position.Pieces (Piece));

   function Piece_At
     (Position : in Position_Type;
      Square   : in Square_Type;
      Piece    : out Piece_Type) return Boolean;
   -- Look up the piece standing on Square. Returns True (and fills Piece)
   -- when Square is occupied, False when it is empty.

   function Color_Board (Position : in Position_Type; Color : in Color_Type)
     return Bitboard;
   -- Union of the six piece boards of the given color.

   function Occupancy (Position : in Position_Type) return Bitboard;
   -- Union of every piece (white + black).

   function Is_Empty (Position : in Position_Type; Square : in Square_Type)
     return Boolean;
   -- True when no piece stands on Square.

   procedure Put_Piece
     (Position : in out Position_Type; Piece : in Piece_Type; Square : in Square_Type);
   -- Place a piece on Square (Square is expected to be empty).

   procedure Remove_Piece
     (Position : in out Position_Type; Piece : in Piece_Type; Square : in Square_Type);
   -- Remove a piece from Square.

   procedure Move_Piece
     (Position : in out Position_Type; Piece : in Piece_Type;
      From, To : in Square_Type);
   -- Relocate Piece from From to To in one pass. To must be empty and
   -- different from From, so the piece/occupancy/colour bitboards are each
   -- toggled by (Bit (From) or Bit (To)) -- three XORs instead of a
   -- Remove_Piece + Put_Piece pair (six and/or operations). Same result.

   function Lowest_Bit (Board : in Bitboard) return Square_Type;
   -- Index of the least significant set bit. Precondition: Board /= 0.

   function Popcount (Board : in Bitboard) return Natural;
   -- Number of set bits (population count).

   procedure Clear_Lowest_Bit (Board : in out Bitboard);
   -- Clear the least significant set bit.

   --  Hot cross-unit primitives: inlined into the search / move generation /
   --  evaluation callers under the release build's -gnatN (semantics
   --  unchanged, the call overhead disappears).
   pragma Inline (Piece_Board);
   pragma Inline (Piece_At);
   pragma Inline (Color_Board);
   pragma Inline (Occupancy);
   pragma Inline (Is_Empty);
   pragma Inline (Lowest_Bit);
   pragma Inline (Popcount);
   pragma Inline (Clear_Lowest_Bit);
   pragma Inline (Put_Piece);
   pragma Inline (Remove_Piece);
   pragma Inline (Move_Piece);

end BBChess.Board;
