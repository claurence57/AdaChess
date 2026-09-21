--
--  AdaChess-BB : bounded text handling (body)
--

with Ada.Characters.Handling;

package body BBChess.Text is

   use Ada.Characters.Handling;

   procedure Copy_Bounded (Source    : in String;
                           Dest      : out String;
                           Dest_Last : out Natural) is
      N : Natural := 0;
   begin
      for C of Source loop
         exit when N = Dest'Length;
         N := N + 1;
         Dest (Dest'First + N - 1) := C;
      end loop;
      Dest_Last := N;
   end Copy_Bounded;

   procedure Append_Bounded (Dest      : in out String;
                             Last      : in out Natural;
                             Source    : in String;
                             Truncated : out Boolean) is
   begin
      Truncated := False;
      for C of Source loop
         if Last = Dest'Length then
            Truncated := True;
            exit;
         end if;
         Last := Last + 1;
         Dest (Dest'First + Last - 1) := C;
      end loop;
   end Append_Bounded;

   procedure Split_Command (Line      : in String;
                            Command   : out String;
                            Cmd_Last  : out Natural;
                            Parameter : out String;
                            Par_Last  : out Natural) is
   begin
      Copy_Bounded (First_Word (Line), Command, Cmd_Last);
      Copy_Bounded (Rest_Of (Line), Parameter, Par_Last);
   end Split_Command;

   function First_Word (S : in String) return String is
      I : Natural := S'First;
   begin
      while I <= S'Last and then S (I) /= ' ' and then S (I) /= ASCII.HT loop
         I := I + 1;
      end loop;
      return To_Lower (S (S'First .. I - 1));
   end First_Word;

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

   function Thread_Count (Argument : in String; Default : in Natural)
     return Natural
   is
      Dig : String (1 .. Argument'Length);
      Last   : Natural := 0;
   begin
      if Argument'Length > 2
        and then Argument (Argument'First .. Argument'First + 1) = "-T"
      then
         Dig (1 .. Argument'Length - 2) :=
           Argument (Argument'First + 2 .. Argument'Last);
         Last := Argument'Length - 2;
      elsif Argument'Length > 8
        and then Argument (Argument'First .. Argument'First + 7) = "--thread"
        and then Argument (Argument'First + 8) = '='
      then
         Dig (1 .. Argument'Length - 9) :=
           Argument (Argument'First + 9 .. Argument'Last);
         Last := Argument'Length - 9;
      else
         return Default;
      end if;

      for I in 1 .. Last loop
         if Dig (I) not in '0' .. '9' then
            return Default;
         end if;
      end loop;

      return Natural'Value (Dig (1 .. Last));
   exception
      when Constraint_Error =>
         return Default;
   end Thread_Count;

end BBChess.Text;
