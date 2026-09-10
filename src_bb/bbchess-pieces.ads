--
--  AdaChess-BB : pieces
--
--  Colors, piece kinds and concrete pieces. Piece_Type is ordered so that
--  each color occupies a contiguous block of 6 values (Pawn .. King), which
--  allows cheap Color/Kind decomposition via modular arithmetic:
--
--     Color = Piece_Type'Pos (P) < 6  ->  White, else Black
--     Kind  = Kind_Type'Val (Piece_Type'Pos (P) mod 6)
--

package BBChess.Pieces is

   pragma Pure (BBChess.Pieces);

   type Color_Type is (White, Black);
   type Kind_Type  is (Pawn, Knight, Bishop, Rook, Queen, King);

   type Piece_Type is
     (White_Pawn, White_Knight, White_Bishop, White_Rook, White_Queen, White_King,
      Black_Pawn, Black_Knight, Black_Bishop, Black_Rook, Black_Queen, Black_King);

   function Opposite (Color : in Color_Type) return Color_Type is
     (if Color = White then Black else White);

   function Color (Piece : in Piece_Type) return Color_Type is
     (if Piece_Type'Pos (Piece) < 6 then White else Black);

   function Kind (Piece : in Piece_Type) return Kind_Type is
     (Kind_Type'Val (Piece_Type'Pos (Piece) mod 6));

   function Make (Color : in Color_Type; Kind : in Kind_Type) return Piece_Type is
     (Piece_Type'Val (Color_Type'Pos (Color) * 6 + Kind_Type'Pos (Kind)));

   function From_Color (Color : in Color_Type) return Piece_Type is
     (Make (Color, King));

   pragma Inline (Opposite);
   pragma Inline (Color);
   pragma Inline (Kind);
   pragma Inline (Make);

end BBChess.Pieces;
