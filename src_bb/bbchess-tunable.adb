--
--  AdaChess-BB : tunable-parameter plumbing (body)
--

with Ada.Text_IO;
with Ada.IO_Exceptions;

package body BBChess.Tunable is

   procedure Put (Name : in String; Value : in Integer) is
   begin
      Ada.Text_IO.Put_Line (Name & " " & Integer'Image (Value));
   end Put;

   procedure Put (Name : in String; Value : in Float) is
   begin
      Ada.Text_IO.Put_Line (Name & " " & Float'Image (Value));
   end Put;

   procedure Load_File (File_Name : in String) is
      F    : Ada.Text_IO.File_Type;
      Line : String (1 .. 256);
      Last : Natural;
   begin
      Ada.Text_IO.Open (F, Ada.Text_IO.In_File, File_Name);
      while not Ada.Text_IO.End_Of_File (F) loop
         Ada.Text_IO.Get_Line (F, Line, Last);
         declare
            S        : constant String := Line (1 .. Last);
            I        : Natural := S'First;
            Name_End : Natural;
         begin
            while I <= S'Last and then S (I) = ' ' loop
               I := I + 1;
            end loop;
            Name_End := I;
            while Name_End <= S'Last and then S (Name_End) /= ' ' loop
               Name_End := Name_End + 1;
            end loop;
            if Name_End > I then
               declare
                  Name   : constant String := S (I .. Name_End - 1);
                  VStart : Natural := Name_End;
               begin
                  while VStart <= S'Last and then S (VStart) = ' ' loop
                     VStart := VStart + 1;
                  end loop;
                  if VStart <= S'Last then
                     declare
                        V : constant String := S (VStart .. S'Last);
                     begin
                        -- Integer parameters are the common case; a real
                        -- parameter (fractional value) fails Integer'Value
                        -- and is applied by the real setter.
                        begin
                           Set_Integer (Name, Integer'Value (V));
                        exception
                           when Constraint_Error =>
                              begin
                                 Set_Real (Name, Float'Value (V));
                              exception
                                 when Constraint_Error => null;
                              end;
                        end;
                     end;
                  end if;
               end;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (F);
   exception
      when Ada.IO_Exceptions.Name_Error =>
         Ada.Text_IO.Put_Line ("warning: cannot open params file " & File_Name);
   end Load_File;

end BBChess.Tunable;
