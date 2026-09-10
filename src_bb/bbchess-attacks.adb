--
--  AdaChess-BB : attack tables (body)
--
--  Leaper tables are computed with simple rank/file steps. Sliding attacks
--  use a BMI2 PEXT lookup: for each square a relevant-occupancy mask is
--  stored and (occupancy PEXT mask) directly indexes the precomputed attack
--  table (a bijection on the subsets of the mask, so no magic search).
--

package body BBChess.Attacks is

   ----------------
   -- Local types --
   ----------------

   type Delta_Step is
      record
         DF : Integer;   -- file delta
         DR : Integer;   -- rank delta
      end record;

   type Delta_Array is array (Positive range <>) of Delta_Step;

   Rook_Deltas : constant Delta_Array :=
     ((1, 0), (-1, 0), (0, 1), (0, -1));

   Bishop_Deltas : constant Delta_Array :=
     ((1, 1), (1, -1), (-1, 1), (-1, -1));

   Knight_Deltas : constant Delta_Array :=
     ((1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2));

   King_Deltas : constant Delta_Array :=
     ((1, 0), (-1, 0), (0, 1), (0, -1),
      (1, 1), (1, -1), (-1, 1), (-1, -1));

   ---------------
   -- Utilities --
   ---------------

   function In_Board (F, R : in Integer) return Boolean is
     (F in 0 .. 7 and R in 0 .. 7);

   function Square_Of (F, R : in Integer) return Square_Type is
     (Square_Type (R * 8 + F));

   -- Parallel bit extract (BMI2), provided by bbchess-bits.c.
   function Pext (X : in Bitboard; Mask : in Bitboard) return Bitboard
     with Import, Convention => C, External_Name => "bb_pext";

   -- Bitboard of the sliding attacks from From, considering Occupancy.
   function Sliding_Attacks
     (From       : in Square_Type;
      Occupancy  : in Bitboard;
      Deltas     : in Delta_Array) return Bitboard
   is
      Result : Bitboard := 0;
   begin
      for D of Deltas loop
         declare
            F : Integer := Integer (File_Of (From)) + D.DF;
            R : Integer := Integer (Rank_Of (From)) + D.DR;
         begin
            while In_Board (F, R) loop
               declare
                  Bit_At : constant Bitboard := Bit (Square_Of (F, R));
               begin
                  Result := Result or Bit_At;
                  exit when (Occupancy and Bit_At) /= 0;
                  F := F + D.DF;
                  R := R + D.DR;
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Sliding_Attacks;

   -- Relevant occupancy mask: every square reachable in the given
   -- directions, except the terminal edge squares of each ray.
   function Slider_Mask (From : in Square_Type; Deltas : in Delta_Array)
     return Bitboard
   is
      Result : Bitboard := 0;
   begin
      for D of Deltas loop
         declare
            F : Integer := Integer (File_Of (From)) + D.DF;
            R : Integer := Integer (Rank_Of (From)) + D.DR;
         begin
            while In_Board (F, R) loop
               if not In_Board (F + D.DF, R + D.DR) then
                  exit;   -- terminal edge square: not needed in the mask
               end if;
               Result := Result or Bit (Square_Of (F, R));
               F := F + D.DF;
               R := R + D.DR;
            end loop;
         end;
      end loop;
      return Result;
   end Slider_Mask;

   -------------
   -- Leapers --
   -------------

   procedure Build_Leaper
     (Result : out Bitboard; From : in Square_Type; Deltas : in Delta_Array)
   is
      Acc : Bitboard := 0;
   begin
      for D of Deltas loop
         declare
            F : constant Integer := Integer (File_Of (From)) + D.DF;
            R : constant Integer := Integer (Rank_Of (From)) + D.DR;
         begin
            if In_Board (F, R) then
               Acc := Acc or Bit (Square_Of (F, R));
            end if;
         end;
      end loop;
      Result := Acc;
   end Build_Leaper;

   ---------------------
   -- PEXT table build --
   ---------------------

   procedure Build_Rook_Table (Square : in Square_Type) is
      Mask : constant Bitboard := Slider_Mask (Square, Rook_Deltas);
      Sub  : Bitboard := Mask;
   begin
      Rook_Mask (Square) := Mask;
      loop
         Rook_Attack_Table (Square, Natural (Pext (Sub, Mask))) :=
           Sliding_Attacks (Square, Sub, Rook_Deltas);
         exit when Sub = 0;
         Sub := (Sub - 1) and Mask;
      end loop;
   end Build_Rook_Table;

   procedure Build_Bishop_Table (Square : in Square_Type) is
      Mask : constant Bitboard := Slider_Mask (Square, Bishop_Deltas);
      Sub  : Bitboard := Mask;
   begin
      Bishop_Mask (Square) := Mask;
      loop
         Bishop_Attack_Table (Square, Natural (Pext (Sub, Mask))) :=
           Sliding_Attacks (Square, Sub, Bishop_Deltas);
         exit when Sub = 0;
         Sub := (Sub - 1) and Mask;
      end loop;
   end Build_Bishop_Table;

   --------------------
   -- Public queries --
   --------------------

   function Bishop_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
   begin
      return Bishop_Attack_Table
        (Square, Natural (Pext (Occupancy, Bishop_Mask (Square))));
   end Bishop_Attacks;

   function Rook_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
   begin
      return Rook_Attack_Table
        (Square, Natural (Pext (Occupancy, Rook_Mask (Square))));
   end Rook_Attacks;

   function Queen_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
   begin
      return Rook_Attacks (Square, Occupancy) or Bishop_Attacks (Square, Occupancy);
   end Queen_Attacks;

