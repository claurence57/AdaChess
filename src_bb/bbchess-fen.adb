--
--  AdaChess-BB : FEN loading (body)
--

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Movegen;
use BBChess.Movegen;

package body BBChess.Fen is

   function Kind_Of (C : in Character) return Kind_Type is
   begin
      case C is
         when 'P' | 'p' => return Pawn;
         when 'N' | 'n' => return Knight;
         when 'B' | 'b' => return Bishop;
         when 'R' | 'r' => return Rook;
         when 'Q' | 'q' => return Queen;
         when 'K' | 'k' => return King;
         when others => raise Constraint_Error with "invalid piece in FEN: " & C;
      end case;
   end Kind_Of;

   -- Split Text into its space separated fields, field I (1-based).
   function Field (Text : in String; I : in Positive) return String is
      Idx     : Positive := Text'First;
      Current : Natural := 1;
      Start   : Positive;
   begin
      while Current < I loop
         -- Skip leading spaces.
         while Idx <= Text'Last and then Text (Idx) = ' ' loop
            Idx := Idx + 1;
         end loop;
         if Idx > Text'Last then
            return "";
         end if;
         -- Skip the token.
         while Idx <= Text'Last and then Text (Idx) /= ' ' loop
            Idx := Idx + 1;
         end loop;
         Current := Current + 1;
      end loop;

      while Idx <= Text'Last and then Text (Idx) = ' ' loop
         Idx := Idx + 1;
      end loop;
      Start := Idx;
      while Idx <= Text'Last and then Text (Idx) /= ' ' loop
         Idx := Idx + 1;
      end loop;
      return Text (Start .. Idx - 1);
   end Field;

   function File_Index (C : in Character) return Natural is
   begin
      case C is
         when 'a' => return 0;
         when 'b' => return 1;
         when 'c' => return 2;
         when 'd' => return 3;
         when 'e' => return 4;
         when 'f' => return 5;
         when 'g' => return 6;
         when 'h' => return 7;
         when others => raise Constraint_Error with "invalid file in FEN: " & C;
      end case;
   end File_Index;

   procedure Load (Position : out Position_Type; Text : in String) is
      Pos   : Position_Type;
      Board : constant String := Field (Text, 1);
      Idx   : Positive := Board'First;
   begin
      -- Board placement: ranks are given top (rank 8) to bottom (rank 1).
      for Rank_Token in 0 .. 7 loop
         declare
            Rank_Index : constant Integer := 7 - Rank_Token;
            File_Index_Of_Piece : Integer := 0;
         begin
            while File_Index_Of_Piece <= 7 loop
               if Idx > Board'Last then
                  raise Constraint_Error with "FEN board too short";
               end if;
               if Board (Idx) in '1' .. '8' then
                  File_Index_Of_Piece :=
                    File_Index_Of_Piece + (Character'Pos (Board (Idx)) - Character'Pos ('0'));
               elsif Board (Idx) = '/' then
                  null;
               else
                  declare
                     C : constant Character := Board (Idx);
                  begin
                     if C in 'A' .. 'Z' then
                        Put_Piece (Pos, Make (White, Kind_Of (C)),
                                   Square_Type (Rank_Index * 8 + File_Index_Of_Piece));
                     else
                        Put_Piece (Pos, Make (Black, Kind_Of (C)),
                                   Square_Type (Rank_Index * 8 + File_Index_Of_Piece));
                     end if;
                     File_Index_Of_Piece := File_Index_Of_Piece + 1;
                  end;
               end if;
               Idx := Idx + 1;
            end loop;
         end;
         if Rank_Token < 7 then
            -- skip the '/' separator
            if Idx <= Board'Last and then Board (Idx) = '/' then
               Idx := Idx + 1;
            end if;
         end if;
      end loop;

      -- Side to move.
      declare
         Side : constant String := Field (Text, 2);
      begin
         if Side = "b" then
            Pos.Side := Black;
         else
            Pos.Side := White;
         end if;
      end;

      -- Castling rights.
      declare
         Castle : constant String := Field (Text, 3);
      begin
         Pos.Castle := (others => (others => False));
         for C of Castle loop
            case C is
               when 'K' => Pos.Castle (White, King_Side) := True;
               when 'Q' => Pos.Castle (White, Queen_Side) := True;
               when 'k' => Pos.Castle (Black, King_Side) := True;
               when 'q' => Pos.Castle (Black, Queen_Side) := True;
               when others => null;
            end case;
         end loop;
      end;

      -- En passant square.
      declare
         Ep : constant String := Field (Text, 4);
      begin
         if Ep = "-" or else Ep = "" then
            Pos.En_Passant := Ep_None;
         else
            Pos.En_Passant :=
              (Character'Pos (Ep (Ep'Last)) - Character'Pos ('1')) * 8 +
              File_Index (Ep (Ep'First));
         end if;
      end;

      -- Halfmove and fullmove clocks (best effort).
      declare
         Half : constant String := Field (Text, 5);
         Full : constant String := Field (Text, 6);
      begin
         if Half'Length > 0 then
            begin
               Pos.Halfmove := Natural'Value (Half);
            exception
               when Constraint_Error => null;
            end;
         end if;
         if Full'Length > 0 then
            begin
               Pos.Fullmove := Positive'Value (Full);
            exception
               when Constraint_Error => null;
            end;
         end if;
      end;

      -- Validate the position: exactly one king per side and the side that
      -- does not have the move must not be left in check. This rejects
      -- illegal FENs (e.g. a capturable king) that would otherwise crash the
      -- search when it tries to locate a missing king.
      declare
         White_Kings : constant Natural :=
           Popcount (Pos.Pieces (Make (White, King)));
         Black_Kings : constant Natural :=
           Popcount (Pos.Pieces (Make (Black, King)));
      begin
         if White_Kings /= 1 or else Black_Kings /= 1 then
            raise Constraint_Error with "FEN must have exactly one king per side";
         end if;
      end;

      if King_In_Check (Pos, Opposite (Pos.Side)) then
         raise Constraint_Error with
           "FEN leaves the side not to move in check";
      end if;

      Position := Pos;
      Position.Key := Hash.Compute (Position);
   end Load;

end BBChess.Fen;
