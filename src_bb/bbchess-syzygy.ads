--
--  AdaChess-BB : Syzygy endgame tablebases (via the Fathom C library)
--
--  Thin Ada binding over Fathom (vendored in src_bb/fathom). WDL probing is
--  used in the search; the probe is only valid without castling rights and
--  with a zero halfmove clock (Fathom rejects such positions).
--

with Interfaces.C;

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

package BBChess.Syzygy is

   -- Scores returned by the search for a tablebase win/loss (below mate,
   -- above any normal evaluation), adjusted by the ply for distance.
   TB_Win  : constant Integer := 20_000;
   TB_Draw : constant Integer := 0;
   TB_Loss : constant Integer := -20_000;

   -- Fathom WDL values.
   TB_Result_Loss         : constant Interfaces.C.unsigned := 0;
   TB_Result_Blessed_Loss : constant Interfaces.C.unsigned := 1;
   TB_Result_Draw         : constant Interfaces.C.unsigned := 2;
   TB_Result_Cursed_Win   : constant Interfaces.C.unsigned := 3;
   TB_Result_Win          : constant Interfaces.C.unsigned := 4;
   TB_Result_Failed       : constant Interfaces.C.unsigned := 16#FFFF_FFFF#;

   procedure Init (Path : in String; Ok : out Boolean);
   -- Initialise the tablebases from a directory (or list of directories)
   -- separated by the platform path separator. Ok is False when no usable
   -- tablebase is found (Largest is then 0).

   procedure Free;
   -- Release the tablebases.

   function Largest return Natural;
   -- Largest number of pieces available in the loaded tablebases (0 = none).

   function Enabled return Boolean;
   -- True when at least one tablebase is loaded.

   function Probe_WDL (Position : in Position_Type) return Integer;
   -- Fathom WDL value (0..4) from the side to move's point of view, or -1 when
   -- the probe fails (no tablebase, castling rights, or a non-zero halfmove
   -- clock).

end BBChess.Syzygy;
