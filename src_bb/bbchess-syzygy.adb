--
--  AdaChess-BB : Syzygy endgame tablebases (body)
--

with Interfaces;
with Interfaces.C.Strings;

package body BBChess.Syzygy is

   use type Interfaces.C.unsigned;
   use type Interfaces.C.int;

   function C_Init (Path : Interfaces.C.Strings.chars_ptr)
     return Interfaces.C.int
     with Import, External_Name => "bb_tb_init", Convention => C;

   procedure C_Free
     with Import, External_Name => "bb_tb_free", Convention => C;

   function C_Largest return Interfaces.C.unsigned
     with Import, External_Name => "bb_tb_largest", Convention => C;

   function C_WDL
     (White, Black, Kings, Queens, Rooks, Bishops, Knights, Pawns
        : Interfaces.Unsigned_64;
      Rule50, Castling, Ep : Interfaces.C.unsigned;
      Turn : Interfaces.C.int) return Interfaces.C.unsigned
     with Import, External_Name => "bb_tb_wdl", Convention => C;

   Loaded    : Boolean := False;
   Largest_N : Natural := 0;

   procedure Init (Path : in String; Ok : out Boolean) is
      use Interfaces.C.Strings;
      C_Path : chars_ptr := New_String (Path);
      R      : Interfaces.C.int;
   begin
      R := C_Init (C_Path);
      Free (C_Path);
      Ok := R /= 0;
      if Ok then
         Largest_N := Natural (C_Largest);
      else
         Largest_N := 0;
      end if;
      Loaded := Ok and then Largest_N > 0;
      Ok := Loaded;
   end Init;

   procedure Free is
   begin
      C_Free;
      Loaded := False;
      Largest_N := 0;
   end Free;

   function Largest return Natural is (Largest_N);

   function Enabled return Boolean is (Loaded);

   function Probe_WDL (Position : in Position_Type) return Integer is
      W : Interfaces.C.unsigned;
   begin
      if not Loaded or else Largest_N = 0 then
         return -1;
      end if;
      -- Castling rights make the WDL probe invalid. The halfmove clock is
      -- ignored (the WDL tables assume rule50 = 0; DTZ would be needed to
      -- respect the 50-move rule exactly).
      for C in Color_Type loop
         for S in Castle_Side_Type loop
            if Position.Castle (C, S) then
               return -1;
            end if;
         end loop;
      end loop;

      W := C_WDL
        (White   => Interfaces.Unsigned_64 (Color_Board (Position, White)),
         Black   => Interfaces.Unsigned_64 (Color_Board (Position, Black)),
         Kings   => Interfaces.Unsigned_64
                      (Position.Pieces (White_King)
                       or Position.Pieces (Black_King)),
         Queens  => Interfaces.Unsigned_64
                      (Position.Pieces (White_Queen)
                       or Position.Pieces (Black_Queen)),
         Rooks   => Interfaces.Unsigned_64
                      (Position.Pieces (White_Rook)
                       or Position.Pieces (Black_Rook)),
         Bishops => Interfaces.Unsigned_64
                      (Position.Pieces (White_Bishop)
                       or Position.Pieces (Black_Bishop)),
         Knights => Interfaces.Unsigned_64
                      (Position.Pieces (White_Knight)
                       or Position.Pieces (Black_Knight)),
         Pawns   => Interfaces.Unsigned_64
                      (Position.Pieces (White_Pawn)
                       or Position.Pieces (Black_Pawn)),
         Rule50   => 0,
         Castling => 0,
         Ep       => (if Position.En_Passant = Ep_None then 0
                      else Interfaces.C.unsigned (Position.En_Passant)),
         Turn     => (if Position.Side = White then 1 else 0));
      if W = TB_Result_Failed then
         return -1;
      end if;
      return Integer (W);
   end Probe_WDL;

end BBChess.Syzygy;
