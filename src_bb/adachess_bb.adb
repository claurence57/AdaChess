--
--  AdaChess-BB - main entry point.
--
--  * With "--selftest": run the internal test-suite.
--  * Otherwise: an XBoard/Winboard chess engine (protocol subset: xboard,
--    protover, new, setboard, force, white/black, go, ping, st, sd,
--    usermove, quit). The engine plays via iterative deepening search,
--    replying "move <coord>".
--

with Ada.Text_IO;
with Ada.Command_Line;
with Ada.Characters.Handling;

use Ada.Characters.Handling;

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Movegen;
use BBChess.Movegen;

with BBChess.Fen;
use BBChess.Fen;

with BBChess.Search;
use BBChess.Search;

with BBChess.Notation;
use BBChess.Notation;

with BBChess.Self_Tests;

procedure AdaChess_BB is

   Input_Line : String (1 .. 256);
   Last       : Natural;

   ---------------
   -- Text utils --
   ---------------

   -- First whitespace separated word, lower-cased.
   function First_Word (S : in String) return String is
      I : Natural := S'First;
   begin
      while I <= S'Last and then S (I) /= ' ' and then S (I) /= ASCII.HT loop
         I := I + 1;
      end loop;
      return To_Lower (S (S'First .. I - 1));
   end First_Word;

   -- Text after the first separator, trimmed.
   function Rest_Of (S : in String) return String is
      I : Natural := S'First;
   begin
      while I <= S'Last and then S (I) /= ' ' and then S (I) /= ASCII.HT loop
         I := I + 1;
      end loop;
      while I <= S'Last and then S (I) in ' ' | ASCII.HT loop
         I := I + 1;
      end loop;
      return S (I .. S'Last);
   end Rest_Of;

   procedure Read_Line is
   begin
      Ada.Text_IO.Get_Line (Input_Line, Last);
   end Read_Line;

   -- Trim spaces/tabs at both ends.
   function Trim_Both (S : in String) return String is
      Lo : Natural := S'First;
      Hi : Natural := S'Last;
   begin
      while Lo <= Hi and then S (Lo) in ' ' | ASCII.HT loop
         Lo := Lo + 1;
      end loop;
      while Hi >= Lo and then S (Hi) in ' ' | ASCII.HT loop
         Hi := Hi - 1;
      end loop;
      if Lo > Hi then
         return "";
      end if;
      return S (Lo .. Hi);
   end Trim_Both;

   -- Engine state.
   Pos        : Position_Type := Start_Position;
   Engine_Side : Color_Type := Black;
   Force      : Boolean := True;
   Protocol   : Boolean := False;
   Move_Time  : Duration := 1.0;
   Max_Depth  : Natural := 64;

   Current_Command : String (1 .. 64);
   Cmd_Last        : Natural;
   Parameter       : String (1 .. 256);
   Par_Last        : Natural;

begin
   -- Self test mode.
   if Ada.Command_Line.Argument_Count > 0
     and then Ada.Command_Line.Argument (1) = "--selftest"
   then
      BBChess.Self_Tests.Run;
      return;
   end if;

   Main_Loop : loop
      -- The engine moves when it is its turn and not in force mode.
      if Protocol and then not Force and then Pos.Side = Engine_Side then
         declare
            M    : constant Move_Type :=
              Best_Move (Pos, Max_Depth, Move_Time);
            Undo : Undo_Info;
         begin
            if M /= Empty_Move then
               Ada.Text_IO.Put ("move ");
               Ada.Text_IO.Put (To_String (M));
               Ada.Text_IO.New_Line;
               Ada.Text_IO.Flush;
               Make_Move (Pos, M, Undo);
            end if;
         end;
      end if;

      Read_Line;

      -- Normalize the current input.
      declare
         Trimmed : constant String := Trim_Both (Input_Line (1 .. Last));
      begin
         if Trimmed'Length = 0 then
            goto Continue_Loop;
         end if;

         declare
            Word : constant String := First_Word (Trimmed);
            Rest : constant String := Rest_Of (Trimmed);
         begin
            Current_Command (1 .. Word'Length) := Word;
            Cmd_Last := Word'Length;
            Parameter (1 .. Rest'Length) := Rest;
            Par_Last := Rest'Length;
         end;
      end;

      declare
         Cmd : constant String := Current_Command (1 .. Cmd_Last);
         Par : constant String := Parameter (1 .. Par_Last);
      begin
         if Cmd = "xboard" then
            Protocol := True;

         elsif Cmd = "protover" then
            Ada.Text_IO.Put_Line ("feature myname=""AdaChess-BB""");
            Ada.Text_IO.Put_Line ("feature setboard=1");
            Ada.Text_IO.Put_Line ("feature ping=1");
            Ada.Text_IO.Put_Line ("feature memory=1");
            Ada.Text_IO.Put_Line ("feature done=1");
            Ada.Text_IO.Flush;

         elsif Cmd = "new" then
            Pos := Start_Position;
            Engine_Side := Black;
            Force := False;
            Move_Time := 1.0;
            Max_Depth := 64;

         elsif Cmd = "setboard" then
            begin
               Load (Pos, Par);
               Force := True;
            exception
               when Constraint_Error =>
                  Ada.Text_IO.Put_Line ("Error (bad FEN): " & Par);
            end;

         elsif Cmd = "force" then
            Force := True;

         elsif Cmd = "white" then
            Engine_Side := White;

         elsif Cmd = "black" then
            Engine_Side := Black;

         elsif Cmd = "go" then
            Force := False;
            Engine_Side := Pos.Side;

         elsif Cmd = "ping" then
            if Par'Length > 0 then
               Ada.Text_IO.Put_Line ("pong " & Par);
            else
               Ada.Text_IO.Put_Line ("pong");
            end if;
            Ada.Text_IO.Flush;

         elsif Cmd = "st" then
            begin
               Move_Time := Duration'Value (Par);
            exception
               when Constraint_Error => null;
            end;

         elsif Cmd = "sd" then
            begin
               Max_Depth := Natural'Value (Par);
            exception
               when Constraint_Error => null;
            end;

         elsif Cmd = "usermove" or else Cmd = "move" then
            declare
               M    : constant Move_Type := From_String (Pos, Par);
               Undo : Undo_Info;
            begin
               if M /= Empty_Move then
                  Make_Move (Pos, M, Undo);
               end if;
            end;

         elsif Cmd = "quit" or else Cmd = "exit" then
            exit Main_Loop;

         else
            -- Try to interpret the line as a raw coordinate move (console use).
            declare
               M    : constant Move_Type :=
                 From_String (Pos, Trim_Both (Input_Line (1 .. Last)));
               Undo : Undo_Info;
            begin
               if M /= Empty_Move then
                  Make_Move (Pos, M, Undo);
               end if;
            end;
         end if;
      end;

      <<Continue_Loop>>
      null;
   end loop Main_Loop;

   Ada.Text_IO.Put_Line ("Thanks for playing with AdaChess-BB!");
end AdaChess_BB;
