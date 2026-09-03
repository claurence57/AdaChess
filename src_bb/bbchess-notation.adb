--
--  AdaChess-BB : move notation (body)
--

with BBChess.Movegen;
use BBChess.Movegen;

package body BBChess.Notation is

   function File_Char (F : in Natural) return Character is
     (Character'Val (Character'Pos ('a') + F));

   function Rank_Char (R : in Natural) return Character is
     (Character'Val (Character'Pos ('1') + R));

   function Square_Char (Square : in Square_Type) return String is
     (File_Char (File_Of (Square)) & Rank_Char (Rank_Of (Square)));

   function Promo_Char (Move : in Move_Type) return Character is
   begin
      case Kind (Move.Promotion) is
         when Queen  => return 'q';
         when Rook   => return 'r';
         when Bishop => return 'b';
         when Knight => return 'n';
         when others => return '?';
      end case;
   end Promo_Char;

   function To_String (Move : in Move_Type) return String is
      Base : constant String := Square_Char (Move.From) & Square_Char (Move.To);
   begin
      if Move.Flag = Promotion then
         return Base & Promo_Char (Move);
      end if;
      return Base;
   end To_String;

   function From_String (Position : in Position_Type; Text : in String)
     return Move_Type is
      Moves : Move_List;
      Count : Natural;
   begin
      if Text'Length < 4 then
         return Empty_Move;
      end if;

      Generate_Legal_Moves (Position, Moves, Count);

      for I in 1 .. Count loop
         declare
            M : Move_Type renames Moves (I);
         begin
            if To_String (M) = Text then
               return M;
            end if;
         end;
      end loop;
      return Empty_Move;
   end From_String;

end BBChess.Notation;
