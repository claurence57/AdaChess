--
--  AdaChess-BB : board representation (body)
--

package body BBChess.Board is

   --  GCC builtins imported as compiler intrinsics so they are emitted inline
   --  (POPCNT / BSF) instead of as an out-of-line call into the C shim. Under
   --  the portable build GCC lowers them to the libgcc routines, exactly as
   --  the C shim does, so behaviour is unchanged in both modes.
   function Intrin_Popcount (X : in Bitboard) return Natural
     with Import, Convention => Intrinsic, External_Name => "__builtin_popcountll";
   function Intrin_Ctz (X : in Bitboard) return Natural
     with Import, Convention => Intrinsic, External_Name => "__builtin_ctzll";

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
      Position.Squares (Square) := Piece;
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
      if (Position.All_Occ and Mask) = 0 then
         Piece := White_Pawn;
         return False;
      end if;
      Piece := Position.Squares (Square);
      return True;
   end Piece_At;

   ---------------
   -- Lowest_Bit --
   ---------------

   function Lowest_Bit (Board : in Bitboard) return Square_Type is
   begin
      return Square_Type (Intrin_Ctz (Board));
   end Lowest_Bit;

   -------------
   -- Popcount --
   -------------

   function Popcount (Board : in Bitboard) return Natural is
   begin
      return Intrin_Popcount (Board);
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