begin
   -- Sliding tables (no search: PEXT indexes the subsets directly).
   for Square in Square_Type loop
      Build_Rook_Table (Square);
      Build_Bishop_Table (Square);
   end loop;

   -- Leaper tables.
   for Square in Square_Type loop
      Build_Leaper (Knight_Attacks (Square), Square, Knight_Deltas);
      Build_Leaper (King_Attacks (Square), Square, King_Deltas);

      -- Pawn attacks: White moves up the ranks (+1), Black moves down (-1).
      declare
         F : constant Integer := Integer (File_Of (Square));
         R : constant Integer := Integer (Rank_Of (Square));
         White_Pawn_Acc : Bitboard := 0;
         Black_Pawn_Acc : Bitboard := 0;
      begin
         for DF in -1 .. 1 loop
            if DF /= 0 then
               if In_Board (F + DF, R + 1) then
                  White_Pawn_Acc := White_Pawn_Acc or Bit (Square_Of (F + DF, R + 1));
               end if;
               if In_Board (F + DF, R - 1) then
                  Black_Pawn_Acc := Black_Pawn_Acc or Bit (Square_Of (F + DF, R - 1));
               end if;
            end if;
         end loop;
         Pawn_Attacks (White, Square) := White_Pawn_Acc;
         Pawn_Attacks (Black, Square) := Black_Pawn_Acc;
      end;
   end loop;

   -- File masks.
   for R in 0 .. 7 loop
      File_A_BB := File_A_BB or Bit (Square_Type (R * 8));
      File_H_BB := File_H_BB or Bit (Square_Type (R * 8 + 7));
   end loop;

   -- Between / Line tables (both empty when the squares are not aligned).
   for A in Square_Type loop
      for B in Square_Type loop
         if A /= B then
            if (Rook_Attacks (A, 0) and Bit (B)) /= 0 then
               Between (A, B) :=
                 Rook_Attacks (A, Bit (B)) and Rook_Attacks (B, Bit (A));
               Line (A, B) :=
                 (Rook_Attacks (A, 0) and Rook_Attacks (B, 0))
                 or Bit (A) or Bit (B);
            elsif (Bishop_Attacks (A, 0) and Bit (B)) /= 0 then
               Between (A, B) :=
                 Bishop_Attacks (A, Bit (B)) and Bishop_Attacks (B, Bit (A));
               Line (A, B) :=
                 (Bishop_Attacks (A, 0) and Bishop_Attacks (B, 0))
                 or Bit (A) or Bit (B);
            end if;
         end if;
      end loop;
   end loop;
end BBChess.Attacks;
