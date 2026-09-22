--
--  AdaChess-BB : absolute pin detection (body)
--

with BBChess.Attacks;
use BBChess.Attacks;

package body BBChess.Pin_Mask is

   function Pinned (Occ               : in Bitboard;
                    King_Sq           : in Square_Type;
                    Own               : in Bitboard;
                    Enemy_Rook_Queen  : in Bitboard;
                    Enemy_Bishop_Queen : in Bitboard) return Bitboard
   is
      Pinners : Bitboard :=
        (Rook_Ray (King_Sq) and Enemy_Rook_Queen)
        or (Bishop_Ray (King_Sq) and Enemy_Bishop_Queen);
      Result  : Bitboard := 0;
   begin
      while Pinners /= 0 loop
         declare
            P        : constant Square_Type := Lowest_Bit (Pinners);
            Blockers : Bitboard;
         begin
            Blockers := Between (King_Sq, P) and Occ;
            if Blockers /= 0
              and then (Blockers and (Blockers - 1)) = 0
              and then (Blockers and Own) /= 0
            then
               Result := Result or Blockers;
            end if;
         end;
         Pinners := Pinners and (Pinners - 1);
      end loop;
      return Result;
   end Pinned;

end BBChess.Pin_Mask;
