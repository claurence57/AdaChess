--
--  AdaChess-BB : attack tables (body)
--
--  Leaper tables are computed with simple rank/file steps. Sliding attacks
--  use "fancy magic bitboards": for each square a magic number is searched
--  so that (occupancy * magic) >> shift yields a collision-free index over
--  every relevant occupancy of that square.
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

   -- Right shift on the modular 64-bit type (division by a power of two).
   function Shift_Right (Value : in Bitboard; Amount : in Natural) return Bitboard is
     (Value / 2 ** Amount);

   ----------
   -- PRNG --
   ----------

   -- Xorshift64*, deterministic seed.
   Rand_State : Bitboard := 16#9E3779B97F4A7C15#;

   function Next_Random return Bitboard is
   begin
      Rand_State := Rand_State xor Shift_Right (Rand_State, 12);
      Rand_State := Rand_State xor (Rand_State * 2 ** 25);
      Rand_State := Rand_State xor Shift_Right (Rand_State, 27);
      return Rand_State * 16#2545F4914F6CDD1D#;
   end Next_Random;

   -------------------
   -- Magic helpers --
   -------------------

   function Magic_Index
     (Occupancy : in Bitboard;
      Magic     : in Bitboard;
      Shift     : in Natural) return Natural
   is
   begin
      return Natural (Shift_Right (Occupancy * Magic, Shift));
   end Magic_Index;

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

   -----------------
   -- Magic build --
   -----------------

   procedure Build_Rook_Magic (Square : in Square_Type) is
      Mask  : constant Bitboard := Slider_Mask (Square, Rook_Deltas);
      Shift : constant Natural := 64 - Popcount (Mask);
      Found : Boolean := False;
      Magic : Bitboard;
      Used  : array (0 .. Max_Rook_Index) of Boolean := (others => False);
   begin
      for Attempt in 1 .. 5_000_000 loop
         Magic := Next_Random and Next_Random and Next_Random;
         if Magic = 0 then
            Magic := 1;
         end if;
         Used  := (others => False);
         Found := True;

         declare
            Sub : Bitboard := Mask;
         begin
            loop
               declare
                  Idx : constant Natural := Magic_Index (Sub, Magic, Shift);
               begin
                  if Used (Idx) then
                     Found := False;
                     exit;
                  end if;
                  Used (Idx) := True;
                  Rook_Attack_Table (Square, Idx) :=
                    Sliding_Attacks (Square, Sub, Rook_Deltas);
               end;
               exit when Sub = 0;
               Sub := (Sub - 1) and Mask;
            end loop;
         end;

         exit when Found;
      end loop;

      if not Found then
         raise Program_Error with "Rook magic search failed on square " &
           Square_Type'Image (Square);
      end if;

      Rook_Magic_Data (Square) := (Magic => Magic, Shift => Shift, Mask => Mask);
   end Build_Rook_Magic;

   procedure Build_Bishop_Magic (Square : in Square_Type) is
      Mask  : constant Bitboard := Slider_Mask (Square, Bishop_Deltas);
      Shift : constant Natural := 64 - Popcount (Mask);
      Found : Boolean := False;
      Magic : Bitboard;
      Used  : array (0 .. Max_Bishop_Index) of Boolean := (others => False);
   begin
      for Attempt in 1 .. 5_000_000 loop
         Magic := Next_Random and Next_Random and Next_Random;
         if Magic = 0 then
            Magic := 1;
         end if;
         Used  := (others => False);
         Found := True;

         declare
            Sub : Bitboard := Mask;
         begin
            loop
               declare
                  Idx : constant Natural := Magic_Index (Sub, Magic, Shift);
               begin
                  if Used (Idx) then
                     Found := False;
                     exit;
                  end if;
                  Used (Idx) := True;
                  Bishop_Attack_Table (Square, Idx) :=
                    Sliding_Attacks (Square, Sub, Bishop_Deltas);
               end;
               exit when Sub = 0;
               Sub := (Sub - 1) and Mask;
            end loop;
         end;

         exit when Found;
      end loop;

      if not Found then
         raise Program_Error with "Bishop magic search failed on square " &
           Square_Type'Image (Square);
      end if;

      Bishop_Magic_Data (Square) := (Magic => Magic, Shift => Shift, Mask => Mask);
   end Build_Bishop_Magic;

   --------------------
   -- Public queries --
   --------------------

   function Bishop_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
      Data : Magic_Data_Type renames Bishop_Magic_Data (Square);
      Idx  : constant Natural :=
        Magic_Index (Occupancy and Data.Mask, Data.Magic, Data.Shift);
   begin
      return Bishop_Attack_Table (Square, Idx);
   end Bishop_Attacks;

   function Rook_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
      Data : Magic_Data_Type renames Rook_Magic_Data (Square);
      Idx  : constant Natural :=
        Magic_Index (Occupancy and Data.Mask, Data.Magic, Data.Shift);
   begin
      return Rook_Attack_Table (Square, Idx);
   end Rook_Attacks;

   function Queen_Attacks (Square : in Square_Type; Occupancy : in Bitboard)
     return Bitboard is
   begin
      return Rook_Attacks (Square, Occupancy) or Bishop_Attacks (Square, Occupancy);
   end Queen_Attacks;

begin
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

   -- Sliding magics.
   for Square in Square_Type loop
      Build_Rook_Magic (Square);
      Build_Bishop_Magic (Square);
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
