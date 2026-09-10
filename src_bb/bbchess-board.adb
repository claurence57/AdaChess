--
--  AdaChess-BB : board representation (body)
--

package body BBChess.Board is

   -- Bit intrinsics provided by bbchess-bits.c (GCC __builtin_popcountll /
   -- __builtin_ctzll, built with -mpopcnt -mbmi). These replace the previous
   -- software loops, which dominated the profile.
   function C_Popcount (X : in Bitboard) return Natural
     with Import, Convention => C, External_Name => "bb_popcountll";
   function C_Ctz (X : in Bitboard) return Natural
     with Import, Convention => C, External_Name => "bb_ctzll";

   ---------------
   -- Color_Board --
   ---------------

   function Color_Board (Position : in Position_Type; Color : in Color_Type)
     return Bitboard is
   begin
      return Position.Color_Occ (Color);
   end Color_Board;

   --------------
   -- Occupancy --
   --------------

   function Occupancy (Position : in Position_Type) return Bitboard is
   begin
      return Position.All_Occ;
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
      M : constant Bitboard := Bit (Square);
   begin
      Position.Pieces (Piece) := Position.Pieces (Piece) or M;
      Position.All_Occ := Position.All_Occ or M;
      Position.Color_Occ (Pieces.Color (Piece)) :=
        Position.Color_Occ (Pieces.Color (Piece)) or M;
   end Put_Piece;

   -----------------
   -- Remove_Piece --
   -----------------

   procedure Remove_Piece
     (Position : in out Position_Type; Piece : in Piece_Type; Square : in Square_Type)
   is
      M : constant Bitboard := not Bit (Square);
   begin
      Position.Pieces (Piece) := Position.Pieces (Piece) and M;
      Position.All_Occ := Position.All_Occ and M;
      Position.Color_Occ (Pieces.Color (Piece)) :=
        Position.Color_Occ (Pieces.Color (Piece)) and M;
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
      return Square_Type (C_Ctz (Board));
   end Lowest_Bit;

   -------------
   -- Popcount --
   -------------

   function Popcount (Board : in Bitboard) return Natural is
   begin
      return C_Popcount (Board);
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
