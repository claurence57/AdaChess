--
--  AdaChess-BB : static evaluation (body)
--

package body BBChess.Eval is

   function Piece_Value (Kind : in Kind_Type) return Score_Type is
   begin
      case Kind is
         when Pawn   => return 100;
         when Knight => return 320;
         when Bishop => return 330;
         when Rook   => return 500;
         when Queen  => return 900;
         when King   => return 0;
      end case;
   end Piece_Value;

   -- Distance-ish helper: the higher, the closer to the centre files/ranks.
   function Centre_Score (F, R : in Natural) return Score_Type is
      D : constant Integer := Abs (2 * F - 7) + Abs (2 * R - 7);
   begin
      if D <= 4 then
         return 12 - 2 * D;
      end if;
      return 0;
   end Centre_Score;

   function Positional (Color : in Color_Type; Kind : in Kind_Type;
                        Square : in Square_Type) return Score_Type
   is
      F : constant Natural := File_Of (Square);
      R : constant Natural := Rank_Of (Square);
      Result : Score_Type := 0;
   begin
      case Kind is
         when Pawn =>
            -- Advancement: how many ranks the pawn already travelled.
            declare
               Advanced : Natural;
            begin
               if Color = White then
                  Advanced := R;
               else
                  Advanced := 7 - R;
               end if;
               Result := Result + (Advanced - 1) * 6;
            end;
            -- Slight preference for central files.
            if F in 3 .. 4 then
               Result := Result + 5;
            end if;

         when Knight | Bishop | Queen =>
            Result := Result + Centre_Score (F, R);

         when King =>
            null;

         when Rook =>
            null;
      end case;
      return Result;
   end Positional;

   function Static (Position : in Position_Type) return Score_Type is
      Result : Score_Type := 0;
   begin
      for Color in Color_Type loop
         declare
            Sign : constant Score_Type := (if Color = White then 1 else -1);
         begin
            for Kind in Kind_Type loop
               declare
                  Piece : constant Piece_Type := Make (Color, Kind);
                  B     : Bitboard := Position.Pieces (Piece);
                  Value : constant Score_Type := Piece_Value (Kind);
               begin
                  while B /= 0 loop
                     declare
                        Sq : constant Square_Type := Lowest_Bit (B);
                     begin
                        Result := Result +
                          Sign * (Value + Positional (Color, Kind, Sq));
                     end;
                     B := B and (B - 1);
                  end loop;
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Static;

   function Evaluate (Position : in Position_Type) return Score_Type is
   begin
      if Position.Side = White then
         return Static (Position);
      else
         return -Static (Position);
      end if;
   end Evaluate;

end BBChess.Eval;
