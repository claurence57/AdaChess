--
--  AdaChess-BB : tunable-parameter plumbing (shared by Eval and Search)
--
--  Both BBChess.Eval (P_* evaluation constants) and BBChess.Search (S_*
--  search constants) expose the same three services to the tuner:
--    * a "--dump-params" serializer printing "NAME value", one per line;
--    * a "--params" file parser reading the same "NAME value" lines;
--    * a name-indexed setter used by that parser.
--  Only the serializer's line format and the parser's token handling are
--  common (the tables, defaults, ranges and setter side effects stay in the
--  two packages), so this unit factors exactly those two pieces.
--

package BBChess.Tunable is

   procedure Put (Name : in String; Value : in Integer);
   -- Print one "--dump-params" line: Name, a single space, then the value.
   -- Integer'Image supplies its own leading blank for non-negative values,
   -- which is exactly the historical two-column layout.

   procedure Put (Name : in String; Value : in Float);
   -- Same, for a real parameter (Float'Image formatting preserved).

   generic
      with procedure Set_Integer (Name : in String; Value : in Integer);
      with procedure Set_Real (Name : in String; Value : in Float);
   procedure Load_File (File_Name : in String);
   -- Read "Name Value" lines and apply each one through the supplied
   -- setters. Integer'Value is tried first; on a Constraint_Error the token
   -- is offered to Set_Real (so "S_LMR_BASE 0.75" reaches the real setter,
   -- while a fractional token for an integer / unknown name is ignored, as
   -- it always was). A file that cannot be opened prints the historical
   -- warning and returns without applying anything.

end BBChess.Tunable;
