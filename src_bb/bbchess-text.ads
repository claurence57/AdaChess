--
--  AdaChess-BB : bounded text handling (spec)
--
--  Small helpers shared by the command loop and its self tests. The release
--  build is compiled with -gnatp (run-time checks off), so every copy here is
--  bounded explicitly and can never write past the destination buffer. They
--  also avoid relying on Constraint_Error, which would be unchecked away.
--

package BBChess.Text is

   procedure Copy_Bounded (Source    : in String;
                           Dest      : out String;
                           Dest_Last : out Natural);
   -- Copy at most Dest'Length characters of Source into Dest and report how
   -- many were copied. Never raises, even when Source is longer than Dest.

   procedure Append_Bounded (Dest      : in out String;
                             Last      : in out Natural;
                             Source    : in String;
                             Truncated : out Boolean);
   -- Append Source to Dest, whose valid prefix is Dest (Dest'First .. Last)
   -- (Last is the number of characters already there). Characters that do not
   -- fit are dropped and Truncated is set. Never raises.

   procedure Split_Command (Line      : in String;
                            Command   : out String;
                            Cmd_Last  : out Natural;
                            Parameter : out String;
                            Par_Last  : out Natural);
   -- Split an already trimmed protocol line into its first word (lower-cased)
   -- and the rest of the line, copied with an explicit bound into Command and
   -- Parameter. A word longer than Command is truncated instead of
   -- overwriting neighbouring state (the release build has checks disabled).

   function First_Word (S : in String) return String;
   -- First whitespace separated word, lower-cased ("" when S is blank).

   function Rest_Of (S : in String) return String;
   -- Text after the first separator, leading blanks trimmed.

   function Token (Source : in String; N : in Positive) return String;
   -- N-th space separated token of Source ("" when there is none).

   function Trim_Both (S : in String) return String;
   -- Trim spaces/tabs at both ends.

   function Thread_Count (Argument : in String; Default : in Natural)
     return Natural;
   -- Thread count parsed from a single command-line argument: "-TN" or
   -- "--thread=N". Returns Default (0 means "no match") when Argument is
   -- neither form or the value is malformed. The two-argument form
   -- ("--threads N") is resolved by the caller.

end BBChess.Text;
