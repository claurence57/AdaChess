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
with Ada.Environment_Variables;
with Ada.IO_Exceptions;
with Ada.Real_Time;
with Ada.Strings.Unbounded;

use Ada.Characters.Handling;
use Ada.Real_Time;

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Hash;

with BBChess.Movegen;
use BBChess.Movegen;

with BBChess.Fen;
use BBChess.Fen;

with BBChess.Search;
use BBChess.Search;

with BBChess.Notation;
use BBChess.Notation;

with BBChess.Eval;
use BBChess.Eval;

with BBChess.Self_Tests;

with BBChess.Polyglot;

with BBChess.Syzygy;

procedure AdaChess_BB is

   Input_Line : String (1 .. 8192);
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
   UCI_Mode    : Boolean := False;

   -- Game history (Zobrist keys of every position played, oldest first) for
   -- the threefold-repetition detection in the search. Keys are recorded
   -- after every real move applied to Pos (both sides) and at "new"/FEN.
   Game_Keys : BBChess.Search.Game_Key_Array := (others => 0);
   Game_N    : Natural := 0;

   procedure Push_Game_Key (Key : in Bitboard) is
   begin
      if Game_N = BBChess.Search.Max_Game_Keys then
         -- Drop the oldest position: the game is longer than the buffer.
         for I in 1 .. Game_N - 1 loop
            Game_Keys (I - 1) := Game_Keys (I);
         end loop;
         Game_N := Game_N - 1;
      end if;
      Game_Keys (Game_N) := Key;
      Game_N := Game_N + 1;
   end Push_Game_Key;

   -- Record the current position (freshly computed Zobrist key) as a new
   -- entry of the game history, unless it is already the last one.
   procedure Record_Current_Key is
      K : constant Bitboard := BBChess.Hash.Compute (Pos);
   begin
      if Game_N = 0 or else Game_Keys (Game_N - 1) /= K then
         Push_Game_Key (K);
      end if;
   end Record_Current_Key;

   -- Hand the game history to the search before it starts to think.
   procedure Sync_Game_History is
   begin
      BBChess.Search.Set_Game_History (Game_Keys, Game_N);
   end Sync_Game_History;

   -- Start a fresh game history and record the given position.
   procedure Reset_Game_History is
   begin
      Game_N := 0;
      Record_Current_Key;
   end Reset_Game_History;

   -- Clock state, driven by the XBoard "st", "level" and "time" commands.
   Fixed_Time     : Boolean := False;  -- "st <s>": think exactly that long
   Move_Time      : Duration := 1.0;   -- fixed budget, or fallback w/o clock
   Clock_Left     : Duration := 0.0;   -- own remaining time ("time", seconds)
   Time_Increment : Duration := 0.0;   -- per-move increment ("level", seconds)
   Max_Depth      : Natural := 64;

   Current_Command : String (1 .. 64);
   Cmd_Last        : Natural;
   Parameter       : String (1 .. 8192);
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

   -------------------
   -- Opening book --
   -------------------

   Book_Max_Ply : constant := 16;   -- stop using the book after this ply
   Own_Book     : Boolean := True;  -- UCI "OwnBook" (default on)

   -- Probe the book for the engine's side. Returns False when the book is
   -- disabled, empty, past the opening phase, or the position is not in it.
   function Try_Book (Move : out Move_Type) return Boolean is
      M : Move_Type;
   begin
      Move := Empty_Move;
      if not Own_Book or else not BBChess.Polyglot.Book_Loaded then
         return False;
      end if;
      if Game_N = 0 or else Game_N - 1 > Book_Max_Ply then
         return False;
      end if;
      if BBChess.Polyglot.Probe (Pos, M) and then M /= Empty_Move then
         Move := M;
         return True;
      end if;
      return False;
   end Try_Book;

   -- Load the book from conventional locations (CWD, executable directory
   -- and its parent, home). The first readable file wins.
   procedure Load_Default_Book is
      use Ada.Strings.Unbounded;
      Exe : constant String := Ada.Command_Line.Command_Name;

      function Exe_Dir return String is
         Slash : Natural := 0;
      begin
         for I in Exe'Range loop
            if Exe (I) = '/' then
               Slash := I;
            end if;
         end loop;
         if Slash = 0 then
            return ".";
         end if;
         return Exe (Exe'First .. Slash - 1);
      end Exe_Dir;

      D    : constant String := Exe_Dir;
      Home : constant String :=
        (if Ada.Environment_Variables.Exists ("HOME")
         then Ada.Environment_Variables.Value ("HOME") else "");
      Candidates : constant array (1 .. 6) of Unbounded_String :=
        (1 => To_Unbounded_String ("books/book.bin"),
         2 => To_Unbounded_String (D & "/books/book.bin"),
         3 => To_Unbounded_String (D & "/../books/book.bin"),
         4 => To_Unbounded_String (Home & "/.adachess/book.bin"),
         5 => To_Unbounded_String ("book.bin"),
         6 => To_Unbounded_String (D & "/book.bin"));
      Ok : Boolean;
   begin
      if BBChess.Polyglot.Book_Loaded then
         return;
      end if;
      for C in Candidates'Range loop
         BBChess.Polyglot.Open_Book (To_String (Candidates (C)), Ok);
         if Ok then
            return;
         end if;
      end loop;
   end Load_Default_Book;

   -- Search and play when it is the engine's turn. Called after the
   -- opponent's move has been applied and from the "go" / "?" prompts, so
   -- that the search always starts with an up-to-date view of the clock.
   procedure Play_If_My_Turn is
   begin
      if Protocol and then not Force and then Pos.Side = Engine_Side then
         -- Make sure the game history ends with the current position (a
         -- real move may have been played since the last sync).
         Record_Current_Key;

         -- Opening book: play a book move without searching.
         declare
            BM   : Move_Type;
            Undo : Undo_Info;
         begin
            if Try_Book (BM) then
               Ada.Text_IO.Put ("move ");
               Ada.Text_IO.Put (To_String (BM));
               Ada.Text_IO.New_Line;
               Ada.Text_IO.Flush;
               Make_Move (Pos, BM, Undo);
               Record_Current_Key;
               return;
            end if;
         end;

         -- Give the game history to the search before it thinks.
         Sync_Game_History;
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
               Record_Current_Key;
            end if;
         end;
      end if;
   end Play_If_My_Turn;

   ----------------
   -- UCI support --
   ----------------

   function Token_Count (S : in String) return Natural is
      I : Natural := S'First;
      N : Natural := 0;
   begin
      while I <= S'Last loop
         while I <= S'Last and then S (I) = ' ' loop
            I := I + 1;
         end loop;
         exit when I > S'Last;
         N := N + 1;
         while I <= S'Last and then S (I) /= ' ' loop
            I := I + 1;
         end loop;
      end loop;
      return N;
   end Token_Count;

   function Parse_Duration (S : String; Default : Duration) return Duration is
   begin
      if S'Length = 0 then
         return Default;
      end if;
      return Duration'Value (S);
   exception
      when Constraint_Error => return Default;
   end Parse_Duration;

   function Parse_Natural (S : String; Default : Natural) return Natural is
   begin
      if S'Length = 0 then
         return Default;
      end if;
      return Natural'Value (S);
   exception
      when Constraint_Error => return Default;
   end Parse_Natural;

   -- "position startpos moves ..." or "position fen <6 fields> moves ...".
   procedure Apply_UCI_Position (Par : in String) is
      T1 : constant String := Token (Par, 1);
      I  : Natural := 1;
      N  : constant Natural := Token_Count (Par);
      M  : Move_Type;
      U  : Undo_Info;
   begin
      if T1 = "startpos" then
         Pos := Start_Position;
         I := 2;
      elsif T1 = "fen" then
         declare
            Fen : String (1 .. 256);
            L   : Natural := 0;
         begin
            for K in 2 .. 7 loop
               declare
                  Tok : constant String := Token (Par, K);
               begin
                  exit when Tok'Length = 0;
                  if L > 0 then
                     L := L + 1;
                     Fen (L) := ' ';
                  end if;
                  for C of Tok loop
                     L := L + 1;
                     Fen (L) := C;
                  end loop;
               end;
            end loop;
            begin
               Load (Pos, Fen (1 .. L));
            exception
               when Constraint_Error =>
                  Ada.Text_IO.Put_Line ("info string bad FEN");
            end;
         end;
         I := 8;
      else
         return;
      end if;

      Reset_Game_History;
      while I <= N loop
         exit when Token (Par, I) = "moves";
         I := I + 1;
      end loop;
      I := I + 1;
      while I <= N loop
         M := From_String (Pos, Token (Par, I));
         if M = Empty_Move then
            Ada.Text_IO.Put_Line
              ("info string unknown move " & Token (Par, I));
         else
            Make_Move (Pos, M, U);
            Record_Current_Key;
         end if;
         I := I + 1;
      end loop;
   end Apply_UCI_Position;

   -- "go wtime .. btime .. winc .. binc .. movestogo .. depth .. movetime ..".
   procedure Handle_UCI_Go (Par : in String) is
      N : constant Natural := Token_Count (Par);
      I : Natural := 1;
   begin
      Fixed_Time := False;
      Clock_Left := 0.0;
      Time_Increment := 0.0;
      Max_Depth := 64;

      while I <= N loop
         declare
            Name : constant String := Token (Par, I);
            Next : constant String :=
              (if I < N then Token (Par, I + 1) else "");
         begin
            if Name = "wtime" and then Pos.Side = White then
               Clock_Left := Parse_Duration (Next, 0.0) / 1000.0;
            elsif Name = "btime" and then Pos.Side = Black then
               Clock_Left := Parse_Duration (Next, 0.0) / 1000.0;
            elsif Name = "winc" and then Pos.Side = White then
               Time_Increment := Parse_Duration (Next, 0.0) / 1000.0;
            elsif Name = "binc" and then Pos.Side = Black then
               Time_Increment := Parse_Duration (Next, 0.0) / 1000.0;
            elsif Name = "movetime" then
               Fixed_Time := True;
               Move_Time := Parse_Duration (Next, 1.0) / 1000.0;
            elsif Name = "depth" then
               Max_Depth := Parse_Natural (Next, 64);
            end if;
         end;
         I := I + 1;
      end loop;

      -- Opening book.
      declare
         BM : Move_Type;
      begin
         if Try_Book (BM) then
            Ada.Text_IO.Put_Line ("bestmove " & To_String (BM));
            Ada.Text_IO.Flush;
            return;
         end if;
      end;

      declare
         M : constant Move_Type :=
           Best_Move (Pos, Max_Depth, Time_For_Next_Move);
      begin
         if M = Empty_Move then
            Ada.Text_IO.Put_Line ("bestmove 0000");
         else
            Ada.Text_IO.Put_Line ("bestmove " & To_String (M));
         end if;
         Ada.Text_IO.Flush;
      end;
   end Handle_UCI_Go;


   -- Fixed set of positions exercising the evaluation and the search. The
   -- benchmark searches every one at a fixed depth and reports the total
   -- node count and nodes/second, so that each optimization can be measured
   -- against the same workload.
   procedure Run_Bench (Depth : in Natural) is
      use Ada.Strings.Unbounded;
      Fens : constant array (Positive range <>) of Unbounded_String :=
        (1 => To_Unbounded_String ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"),
         2 => To_Unbounded_String ("r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4"),
         3 => To_Unbounded_String ("rnbqkbnr/pp1ppppp/8/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"),
         4 => To_Unbounded_String ("r1bq1rk1/pp3ppp/2n1pn2/2pp4/3P1B2/2NBPN2/PPPQ1PPP/2KR3R w - - 0 1"),
         5 => To_Unbounded_String ("r4rk1/pppbqppp/2nbp3/3P4/4B3/5N2/PPP2PPP/R1BQR1K1 b - - 0 11"),
         6 => To_Unbounded_String ("r4r2/pppbnppk/3b4/3p4/8/5N2/PPP2PPP/R1BQ2K1 w - - 0 14"),
         7 => To_Unbounded_String ("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"),
         8 => To_Unbounded_String ("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"));
      Total_Nodes : Natural := 0;
      Pos         : Position_Type;
      T0          : constant Time := Clock;
      Elapsed     : Duration;
      Nps         : Long_Float;
   begin
      Reset_Search;
      Reset_Nodes;
      for I in Fens'Range loop
         Load (Pos, To_String (Fens (I)));
         declare
            M : constant Move_Type := Best_Move (Pos, Depth);
         begin
            null;
            pragma Unreferenced (M);
         end;
      end loop;
      Elapsed := To_Duration (Clock - T0);
      Total_Nodes := Nodes_Searched;

      if Elapsed > 0.0 then
         Nps := Long_Float (Total_Nodes) / Long_Float (Elapsed);
      else
         Nps := 0.0;
      end if;

      Ada.Text_IO.Put_Line
        ("bench depth" & Natural'Image (Depth)
         & ": " & Natural'Image (Fens'Length) & " positions, "
         & Natural'Image (Total_Nodes) & " nodes, "
         & Duration'Image (Elapsed) & " s, "
         & Long_Float'Image (Nps / 1000.0) & " knps");
   end Run_Bench;

   -------------------------
   -- Eval dump (tuning) --
   -------------------------

   -- Read one position per line ("FEN" or "FEN;result") and print the
   -- White-positive static evaluation, one integer per line. Used by the
   -- automatic tuner.
   procedure Run_Eval_Fens (File_Name : in String) is
      F    : Ada.Text_IO.File_Type;
      Line : String (1 .. 512);
      Last : Natural;
      Pos  : Position_Type;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, File_Name);
      while not Ada.Text_IO.End_Of_File (F) loop
         Ada.Text_IO.Get_Line (F, Line, Last);
         declare
            S    : constant String := Line (1 .. Last);
            Semi : Natural := 0;
         begin
            for I in S'Range loop
               if S (I) = ';' then
                  Semi := I;
                  exit;
               end if;
            end loop;
            declare
               Fen : constant String :=
                 (if Semi = 0 then S else S (S'First .. Semi - 1));
            begin
               if Fen'Length > 0 then
                  begin
                     Load (Pos, Fen);
                     Ada.Text_IO.Put_Line (Integer'Image (Static (Pos)));
                  exception
                     when Constraint_Error =>
                        Ada.Text_IO.Put_Line ("0");
                  end;
               end if;
            end;
         end;
      end loop;
      Ada.Text_IO.Close (F);
   end Run_Eval_Fens;

begin
   -- Optional evaluation parameter file (applies to every mode).
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      if Ada.Command_Line.Argument (I) = "--params"
        and then I < Ada.Command_Line.Argument_Count
      then
         Load_Params (Ada.Command_Line.Argument (I + 1));
      end if;
   end loop;

   -- Optional opening book file (applies to the playing modes).
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      if Ada.Command_Line.Argument (I) = "--book"
        and then I < Ada.Command_Line.Argument_Count
      then
         declare
            Ok : Boolean;
         begin
            BBChess.Polyglot.Open_Book (Ada.Command_Line.Argument (I + 1), Ok);
         end;
      end if;
   end loop;

   -- Optional Syzygy tablebase directory (playing modes).
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      if Ada.Command_Line.Argument (I) = "--syzygy"
        and then I < Ada.Command_Line.Argument_Count
      then
         declare
            Ok : Boolean;
         begin
            BBChess.Syzygy.Init (Ada.Command_Line.Argument (I + 1), Ok);
         end;
      end if;
   end loop;

   -- Optional number of search threads (Lazy SMP).
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      if Ada.Command_Line.Argument (I) = "--threads"
        and then I < Ada.Command_Line.Argument_Count
      then
         begin
            Set_Threads (Natural'Value (Ada.Command_Line.Argument (I + 1)));
         exception
            when Constraint_Error => Set_Threads (1);
         end;
      end if;
   end loop;

   -- Dump the current evaluation parameters.
   if Ada.Command_Line.Argument_Count >= 1
     and then Ada.Command_Line.Argument (1) = "--dump-params"
   then
      Dump_Params;
      return;
   end if;

   -- Dump the static evaluation of every FEN of a file (tuning dataset).
   if Ada.Command_Line.Argument_Count >= 2
     and then Ada.Command_Line.Argument (1) = "--eval-fens"
   then
      Run_Eval_Fens (Ada.Command_Line.Argument (2));
      return;
   end if;

   -- Self test mode.
   if Ada.Command_Line.Argument_Count > 0
     and then Ada.Command_Line.Argument (1) = "--selftest"
   then
      BBChess.Self_Tests.Run;
      return;
   end if;

   -- Benchmark mode (optional depth as second argument, default 8).
   if Ada.Command_Line.Argument_Count > 0
     and then Ada.Command_Line.Argument (1) = "--bench"
   then
      declare
         D : Natural := 8;
      begin
         if Ada.Command_Line.Argument_Count >= 2 then
            begin
               D := Natural'Value (Ada.Command_Line.Argument (2));
            exception
               when Constraint_Error => D := 8;
            end;
         end if;
         Run_Bench (D);
      end;
      return;
   end if;

   -- Load the opening book (unless --book already did; the special modes
   -- return before this point).
   Load_Default_Book;

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

          elsif Cmd = "uci" then
             UCI_Mode := True;
             Ada.Text_IO.Put_Line ("id name AdaChess-BB 1.0");
             Ada.Text_IO.Put_Line ("id author AdaChess");
             Ada.Text_IO.Put_Line
               ("option name Hash type spin default 64 min 1 max 1024");
             Ada.Text_IO.Put_Line
               ("option name Threads type spin default 1 min 1 max 16");
             Ada.Text_IO.Put_Line
               ("option name OwnBook type check default true");
             Ada.Text_IO.Put_Line
               ("option name BookFile type string default books/book.bin");
             Ada.Text_IO.Put_Line
               ("option name SyzygyPath type string default <empty>");
             Ada.Text_IO.Put_Line ("uciok");
             Ada.Text_IO.Flush;

          elsif Cmd = "isready" and then UCI_Mode then
             Ada.Text_IO.Put_Line ("readyok");
             Ada.Text_IO.Flush;

          elsif Cmd = "ucinewgame" and then UCI_Mode then
             Reset_Search;
             Reset_Game_History;

          elsif Cmd = "position" and then UCI_Mode then
             Apply_UCI_Position (Par);

          elsif Cmd = "go" and then UCI_Mode then
             Handle_UCI_Go (Par);

          elsif UCI_Mode
            and then (Cmd = "stop" or else Cmd = "ponderhit"
                      or else Cmd = "debug" or else Cmd = "register")
          then
             null;

          elsif Cmd = "setoption" and then UCI_Mode then
             if Token (Par, 1) = "name" then
                if Token (Par, 2) = "Clear" and then Token (Par, 3) = "Hash" then
                   Reset_Search;
                elsif Token (Par, 2) = "Threads"
                  and then Token (Par, 3) = "value"
                then
                   Set_Threads (Parse_Natural (Token (Par, 4), 1));
                elsif Token (Par, 2) = "OwnBook"
                  and then Token (Par, 3) = "value"
                then
                   Own_Book := Token (Par, 4) = "true";
                elsif Token (Par, 2) = "BookFile"
                  and then Token (Par, 3) = "value"
                then
                   declare
                      Ok : Boolean;
                   begin
                      BBChess.Polyglot.Open_Book (Token (Par, 4), Ok);
                   end;
                elsif Token (Par, 2) = "SyzygyPath"
                  and then Token (Par, 3) = "value"
                then
                   declare
                      Ok : Boolean;
                   begin
                      BBChess.Syzygy.Init (Token (Par, 4), Ok);
                   end;
                end if;
             end if;

          elsif Cmd = "protover" then
             Ada.Text_IO.Put_Line ("feature myname=""AdaChess-BB 1.0""");
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
             Reset_Game_History;

         elsif Cmd = "setboard" then
            begin
               Load (Pos, Par);
               Force := True;
               Reset_Game_History;
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

         elsif Cmd = "post" then
            Set_Post (True);

         elsif Cmd = "nopost" then
            Set_Post (False);

         elsif Cmd = "accepted" or else Cmd = "rejected" then
            null;

         elsif Cmd = "easy" or else Cmd = "hard"
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
