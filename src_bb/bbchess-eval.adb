--
--  AdaChess-BB : static evaluation (body)
--
--  Material + piece-square tables, plus standard positional terms that are
--  easy to compute on bitboards:
--    * mobility (knights, bishops, rooks, queen)
--    * bishop pair
--    * rooks on (semi-)open files and on the 7th rank
--    * passed pawns
--
--  All terms are symmetric under a vertical mirror, so a balanced start
--  position still evaluates to 0.
--

with BBChess.Attacks;
use BBChess.Attacks;

package body BBChess.Eval is

   type PST_Table is array (Natural range 0 .. 7, Natural range 0 .. 7)
     of Score_Type;

   -- Rows: 0 = own back rank, 7 = just before the opponent's back rank.
   Pawn_PST : constant PST_Table :=
     ((0, 0, 0, 0, 0, 0, 0, 0),
      (0, 0, 0, 0, 0, 0, 0, 0),
      (0, 0, 5, 10, 10, 5, 0, 0),
      (0, 0, 5, 20, 20, 5, 0, 0),
      (0, 0, 10, 25, 25, 10, 0, 0),
      (0, 0, 10, 30, 30, 10, 0, 0),
      (0, 10, 20, 50, 50, 20, 10, 0),
      (0, 0, 0, 0, 0, 0, 0, 0));

   Knight_PST : constant PST_Table :=
     ((-50, -40, -30, -30, -30, -30, -40, -50),
      (-40, -20, 0, 0, 0, 0, -20, -40),
      (-30, 0, 10, 15, 15, 10, 0, -30),
      (-30, 5, 15, 20, 20, 15, 5, -30),
      (-30, 0, 15, 20, 20, 15, 0, -30),
      (-30, 5, 10, 15, 15, 10, 5, -30),
      (-40, -20, 0, 5, 5, 0, -20, -40),
      (-50, -40, -30, -30, -30, -30, -40, -50));

   Bishop_PST : constant PST_Table :=
     ((-20, -10, -10, -10, -10, -10, -10, -20),
      (-10, 0, 0, 0, 0, 0, 0, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-10, 5, 5, 10, 10, 5, 5, -10),
      (-10, 0, 10, 10, 10, 10, 0, -10),
      (-10, 5, 5, 10, 10, 5, 5, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-20, -10, -10, -10, -10, -10, -10, -20));

   Rook_PST : constant PST_Table :=
     ((0, 0, 0, 0, 0, 0, 0, 0),
      (5, 10, 10, 10, 10, 10, 10, 5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (5, 10, 10, 10, 10, 10, 10, 5),
      (0, 0, 0, 0, 0, 0, 0, 0));

   Queen_PST : constant PST_Table :=
     ((-20, -10, -10, -5, -5, -10, -10, -20),
      (-10, 0, 0, 0, 0, 0, 0, -10),
      (-10, 0, 5, 5, 5, 5, 0, -10),
      (-5, 0, 5, 5, 5, 5, 0, -5),
      (0, 0, 5, 5, 5, 5, 0, -5),
      (-10, 5, 5, 5, 5, 5, 0, -10),
      (-10, 0, 5, 0, 0, 0, 0, -10),
      (-20, -10, -10, -5, -5, -10, -10, -20));

   King_PST : constant PST_Table :=
     ((20, 30, 10, 0, 0, 10, 30, 20),
      (-10, -10, 0, 0, 0, 0, -10, -10),
      (-20, -20, -20, -20, -20, -20, -20, -20),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-40, -40, -40, -40, -40, -40, -40, -40),
      (-40, -40, -40, -40, -40, -40, -40, -40));

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

   function PST (Kind : in Kind_Type; Color : in Color_Type;
                 Square : in Square_Type) return Score_Type is
      File_Idx : constant Natural := File_Of (Square);
      Row      : Natural;
   begin
      if Color = White then
         Row := Rank_Of (Square);
      else
         Row := 7 - Rank_Of (Square);
      end if;

      case Kind is
         when Pawn   => return Pawn_PST (Row, File_Idx);
         when Knight => return Knight_PST (Row, File_Idx);
         when Bishop => return Bishop_PST (Row, File_Idx);
         when Rook   => return Rook_PST (Row, File_Idx);
         when Queen  => return Queen_PST (Row, File_Idx);
         when King   => return King_PST (Row, File_Idx);
      end case;
   end PST;

   -----------------
   -- File / rank --
   -----------------

   function File_Bits (F : in Natural) return Bitboard is
      Result : Bitboard := 0;
   begin
      for R in 0 .. 7 loop
         Result := Result or Bit (Square_Type (R * 8 + F));
      end loop;
      return Result;
   end File_Bits;

   function Rank_Bits (R : in Natural) return Bitboard is
      Result : Bitboard := 0;
   begin
      for F in 0 .. 7 loop
         Result := Result or Bit (Square_Type (R * 8 + F));
      end loop;
      return Result;
   end Rank_Bits;

   -----------------
   -- Mobility    --
   -----------------

   function Mobility (Piece : in Piece_Type; Square : in Square_Type;
                      Position : in Position_Type) return Natural is
      Occ : constant Bitboard := Occupancy (Position);
      Own : constant Bitboard := Color_Board (Position, Color (Piece));
      Attacks : Bitboard;
   begin
      case Kind (Piece) is
         when Knight => Attacks := Knight_Attacks (Square);
         when Bishop => Attacks := Bishop_Attacks (Square, Occ);
         when Rook   => Attacks := Rook_Attacks (Square, Occ);
         when Queen  => Attacks := Queen_Attacks (Square, Occ);
         when others => return 0;
      end case;
      return Popcount (Attacks and not Own);
   end Mobility;

   ----------------
   -- Rook terms --
   ----------------

   function Rook_Bonus (Color : in Color_Type; Square : in Square_Type;
                        Position : in Position_Type) return Score_Type
   is
      F     : constant Natural := File_Of (Square);
      R     : constant Natural := Rank_Of (Square);
      Own_P : constant Bitboard := Position.Pieces (Make (Color, Pawn));
      En_P  : constant Bitboard := Position.Pieces (Make (Opposite (Color), Pawn));
      Has_Own_Pawn  : constant Boolean := (Own_P and File_Bits (F)) /= 0;
      Has_Enemy_Pawn : constant Boolean := (En_P and File_Bits (F)) /= 0;
      Rel_Row : constant Natural := (if Color = White then R else 7 - R);
      Result : Score_Type := 0;
   begin
      -- Open / semi-open file.
      if not Has_Enemy_Pawn then
         if not Has_Own_Pawn then
            Result := Result + 14;          -- fully open file
         else
            Result := Result + 8;           -- semi-open (enemy side)
         end if;
      end if;

      -- Rook on the 7th rank.
      if Rel_Row = 6 then
         Result := Result + 18;
      end if;
      return Result;
   end Rook_Bonus;

   ----------------
   -- Passed pawn --
   ----------------

   function Pawn_Is_Passed (Color : in Color_Type;
                            Position : in Position_Type;
                            F, R : in Natural) return Boolean
   is
      En_P : constant Bitboard := Position.Pieces (Make (Opposite (Color), Pawn));
      Lo   : constant Natural := (if F = 0 then 0 else F - 1);
      Hi   : constant Natural := (if F = 7 then 7 else F + 1);
   begin
      for FF in Lo .. Hi loop
         if Color = White then
            for R2 in R + 1 .. 7 loop
               if (En_P and Bit (Square_Type (R2 * 8 + FF))) /= 0 then
                  return False;
               end if;
            end loop;
         else
            for R2 in 0 .. R - 1 loop
               if (En_P and Bit (Square_Type (R2 * 8 + FF))) /= 0 then
                  return False;
               end if;
            end loop;
         end if;
      end loop;
      return True;
   end Pawn_Is_Passed;

   function Passed_Bonus (Color : in Color_Type; R : in Natural)
     return Score_Type is
      Rel_Row : constant Natural := (if Color = White then R else 7 - R);
   begin
      if Rel_Row >= 5 then
         return 50;
      elsif Rel_Row >= 3 then
         return 25;
      else
         return 10;
      end if;
   end Passed_Bonus;

   function Static (Position : in Position_Type) return Score_Type is
      Result : Score_Type := 0;
   begin
      for Color in Color_Type loop
         declare
            Sign : constant Score_Type := (if Color = White then 1 else -1);
            Bishop_Count : Natural := 0;
         begin
            for Kind in Kind_Type loop
               declare
                  Piece : constant Piece_Type := Make (Color, Kind);
                  B     : Bitboard := Position.Pieces (Piece);
               begin
                  while B /= 0 loop
                     declare
                        Sq  : constant Square_Type := Lowest_Bit (B);
                        Ext : Score_Type := 0;
                     begin
                        if Kind = Knight or Kind = Bishop then
                           Ext := Ext + 3 * Mobility (Piece, Sq, Position);
                        elsif Kind = Rook then
                           Ext := Ext + 2 * Mobility (Piece, Sq, Position)
                             + Rook_Bonus (Color, Sq, Position);
                        elsif Kind = Queen then
                           Ext := Ext + 1 * Mobility (Piece, Sq, Position);
                        elsif Kind = Pawn then
                           if Pawn_Is_Passed (Color, Position,
                                              File_Of (Sq), Rank_Of (Sq)) then
                              Ext := Ext + Passed_Bonus (Color, Rank_Of (Sq));
                           end if;
                        end if;
                        if Kind = Bishop then
                           Bishop_Count := Bishop_Count + 1;
                        end if;
                        Result := Result + Sign *
                          (Piece_Value (Kind) + PST (Kind, Color, Sq) + Ext);
                     end;
                     B := B and (B - 1);
                  end loop;
               end;
            end loop;

            if Bishop_Count >= 2 then
               Result := Result + Sign * 25;    -- bishop pair
            end if;
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
