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

   -- Position data: twelve piece bitboards plus the full game state.
   type Piece_Board_Array is array (Piece_Type) of Bitboard;
   type Position_Type is
      record
         Pieces      : Piece_Board_Array := (others => 0);
         Side        : Color_Type := White;
         Castle      : Castle_Rights_Type := (others => (others => False));
         En_Passant  : Integer := Ep_None;
         Halfmove    : Natural := 0;
         Fullmove    : Positive := 1;
         Key         : Bitboard := 0;
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

   function Lowest_Bit (Board : in Bitboard) return Square_Type;
   -- Index of the least significant set bit. Precondition: Board /= 0.

   function Popcount (Board : in Bitboard) return Natural;
   -- Number of set bits (population count).

   procedure Clear_Lowest_Bit (Board : in out Bitboard);
   -- Clear the least significant set bit.

end BBChess.Board;
