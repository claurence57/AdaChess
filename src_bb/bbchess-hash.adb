--
--  AdaChess-BB : Zobrist hashing (body)
--

package body BBChess.Hash is

   Piece_Key_Val : array (Piece_Type, Square_Type) of Bitboard;
   Side_Key_Val  : Bitboard;
   Castle_Key_Val : array (Color_Type, Castle_Side_Type) of Bitboard;
   Ep_Key_Val    : array (Natural range 0 .. 7) of Bitboard;

   -- Deterministic LCG (no external randomness needed).
   Seed : Bitboard := 16#853C49E6748FEA9B#;

   Keys_Enabled_Flag : Boolean := False;

   function Next_Random return Bitboard is
   begin
      Seed := Seed * 6364136223846793005 + 1442695040888963407;
      return Seed;
   end Next_Random;

   procedure Fill_Tables is
   begin
      for P in Piece_Type loop
         for S in Square_Type loop
            Piece_Key_Val (P, S) := Next_Random;
         end loop;
      end loop;
      for C in Color_Type loop
         for CS in Castle_Side_Type loop
            Castle_Key_Val (C, CS) := Next_Random;
         end loop;
      end loop;
      for F in 0 .. 7 loop
         Ep_Key_Val (F) := Next_Random;
      end loop;
      Side_Key_Val := Next_Random;
   end Fill_Tables;

   function Piece_Key (Piece : in Piece_Type; Square : in Square_Type)
     return Bitboard is
   begin
      return Piece_Key_Val (Piece, Square);
   end Piece_Key;

   function Side_Key return Bitboard is
   begin
      return Side_Key_Val;
   end Side_Key;

   function Castle_Key (Color : in Color_Type; Side : in Castle_Side_Type)
     return Bitboard is
   begin
      return Castle_Key_Val (Color, Side);
   end Castle_Key;

   function Ep_Key (File : in Natural) return Bitboard is
   begin
      return Ep_Key_Val (File);
   end Ep_Key;

   procedure Set_Keys_Enabled (On : in Boolean) is
   begin
      Keys_Enabled_Flag := On;
   end Set_Keys_Enabled;

   function Keys_Enabled return Boolean is
   begin
      return Keys_Enabled_Flag;
   end Keys_Enabled;

   function Compute (Position : in Position_Type) return Bitboard is
      Result : Bitboard := 0;
   begin
      for P in Piece_Type loop
         declare
            B : Bitboard := Position.Pieces (P);
         begin
            while B /= 0 loop
               declare
                  S : constant Square_Type := Lowest_Bit (B);
               begin
                  Result := Result xor Piece_Key_Val (P, S);
               end;
               B := B and (B - 1);
            end loop;
         end;
      end loop;

      if Position.Side = Black then
         Result := Result xor Side_Key_Val;
      end if;

      for C in Color_Type loop
         for CS in Castle_Side_Type loop
            if Position.Castle (C, CS) then
               Result := Result xor Castle_Key_Val (C, CS);
            end if;
         end loop;
      end loop;

      if Position.En_Passant /= Ep_None then
         Result := Result xor Ep_Key_Val (Position.En_Passant mod 8);
      end if;

      return Result;
   end Compute;

begin
   Fill_Tables;
end BBChess.Hash;
