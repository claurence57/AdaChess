--
--  AdaChess-BB : self tests (body)
--

with Ada.Text_IO;
with Ada.Real_Time;

use Ada.Real_Time;

with BBChess.Pieces;
use BBChess.Pieces;

with BBChess.Board;
use BBChess.Board;

with BBChess.Attacks;
use BBChess.Attacks;

with BBChess.Moves;
use BBChess.Moves;

with BBChess.Movegen;
use BBChess.Movegen;

with BBChess.Fen;
use BBChess.Fen;

with BBChess.Perft;
use BBChess.Perft;

with BBChess.Eval;
use BBChess.Eval;

with BBChess.Search;
use BBChess.Search;

package body BBChess.Self_Tests is

   procedure Assert (Condition : in Boolean; Message : in String) is
   begin
      if not Condition then
         Ada.Text_IO.Put_Line ("FAILED: " & Message);
         raise Program_Error with Message;
      end if;
   end Assert;

   procedure Run is
      Position : Position_Type;
   begin
      Ada.Text_IO.Put_Line ("AdaChess-BB self tests");
      Ada.Text_IO.New_Line;

      -- Bitboard / square mapping primitives.
      Assert (Bit (0) = 1, "bit 0 must be a1 (lsb)");
      Assert (Bit (63) = Bitboard (2 ** 63), "bit 63 must be h8 (msb)");
      Assert (File_Of (0) = 0 and Rank_Of (0) = 0, "a1 must be file 0 rank 0");
      Assert (File_Of (63) = 7 and Rank_Of (63) = 7, "h8 must be file 7 rank 7");
      Assert (Popcount (Bit (3) or Bit (40)) = 2, "popcount of two bits");

      -- Occupancy helpers.
      for S in 8 .. 15 loop
         Put_Piece (Position, White_Pawn, S);
      end loop;
      for S in 48 .. 55 loop
         Put_Piece (Position, Black_Pawn, S);
      end loop;
      Put_Piece (Position, White_Rook, 0);
      Put_Piece (Position, Black_King, 60);
      Assert (Popcount (Color_Board (Position, White)) = 9, "9 white pieces expected");
      Assert (Popcount (Color_Board (Position, Black)) = 9, "9 black pieces expected");
      Assert (Popcount (Occupancy (Position)) = 18, "18 pieces in total");
      Assert (not Is_Empty (Position, 0), "a1 must be occupied");
      Assert (Is_Empty (Position, 1), "b1 must be empty");

      -- Attack tables.
      Assert (Popcount (Knight_Attacks (0)) = 2, "knight on a1 attacks 2 squares");
      Assert (Popcount (Knight_Attacks (1)) = 3, "knight on b1 attacks 3 squares");
      Assert (Popcount (Knight_Attacks (27)) = 8, "knight on d4 attacks 8 squares");
      Assert (Popcount (King_Attacks (0)) = 3, "king on a1 attacks 3 squares");
      Assert (Popcount (King_Attacks (27)) = 8, "king on d4 attacks 8 squares");
      Assert (Popcount (Pawn_Attacks (White, 8)) = 1, "white pawn on a2 attacks 1");
      Assert (Pawn_Attacks (White, 8) = Bit (17), "white pawn on a2 attacks b3");
      Assert (Pawn_Attacks (Black, 48) = Bit (41), "black pawn on a7 attacks b6");

      Assert (Popcount (Rook_Attacks (0, 0)) = 14, "rook on a1 attacks 14 squares");
      Assert (Popcount (Rook_Attacks (27, 0)) = 14, "rook on d4 attacks 14 squares");
      Assert (Popcount (Bishop_Attacks (0, 0)) = 7, "bishop on a1 attacks 7 squares");
      Assert (Popcount (Bishop_Attacks (27, 0)) = 13, "bishop on d4 attacks 13 squares");
      Assert (Popcount (Queen_Attacks (27, 0)) = 27, "queen on d4 attacks 27 squares");

      Assert (Popcount (Rook_Attacks (0, Bit (16))) = 9,
              "rook a1 blocked on a3 attacks 9 squares");
      Assert ((Rook_Attacks (0, Bit (16)) and Bit (24)) = 0,
              "rook a1 cannot attack beyond a4");

      -- Legal move count at the start position.
      declare
         List  : Move_List;
         Count : Natural;
      begin
         Generate_Legal_Moves (Start_Position, List, Count);
         Assert (Count = 20, "start position has 20 legal moves");
      end;

      -- Make/unmake round trip: 1. e4 then undo.
      declare
         P         : Position_Type := Start_Position;
         M         : Move_Type;
         U         : Undo_Info;
         Occ_Before : constant Bitboard := Occupancy (P);
      begin
         M := (From => 12, To => 28, Piece => White_Pawn,
               Promotion => White_Pawn, Flag => Double_Push);
         Make_Move (P, M, U);
         Assert (P.Side = Black, "after 1.e4 side is black");
         Assert (P.En_Passant = 20, "after 1.e4 ep square is e3");

         declare
            Black_Moves : Move_List;
            B_Count     : Natural;
         begin
            Generate_Legal_Moves (P, Black_Moves, B_Count);
            Assert (B_Count = 20, "black has 20 legal moves after 1.e4");
         end;

         Unmake_Move (P, M, U);
         Assert (P.Side = White, "side restored after unmake");
         Assert (Occupancy (P) = Occ_Before, "occupancy restored after unmake");
         Assert (P.En_Passant = -1, "ep square restored after unmake");
      end;

      -- Perft validation (known CPW values).
      declare
         P        : Position_Type;
         Expected : constant array (1 .. 5) of Natural :=
           (20, 400, 8_902, 197_281, 4_865_609);
      begin
         for D in 1 .. 5 loop
            P := Start_Position;
            Ada.Text_IO.Put_Line
              ("perft startpos depth" & Natural'Image (D)
               & " = " & Natural'Image (Nodes (P, D)));
            Assert (Nodes (P, D) = Expected (D), "startpos perft mismatch");
         end loop;
      end;

      declare
         P : Position_Type;
      begin
         Load (P, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
         Assert (Nodes (P, 1) = 48, "castling perft d1 must be 48");
         Assert (Nodes (P, 2) = 2039, "castling perft d2 must be 2039");
      end;

      declare
         P : Position_Type;
      begin
         Load (P, "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1");
         Assert (Nodes (P, 1) = 14, "ep perft d1 must be 14");
         Assert (Nodes (P, 2) = 191, "ep perft d2 must be 191");
         Assert (Nodes (P, 3) = 2812, "ep perft d3 must be 2812");
      end;

      declare
         P : Position_Type;
      begin
         Load (P, "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8");
         Assert (Nodes (P, 1) = 44, "promo perft d1 must be 44");
         Assert (Nodes (P, 2) = 1486, "promo perft d2 must be 1486");
      end;

      -- Castling rights are event-driven: a king that leaves e8 (and later
      -- returns) must lose both castling rights.
      declare
         P : Position_Type;
         U : Undo_Info;
      begin
         Load (P, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
         Assert (P.Castle (Black, King_Side) and P.Castle (Black, Queen_Side)
                   and P.Castle (White, King_Side) and P.Castle (White, Queen_Side),
                 "FEN KQkq must set all four castling rights");

         Make_Move (P, (From => 60, To => 61, Piece => Black_King, Promotion => White_Pawn, Flag => Quiet), U);  -- Ke8-f8
         Assert (not P.Castle (Black, King_Side)
                   and not P.Castle (Black, Queen_Side),
                 "black king move must clear both black rights");
         Assert (P.Castle (White, King_Side) and P.Castle (White, Queen_Side),
                 "white rights must be untouched");

         Make_Move (P, (From => 4, To => 5, Piece => White_King, Promotion => White_Pawn, Flag => Quiet), U);    -- Ke1-f1
         Make_Move (P, (From => 61, To => 60, Piece => Black_King, Promotion => White_Pawn, Flag => Quiet), U);  -- Kf8-e8
         Assert (not P.Castle (Black, Queen_Side),
                 "black must NOT castle after returning to e8");
      end;

      -- A rook leaving its home square clears only that side.
      declare
         P : Position_Type;
         U : Undo_Info;
      begin
         Load (P, "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1");
         Make_Move (P, (From => 0, To => 1, Piece => White_Rook, Promotion => White_Pawn, Flag => Quiet), U);    -- Ra1-b1
         Assert (not P.Castle (White, Queen_Side),
                 "white a1 rook move must clear queenside");
         Assert (P.Castle (White, King_Side),
                 "white h1 rook move must not clear kingside");
      end;

      Ada.Text_IO.Put_Line ("perft tests OK");

      -- Evaluation + search sanity.
      Assert (Evaluate (Start_Position) = 0, "start eval must be 0");

      -- The evaluation must be symmetric: mirroring the board (rank flip +
      -- color swap) must negate the static score. Exercise the positional
      -- terms (mobility, bishop pair, rooks on the 7th, passed pawns).
      declare
         function Flip_Rank (S : in Square_Type) return Square_Type is
           (Square_Type ((7 - Rank_Of (S)) * 8 + File_Of (S)));

         procedure Check_Symmetry (Fen : in String) is
            P : Position_Type;
            M : Position_Type;
         begin
            Load (P, Fen);
            M.Side := P.Side;
            for Color in Color_Type loop
               for Kind in Kind_Type loop
                  declare
                     Piece : constant Piece_Type := Make (Color, Kind);
                     B     : Bitboard := P.Pieces (Piece);
                  begin
                     while B /= 0 loop
                        declare
                           S : constant Square_Type := Lowest_Bit (B);
                        begin
                           Put_Piece (M, Make (Opposite (Color), Kind),
                                      Flip_Rank (S));
                        end;
                        B := B and (B - 1);
                     end loop;
                  end;
               end loop;
            end loop;
            Assert (Evaluate (M) = -Evaluate (P),
                    "eval not symmetric for FEN " & Fen);
         end Check_Symmetry;
      begin
         Check_Symmetry ("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1");
         Check_Symmetry ("r1bq1rk1/pp3ppp/2n1pn2/2pp4/3P1B2/2NBPN2/PPPQ1PPP/2KR3R w - - 0 1");
         Check_Symmetry ("4k3/6R1/8/8/8/8/6r1/4K3 w - - 0 1");
      end;

      declare
         Pos   : Position_Type := Start_Position;
         Best  : Move_Type;
         List  : Move_List;
         Count : Natural;
         Found : Boolean := False;
      begin
         Ada.Text_IO.Put_Line ("searching best move at depth 3...");
         Best := Best_Move (Pos, 3);
         Generate_Legal_Moves (Pos, List, Count);
         for I in 1 .. Count loop
            if List (I) = Best then
               Found := True;
               exit;
            end if;
          end loop;
          Ada.Text_IO.Put_Line ("best move found, legal=" & Boolean'Image (Found));
          Assert (Found, "Best_Move returned an illegal move");
       end;

      -- Time management regression test: the timed Best_Move must return a
      -- legal move promptly, whatever the budget (the interruptible search
      -- is what keeps the engine from losing on time under a GUI).
      declare
         Start_T : constant Time := Clock;
         Pos     : Position_Type := Start_Position;
         Best    : Move_Type;
         List    : Move_List;
         Count   : Natural;
         Found   : Boolean := False;
      begin
         Ada.Text_IO.Put_Line ("searching with a 0.1s time budget...");
         Best := Best_Move (Pos, 64, 0.1);
         Generate_Legal_Moves (Pos, List, Count);
         for I in 1 .. Count loop
            if List (I) = Best then
               Found := True;
               exit;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("budgeted move legal=" & Boolean'Image (Found)
            & ", elapsed=" & Duration'Image (To_Duration (Clock - Start_T)));
         Assert (Found, "timed Best_Move returned an illegal move");
         Assert (To_Duration (Clock - Start_T) < 2.0,
                 "timed Best_Move overran its budget");
      end;

      Ada.Text_IO.Put_Line ("all self tests OK");
   end Run;

end BBChess.Self_Tests;
