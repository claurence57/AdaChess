--
--  AdaChess-BB : board representation (body)
--

package body BBChess.Board is

   ---------------
   -- Color_Board --
   ---------------

   function Color_Board (Position : in Position_Type; Color : in Color_Type)
     return Bitboard is
      Result : Bitboard := 0;
   begin
      for Piece in Piece_Type loop
         if Pieces.Color (Piece) = Color then
            Result := Result or Position.Pieces (Piece);
         end if;
      end loop;
      return Result;
   end Color_Board;

   --------------
   -- Occupancy --
   --------------

   function Occupancy (Position : in Position_Type) return Bitboard is
      Result : Bitboard := 0;
   begin
      for Piece in Piece_Type loop
         Result := Result or Position.Pieces (Piece);
      end loop;
      return Result;
   end Occupancy;

   --------------
   -- Is_Empty --
   --------------

   function Is_Empty (Position : in Position_Type; Square : in Square_Type)
     return Boolean is
   begin
      return (Occupancy (Position) and Bit (Square)) = 0;
   end Is_Empty;

   --------------
   -- Put_Piece --
   --------------

   procedure Put_Piece
     (Position : in out Position_Type; Piece : in Piece_Type; Square : in Square_Type)
   is
   begin
      Position.Pieces (Piece) := Position.Pieces (Piece) or Bit (Square);
   end Put_Piece;

   -----------------
   -- Remove_Piece --
   -----------------

   procedure Remove_Piece
     (Position : in out Position_Type; Piece : in Piece_Type; Square : in Square_Type)
   is
   begin
      Position.Pieces (Piece) := Position.Pieces (Piece) and not Bit (Square);
   end Remove_Piece;

   --------------
   -- Piece_At --
   --------------

   function Piece_At
     (Position : in Position_Type;
      Square   : in Square_Type;
      Piece    : out Piece_Type) return Boolean
   is
      Mask : constant Bitboard := Bit (Square);
   begin
      for Candidate in Piece_Type loop
         if (Position.Pieces (Candidate) and Mask) /= 0 then
            Piece := Candidate;
            return True;
         end if;
      end loop;
      Piece := White_Pawn;
      return False;
   end Piece_At;

   ---------------
   -- Lowest_Bit --
   ---------------

   function Lowest_Bit (Board : in Bitboard) return Square_Type is
   begin
      for Square in Square_Type loop
         if (Board and Bit (Square)) /= 0 then
            return Square;
         end if;
      end loop;
      raise Program_Error with "Lowest_Bit called on an empty board";
   end Lowest_Bit;

   -------------
   -- Popcount --
   -------------

   function Popcount (Board : in Bitboard) return Natural is
      Value : Bitboard := Board;
      Count : Natural := 0;
   begin
      while Value /= 0 loop
         Value := Value and (Value - 1);
         Count := Count + 1;
      end loop;
      return Count;
   end Popcount;

   ----------------------
   -- Clear_Lowest_Bit --
   ----------------------

   procedure Clear_Lowest_Bit (Board : in out Bitboard) is
   begin
      Board := Board and (Board - 1);
   end Clear_Lowest_Bit;

begin
   for Square in Square_Type loop
      Bit (Square) := 2 ** Square;
   end loop;
end BBChess.Board;
