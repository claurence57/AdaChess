--
--  AdaChess-BB : Polyglot opening book support
--
--  Computes Polyglot Zobrist keys and probes standard Polyglot .bin opening
--  books (16-byte entries, big-endian, sorted by key).
--

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Moves;
use BBChess.Moves;

package BBChess.Polyglot is

   function Polyglot_Key (Position : in Position_Type) return Bitboard;
   -- Polyglot Zobrist hash of Position, compatible with .bin book entries.

   procedure Open_Book (File_Name : in String; Ok : out Boolean);
   -- Load a Polyglot .bin book into memory. Ok is False (and any previously
   -- loaded book is released) when the file cannot be read.

   procedure Close_Book;
   -- Release the in-memory book.

   function Book_Loaded return Boolean;
   -- True when a book is currently loaded.

   function Probe (Position : in Position_Type; Move : out Move_Type)
     return Boolean;
   -- Pick a weighted random book move for Position. Returns False when the
   -- position is out of book or the entry is not legal (Move = Empty_Move).

end BBChess.Polyglot;
