--
--  AdaChess-BB - main entry point.
--
--  * With "--selftest": run the internal test-suite.
--  * Otherwise: an XBoard/Winboard chess engine (protocol subset: xboard,
--    protover, new, setboard, force, white/black, go, level, time, otim,
--    st, sd, usermove, ping, quit). The engine plays via iterative
--    deepening search, replying "move <coord>".
--
--  Time management follows the XBoard clock commands: "level" gives the
--  time control (increment, base) and "time"/"otim" give the clocks. The
--  GUI sends an up-to-date "time" just before the opponent's move, so the
--  engine thinks as soon as the opponent's move has been applied (or when
--  a "go" / "?" prompt arrives) and always searches with a fresh view of
--  its remaining time. The search itself is interruptible (see
--  BBChess.Search), which bounds the worst-case duration of a move.
--

with Ada.Text_IO;
with Ada.Command_Line;
with Ada.Characters.Handling;
with Ada.IO_Exceptions;

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

   -- N-th space separated token of S ("" when there is none).
   function Token (Source : in String; N : in Positive) return String is
      I      : Natural := Source'First;
      Tokens : Natural := 0;
   begin
      while I <= Source'Last loop
         while I <= Source'Last and then Source (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > Source'Last;
         Tokens := Tokens + 1;
         if Tokens = N then
            declare
               Start : constant Natural := I;
            begin
               while I <= Source'Last and then Source (I) /= ' ' loop
                  I := I + 1;
               end loop;
               return Source (Start .. I - 1);
            end;
         end if;
         while I <= Source'Last and then Source (I) /= ' ' loop
            I := I + 1;
         end loop;
      end loop;
      return "";
   end Token;

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
   Pos         : Position_Type := Start_Position;
   Engine_Side : Color_Type := Black;
   Force       : Boolean := True;
   Protocol    : Boolean := False;

   -- Clock state, driven by the XBoard "st", "level" and "time" commands.
   Fixed_Time     : Boolean := False;  -- "st <s>": think exactly that long
   Move_Time      : Duration := 1.0;   -- fixed budget, or fallback w/o clock
   Clock_Left     : Duration := 0.0;   -- own remaining time ("time", seconds)
   Time_Increment : Duration := 0.0;   -- per-move increment ("level", seconds)
   Max_Depth      : Natural := 64;

   Current_Command : String (1 .. 64);
   Cmd_Last        : Natural;
   Parameter       : String (1 .. 256);
   Par_Last        : Natural;

   -- Time to spend on the next move. When a clock is known, allocate a
   -- fraction of the remaining time (plus part of the increment), bounded
   -- by a hard cap and by the actual time still on the clock, so a burst
   -- of long moves can never eat the whole remaining budget.
   function Time_For_Next_Move return Duration is
      Alloc : Duration;
   begin
      if Fixed_Time then
         return Move_Time;
      end if;
      if Clock_Left <= 0.0 then
         return Move_Time;
      end if;

      Alloc := Clock_Left / 30.0 + 0.75 * Time_Increment;
      if Alloc > 2.0 then
         Alloc := 2.0;
      end if;
      if Alloc > Clock_Left - 0.05 then
         Alloc := Clock_Left - 0.05;
      end if;
      if Alloc < 0.01 then
         Alloc := 0.01;
      end if;
      return Alloc;
   end Time_For_Next_Move;

   -- Search and play when it is the engine's turn. Called after the
   -- opponent's move has been applied and from the "go" / "?" prompts, so
   -- that the search always starts with an up-to-date view of the clock.
   procedure Play_If_My_Turn is
   begin
      if Protocol and then not Force and then Pos.Side = Engine_Side then
         declare
            M    : constant Move_Type :=
              Best_Move (Pos, Max_Depth, Time_For_Next_Move);
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
   end Play_If_My_Turn;

