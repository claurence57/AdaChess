--
--  AdaChess-BB : perft (body)
--

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Movegen;
use BBChess.Movegen;

package body BBChess.Perft is

   function Nodes (Position : in out Position_Type; Depth : in Natural)
     return Natural is
      Total : Natural := 0;
   begin
      if Depth = 0 then
         return 1;
      end if;

      declare
         Moves : Move_List;
         Count : Natural;
      begin
         Generate_Legal_Moves (Position, Moves, Count);

         if Depth = 1 then
            return Count;
         end if;

         for I in 1 .. Count loop
            declare
               Undo : Undo_Info;
            begin
               Make_Move (Position, Moves (I), Undo);
               Total := Total + Nodes (Position, Depth - 1);
               Unmake_Move (Position, Moves (I), Undo);
            end;
         end loop;
      end;

      return Total;
   end Nodes;

end BBChess.Perft;
