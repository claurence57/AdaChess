--
--  AdaChess-BB : attack tables
--
--  Precomputed attack sets:
--    * Knight_Attacks / King_Attacks / Pawn_Attacks : leapers, table lookups.
--    * Bishop_Attacks / Rook_Attacks : "fancy magic bitboards" (one lookup).
--    * Queen_Attacks = Rook_Attacks or Bishop_Attacks.
--
--  All tables are built once at elaboration (deterministic seed). The
--  caller only provides an occupancy bitboard (any subset of the 64 squares).
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Attacks is

   pragma Elaborate_Body (BBChess.Attacks);

   -- Leaper attacks, indexed by the origin square.
   Knight_Attacks : array (Square_Type) of Bitboard := (others => 0);
   King_Attacks   : array (Square_Type) of Bitboard := (others => 0);
   Pawn_Attacks   : array (Color_Type, Square_Type) of Bitboard := (others => (others => 0));

   -- Sliding attacks (consider the given occupancy).
   function Bishop_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard;
   function Rook_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard;
   function Queen_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard;

private

   -- Maximum index used by the magic lookup (rook relevant bits <= 12,
   -- bishop relevant bits <= 9).
   Max_Rook_Index   : constant := 4095;
   Max_Bishop_Index : constant := 511;

   type Rook_Attack_Table_Type is
     array (Square_Type, Natural range 0 .. Max_Rook_Index) of Bitboard;
   Rook_Attack_Table : Rook_Attack_Table_Type := (others => (others => 0));

   type Bishop_Attack_Table_Type is
     array (Square_Type, Natural range 0 .. Max_Bishop_Index) of Bitboard;
   Bishop_Attack_Table : Bishop_Attack_Table_Type := (others => (others => 0));

   type Magic_Data_Type is
      record
         Magic : Bitboard := 0;
         Shift : Natural := 64;
         Mask  : Bitboard := 0;
      end record;

   type Magic_Data_Array is array (Square_Type) of Magic_Data_Type;
   Rook_Magic_Data   : Magic_Data_Array;
   Bishop_Magic_Data : Magic_Data_Array;

end BBChess.Attacks;