begin
   -- Self test mode.
   if Ada.Command_Line.Argument_Count > 0
     and then Ada.Command_Line.Argument (1) = "--selftest"
   then
      BBChess.Self_Tests.Run;
      return;
   end if;

   Main_Loop : loop
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
             Fixed_Time := False;
             Move_Time := 1.0;
             Clock_Left := 0.0;
             Time_Increment := 0.0;
             Max_Depth := 64;
             Reset_Search;

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
            Play_If_My_Turn;
         elsif Cmd = "level" then
            declare
               Base_Token : constant String := Token (Par, 2);
               Inc_Token  : constant String := Token (Par, 3);
               Has_Colon  : Boolean := False;
            begin
               begin
                  if Inc_Token'Length > 0 then
                     Time_Increment := Duration'Value (Inc_Token);
                  else
                     Time_Increment := 0.0;
                  end if;
               exception
                  when Constraint_Error =>
                     Time_Increment := 0.0;
               end;

               -- A plain "level M base" uses whole minutes as the base.
               -- An "MM:SS" base (used by cutechess) means the real clock
               -- will be provided later by the "time" command.
               for I in Base_Token'Range loop
                  if Base_Token (I) = ':' then
                     Has_Colon := True;
                     exit;
                  end if;
               end loop;
               if not Has_Colon then
                  begin
                     Clock_Left := Duration (Natural'Value (Base_Token) * 60);
                  exception
                     when Constraint_Error =>
                        Clock_Left := 0.0;
                  end;
               end if;
            end;

         elsif Cmd = "time" then
            begin
               Clock_Left := Duration'Value (Par) / 100.0;
            exception
               when Constraint_Error => null;
            end;

         elsif Cmd = "otim" then
            -- Opponent clock: not needed for the time management above.
            null;

         elsif Cmd = "st" then
            begin
               Move_Time := Duration'Value (Par);
               Fixed_Time := True;
            exception
               when Constraint_Error => null;
            end;

         elsif Cmd = "sd" then
            begin
               Max_Depth := Natural'Value (Par);
            exception
               when Constraint_Error => null;
            end;

         elsif Cmd = "ping" then
            if Par'Length > 0 then
               Ada.Text_IO.Put_Line ("pong " & Par);
            else
               Ada.Text_IO.Put_Line ("pong");
            end if;
            Ada.Text_IO.Flush;

         elsif Cmd = "usermove" or else Cmd = "move" then
            declare
               M    : constant Move_Type := From_String (Pos, Par);
               Undo : Undo_Info;
            begin
               if M /= Empty_Move then
                  Make_Move (Pos, M, Undo);
                  -- The GUI has played its move: it is now our turn (the
                  -- clock was sent just before the move). Think right away.
                  Play_If_My_Turn;
               end if;
            end;

         elsif Cmd = "?" then
            -- "?" is the XBoard prompt asking the engine to move now.
            Play_If_My_Turn;

         elsif Cmd = "accepted" or else Cmd = "rejected" then
            null;

         elsif Cmd = "post" or else Cmd = "nopost"
           or else Cmd = "easy" or else Cmd = "hard"
           or else Cmd = "hint"
         then
            null;

         elsif Cmd = "quit" or else Cmd = "exit" then
            exit Main_Loop;

         else
            -- Try to interpret the line as a raw coordinate move (console
            -- use and cutechess, which sends the opponent move bare).
            declare
               M    : constant Move_Type :=
                 From_String (Pos, Trim_Both (Input_Line (1 .. Last)));
               Undo : Undo_Info;
            begin
               if M /= Empty_Move then
                  Make_Move (Pos, M, Undo);
                  Play_If_My_Turn;
               end if;
            end;
         end if;
      end;

      <<Continue_Loop>>
      null;
   end loop Main_Loop;

   Ada.Text_IO.Put_Line ("Thanks for playing with AdaChess-BB!");
exception
   -- A clean close of the input (e.g. the GUI quitting) must not abort.
   when Ada.IO_Exceptions.End_Error =>
      null;
end AdaChess_BB;
