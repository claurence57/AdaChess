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

with BBChess.See;
use BBChess.See;

with BBChess.Search;
use BBChess.Search;

with BBChess.Clocks;
use BBChess.Clocks;

with BBChess.Hash;
use BBChess.Hash;

with BBChess.Polyglot;
use BBChess.Polyglot;

with BBChess.Text;
use BBChess.Text;

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

      -- Between / Line tables (a1 = 0, b2 = 9, a2 = 8, a4 = 24, h8 = 63).
      Assert (Between (0, 24) = (Bit (8) or Bit (16)),
              "between a1 and a4");
      Assert (Between (0, 63) = (Bit (9) or Bit (18) or Bit (27)
                                 or Bit (36) or Bit (45) or Bit (54)),
              "between a1 and h8");
      Assert (Between (0, 10) = 0, "non-aligned squares have no between");
      Assert (Line (0, 56) = (Bit (0) or Bit (8) or Bit (16) or Bit (24)
                              or Bit (32) or Bit (40) or Bit (48) or Bit (56)),
              "line a1-a8 is the a-file");
      Assert ((Line (0, 63) and Bit (9)) /= 0, "line a1-h8 contains b2");
      Assert (Line (0, 10) = 0, "non-aligned squares have no line");
      Assert (File_A_BB = (Bit (0) or Bit (8) or Bit (16) or Bit (24)
                           or Bit (32) or Bit (40) or Bit (48) or Bit (56)),
              "file A mask");
      Assert ((File_A_BB and File_H_BB) = 0, "file A and H are disjoint");
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
         Assert (Nodes (P, 3) = 97_862, "castling perft d3 must be 97862");
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

      -- Incremental Zobrist: after every real move (with keys enabled), the
      -- incrementally maintained Position.Key must equal the full recompute.
      -- This exercises castling, captures, en passant and promotions.
      declare
         P     : Position_Type;
         U     : Undo_Info;
         Moves : Move_List;
         Count : Natural;
         Bad   : Boolean := False;
      begin
         Load (P, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
         Set_Keys_Enabled (True);
         for Step in 1 .. 40 loop
            if Hash.Compute (P) /= P.Key then
               Bad := True;
               exit;
            end if;
            if Compute_Material (P) /= P.Material then
               Bad := True;
               exit;
            end if;
            Generate_Legal_Moves (P, Moves, Count);
            exit when Count = 0;
            Make_Move (P, Moves (1 + (Step * 7) mod Count), U);
         end loop;
         Set_Keys_Enabled (False);
         Assert (not Bad, "incremental Zobrist diverged from Compute");
      end;

      Ada.Text_IO.Put_Line ("incremental Zobrist OK");

      -- Packed move round-trip (transposition table encoding).
      declare
         P     : Position_Type;
         Moves : Move_List;
         Count : Natural;
         Ok    : Boolean := True;
      begin
         Load (P, "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
         Generate_Legal_Moves (P, Moves, Count);
         for I in 1 .. Count loop
            if Unpack_Move (Pack_Move (Moves (I))) /= Moves (I) then
               Ok := False;
               exit;
            end if;
         end loop;
         Assert (Ok, "packed move round-trip failed");
      end;

      Ada.Text_IO.Put_Line ("packed move round-trip OK");

      -- Illegal FENs must be rejected at load time, in particular a position
      -- that leaves the side not to move in check (a capturable king would
      -- otherwise crash the search when it looks for a missing king).
      declare
         P        : Position_Type;
         Rejected : Boolean := False;
      begin
         begin
            Load (P, "7k/8/8/8/8/8/8/K6R w - - 0 1");   -- Black king in check
         exception
            when Constraint_Error => Rejected := True;
         end;
         Assert (Rejected, "FEN leaving the side not to move in check must be rejected");

         Rejected := False;
         begin
            Load (P, "8/8/8/8/8/8/8/K7 w - - 0 1");    -- missing Black king
         exception
            when Constraint_Error => Rejected := True;
         end;
         Assert (Rejected, "FEN without one king per side must be rejected");
      end;

      Ada.Text_IO.Put_Line ("FEN validation OK");

      -- En-passant FEN field validation: a real target is only accepted when
      -- it matches the side to move and an enemy pawn actually sits behind it;
      -- every other (malformed) field must be normalised to "no en-passant"
      -- instead of yielding an inconsistent position.
      declare
         P : Position_Type;
      begin
         -- Valid: White to move, black pawn on d5, ep target d6.
         Load (P, "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
         Assert (P.En_Passant = 43, "valid ep d6 must be kept (square 43)");

         -- Wrong rank for the side to move: d3 with White to move.
         Load (P, "4k3/8/8/3pP3/8/8/8/4K3 w - d3 0 1");
         Assert (P.En_Passant = -1, "ep on the wrong rank must be rejected");

         -- Junk file: must not raise, must yield no ep target.
         Load (P, "4k3/8/8/3pP3/8/8/8/4K3 w - x6 0 1");
         Assert (P.En_Passant = -1, "ep with a junk file must be rejected");

         -- No enemy pawn behind the target (only a White pawn on e5).
         Load (P, "4k3/8/8/4P3/8/8/8/4K3 w - d6 0 1");
         Assert (P.En_Passant = -1, "ep without a pawn to capture must be rejected");

         -- Black to move: a valid target is on rank 3, captured pawn on rank 4.
         Load (P, "4k3/8/8/8/3Pp3/8/8/4K3 b - d3 0 1");
         Assert (P.En_Passant = 19, "valid ep d3 (Black) must be kept (square 19)");
      end;

      Ada.Text_IO.Put_Line ("en-passant FEN validation OK");

      -- En-passant capture arithmetic: the captured pawn is read from the
      -- square directly behind the target. Exercise a legal capture and its
      -- undo (the computed square is a valid index and the board is restored).
      declare
         P          : Position_Type;
         U          : Undo_Info;
         M          : constant Move_Type :=
           (From => 36, To => 43, Piece => White_Pawn,
            Promotion => White_Pawn, Flag => En_Passant);
         Occ_Before : Bitboard;
      begin
         Load (P, "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1");
         Occ_Before := Occupancy (P);
         Make_Move (P, M, U);
         Assert (U.Has_Captured and then Kind (U.Captured) = Pawn,
                 "ep capture must record a captured pawn");
         Assert (U.Captured_Square = 35,
                 "ep capture must take the pawn on d5 (square 35)");
         Assert (Is_Empty (P, 35) and then Is_Empty (P, 36),
                 "ep capture must clear d5 (pawn) and e5 (mover)");
         Assert (not Is_Empty (P, 43), "ep capture must land the pawn on d6");

         Unmake_Move (P, M, U);
         Assert (Occupancy (P) = Occ_Before,
                 "ep unmake must restore the occupancy");
      end;

      Ada.Text_IO.Put_Line ("en-passant arithmetic OK");

      -- Evaluation + search sanity. Static is the tempo-free, fully
      -- symmetric core (0 on the initial position); Evaluate adds Tempo for
      -- the side to move (White on the initial position).
      Assert (Static (Start_Position) = 0, "start static eval must be 0");
      Assert (Evaluate (Start_Position) = Tempo,
              "start eval must equal Tempo (White to move)");

      -- The tempo-free evaluation must be symmetric: mirroring the board
      -- (rank flip + color swap) must negate the static score. Exercise the
      -- positional terms (mobility, bishop pair, rooks on the 7th, passed
      -- pawns, open files).
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
            M.Material := Compute_Material (M);
            Assert (Static (M) = -Static (P),
                    "eval not symmetric for FEN " & Fen);
         end Check_Symmetry;
      begin
         Check_Symmetry ("4k3/8/8/8/8/8/4P3/4K3 w - - 0 1");
         Check_Symmetry ("r1bq1rk1/pp3ppp/2n1pn2/2pp4/3P1B2/2NBPN2/PPPQ1PPP/2KR3R w - - 0 1");
         Check_Symmetry ("4k3/6R1/8/8/8/8/6r1/4K3 w - - 0 1");
      end;

      declare
         Pos   : constant Position_Type := Start_Position;
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
         Pos     : constant Position_Type := Start_Position;
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

      -- Soft/hard time allocation (BBChess.Clocks): the arithmetic must
      -- reserve a safety margin, keep hard = 2 x soft, honour movestogo and
      -- never return more than the remaining clock.
      declare
         A : Allocation;
      begin
         A := Exact (0.1);
         Assert (A.Soft = 0.1 and then A.Hard = 0.1,
                 "exact budget must set soft = hard = movetime");

         -- 1 s + 0.1 s, no move count: old fraction (1/30) + 0.75*inc.
         A := Clock_Based (1.0, 0.1, 0);
         Assert (A.Soft > 0.10 and then A.Soft < 0.12,
                 "1s+0.1s allocation must stay near 0.11s");
         Assert (A.Hard <= 1.0 - Safety_Margin,
                 "hard limit must stay under the clock minus the margin");
         Assert (A.Hard >= A.Soft, "hard limit must not be below soft");

         -- Same clock, 10 moves to go: the per-move fraction must grow.
         declare
            B : constant Allocation := Clock_Based (1.0, 0.1, 10);
         begin
            Assert (B.Soft > A.Soft,
                    "movestogo must increase the per-move allocation");
            Assert (B.Soft <= 1.0 - Safety_Margin,
                    "movestogo allocation must still reserve the margin");
         end;

         -- Small clock (0.3 s, no increment): soft = 1/30, well under the
         -- 0.2 s reserve, hard = 2 x soft.
         A := Clock_Based (0.3, 0.0, 0);
         Assert (A.Soft < 0.3 - Safety_Margin,
                 "small-clock allocation must stay under clock minus margin");
         Assert (A.Hard <= 0.3 - Safety_Margin,
                 "small-clock hard limit must stay under clock minus margin");

         -- The allocation can never exceed the clock itself, whatever the
         -- (even absurd) clock: at worst a 1 ms fallback.
         A := Clock_Based (0.02, 0.0, 0);
         Assert (A.Soft <= 0.02 and then A.Hard <= 0.02,
                 "allocation must never exceed the remaining clock");
      end;
      Ada.Text_IO.Put_Line ("time allocation OK");

      -- Soft/hard search: the hard limit is the interruptible deadline, the
      -- soft one only stops the launching of a new iteration. A wide
      -- soft/hard pair must still return a legal move within the hard bound.
      declare
         Start_T : constant Time := Clock;
         Pos     : constant Position_Type := Start_Position;
         Best    : Move_Type;
         List    : Move_List;
         Count   : Natural;
         Found   : Boolean := False;
      begin
         Best := Best_Move (Pos, 64, Soft_Alloc => 0.02, Hard_Alloc => 0.30);
         Generate_Legal_Moves (Pos, List, Count);
         for I in 1 .. Count loop
            if List (I) = Best then
               Found := True;
               exit;
            end if;
         end loop;
         Ada.Text_IO.Put_Line
           ("soft/hard search: legal=" & Boolean'Image (Found)
            & ", elapsed=" & Duration'Image (To_Duration (Clock - Start_T)));
         Assert (Found, "soft/hard Best_Move returned an illegal move");
         Assert (To_Duration (Clock - Start_T) < 0.6,
                 "soft/hard Best_Move overran its hard limit");
      end;

      -- A soft/hard search with both limits zero must be exactly a
      -- fixed-depth search (same node count), so the new entry point does
      -- not perturb untimed play.
      declare
         Pos          : constant Position_Type := Start_Position;
         Ref_Move     : Move_Type;
         Got_Move     : Move_Type;
         Ref_Nodes    : Natural;
         Got_Nodes    : Natural;
      begin
         Reset_Search;
         Reset_Nodes;
         Ref_Move := Best_Move (Pos, 5, 0.0, 0);
         Ref_Nodes := Nodes_Searched;

         Reset_Search;
         Reset_Nodes;
         Got_Move := Best_Move (Pos, 5, Soft_Alloc => 0.0, Hard_Alloc => 0.0);
         Got_Nodes := Nodes_Searched;

         Assert (Got_Nodes = Ref_Nodes,
                 "zero soft/hard search must match the fixed-depth node count");
         Assert (Got_Move = Ref_Move,
                 "zero soft/hard search must match the fixed-depth move");
         Reset_Search;
      end;
      Ada.Text_IO.Put_Line ("soft/hard search OK");

      -- Repetition handling: with a game history where the current position
      -- already occurred twice, the search must still return a legal move
      -- (draws are detected inside the tree, not at the root) and Reset_Search
      -- must clear the history for the next game.
      declare
         Pos  : Position_Type;
         Best : Move_Type;
         Keys : Game_Key_Array := (others => 0);
         List : Move_List;
         Count : Natural;
         Found : Boolean := False;
      begin
         Load (Pos, "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1");
         Keys (0) := Pos.Key;
         Keys (1) := Pos.Key;   -- the current position "already seen twice"
         Set_Game_History (Keys, 2);
         Best := Best_Move (Pos, 4);
         Generate_Legal_Moves (Pos, List, Count);
         for I in 1 .. Count loop
            if List (I) = Best then
               Found := True;
               exit;
            end if;
         end loop;
         Assert (Found, "search with a repeated history returned an illegal move");
         Reset_Search;
         Ada.Text_IO.Put_Line ("repetition handling OK");
      end;

      -- Static exchange evaluation: undefended pieces, recaptures, losing
      -- lines and pinned defenders must be scored consistently.
      declare
         function See (Fen : in String; Move : in Move_Type) return Score_Type is
            P : Position_Type;
         begin
            Load (P, Fen);
            return Static_Exchange_Value (P, Move);
         end See;
      begin
         -- b4xa5 : pawn wins an undefended rook.
         Assert (See ("7k/8/8/r7/1P6/8/8/7K w - - 0 1",
                      (From => 25, To => 32, Piece => White_Pawn,
                       Promotion => White_Pawn, Flag => Quiet)) = 500,
                 "SEE b4xa5 must be +500 (undefended rook)");

         -- g5xf6 : pawn takes a defended pawn, the recapture leads to an
         -- even trade (0).
         Assert (See ("7k/4p3/5p2/6P1/8/8/8/7K w - - 0 1",
                      (From => 38, To => 45, Piece => White_Pawn,
                       Promotion => White_Pawn, Flag => Quiet)) = 0,
                 "SEE g5xf6 must be 0 (equal trade)");

         -- Nxe4 : a knight capturing a pawn defended by a pawn loses the
         -- exchange (-220).
         Assert (See ("7k/8/8/3p4/4p3/2N5/8/7K w - - 0 1",
                      (From => 18, To => 28, Piece => White_Knight,
                       Promotion => White_Pawn, Flag => Quiet)) = -220,
                 "SEE Nxe4 must be -220 (knight for pawn)");

         -- c5xb6 : the only defender of the queen is a pinned pawn, so the
         -- queen falls for free (+900).
         Assert (See ("k7/p7/1q6/2P5/8/R7/8/7K w - - 0 1",
                      (From => 34, To => 41, Piece => White_Pawn,
                       Promotion => White_Pawn, Flag => Quiet)) = 900,
                 "SEE c5xb6 must be +900 (pinned defender ignored)");

         -- e5xd6 en passant : pawn for pawn with nothing left to recapture.
         Assert (See ("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1",
                      (From => 36, To => 43, Piece => White_Pawn,
                       Promotion => White_Pawn, Flag => En_Passant)) = 100,
                 "SEE ep capture must be +100");

         Ada.Text_IO.Put_Line ("SEE tests OK");
      end;

      -- Polyglot key: must match the reference implementation exactly
      -- (piece placement, castling, conditional en passant, side to move).
      declare
         function Key_Of (Fen : in String) return Bitboard is
            P : Position_Type;
         begin
            Load (P, Fen);
            return Polyglot_Key (P);
         end Key_Of;
      begin
         Assert
           (Key_Of ("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")
            = 16#463B96181691FC9C#,
            "polyglot key startpos");
         Assert
           (Key_Of ("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
            = 16#FDA239CC692A6053#,
            "polyglot key castling");
         Assert
           (Key_Of ("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
            = 16#5F442AAD040588EC#,
            "polyglot key en passant (capturable)");
         Assert
           (Key_Of ("4k3/8/8/3p4/8/8/8/4K3 w - d6 0 1")
            = 16#5DCDC6EF271A91C9#,
            "polyglot key en passant (not capturable)");
         Assert
           (Key_Of ("r1bq1rk1/pp3ppp/2n1pn2/2pp4/3P1B2/2NBPN2/PPPQ1PPP/2KR3R w - - 0 1")
            = 16#FA541663E45EC608#,
            "polyglot key middlegame");
         Ada.Text_IO.Put_Line ("polyglot key OK");
      end;

      -- B2 regression: after a multi-threaded search, Stop_Search stays set
      -- (the Lazy SMP primary thread raises it to stop the helpers). A later
      -- single-threaded search must clear it, otherwise it aborts at the
      -- first Poll_Time checkpoint and falls back to Quick_Move. Compare the
      -- move and the node count against a clean reference run on the same,
      -- freshly reset position: they must be identical.
      declare
         Pos       : Position_Type;
         Ref_Move  : Move_Type;
         Got_Move  : Move_Type;
         Ref_Nodes : Natural;
         Got_Nodes : Natural;
         List      : Move_List;
         Count     : Natural;
         Found     : Boolean := False;
      begin
         Pos := Start_Position;

         -- Reference: a plain single-threaded search from a reset state.
         Set_Threads (1);
         Reset_Search;
         Reset_Nodes;
         Ref_Move := Best_Move (Pos, 5, 0.0, 0);
         Ref_Nodes := Nodes_Searched;

         -- Leave Stop_Search set by running a multi-threaded search.
         Set_Threads (4);
         Reset_Search;
         declare
            Ignored : Move_Type;
         begin
            Ignored := Best_Move (Pos, 5, 0.0, 0);
            pragma Unreferenced (Ignored);
         end;

         -- Single-threaded again: must reproduce the reference exactly.
         Set_Threads (1);
         Reset_Search;
         Reset_Nodes;
         Got_Move := Best_Move (Pos, 5, 0.0, 0);
         Got_Nodes := Nodes_Searched;

         Generate_Legal_Moves (Pos, List, Count);
         for I in 1 .. Count loop
            if List (I) = Got_Move then
               Found := True;
               exit;
            end if;
         end loop;

         Ada.Text_IO.Put_Line
           ("MT-then-ST search: ref nodes=" & Natural'Image (Ref_Nodes)
            & ", got nodes=" & Natural'Image (Got_Nodes));
         Assert (Found, "single-threaded search after SMP returned an illegal move");
         Assert (Got_Nodes = Ref_Nodes,
                 "single-threaded search after SMP did not reach full depth");
         Assert (Got_Move = Ref_Move,
                 "single-threaded search after SMP differs from the reference");
         Reset_Search;
      end;

      Ada.Text_IO.Put_Line ("MT-then-ST search OK");

      -- B4 regression: a very long protocol token must be truncated safely
      -- instead of overwriting adjacent state. Split_Command is the exact
      -- helper the command loop uses; it must bound the copy to the buffer.
      declare
         Long   : constant String (1 .. 200) := (others => 'x');
         Cmd    : String (1 .. 64);
         Par    : String (1 .. 128);
         Cmd_L  : Natural;
         Par_L  : Natural;
      begin
         Split_Command (Long & " stop", Cmd, Cmd_L, Par, Par_L);
         Assert (Cmd_L = Cmd'Length,
                 "over-long command word must be truncated to the buffer");
         Assert (Cmd (1) = 'x' and then Cmd (Cmd_L) = 'x',
                 "truncated command must keep the leading characters");

         -- A normal line right after must parse correctly: no state was
         -- corrupted next to the command buffer.
         Split_Command ("setboard 8/8/8/8/8/8/8/K6k w - - 0 1",
                        Cmd, Cmd_L, Par, Par_L);
         Assert (Cmd (1 .. Cmd_L) = "setboard", "normal command after long line");
         Assert (Par (1 .. Par_L) = "8/8/8/8/8/8/8/K6k w - - 0 1",
                 "normal parameter after long line");
      end;

      -- B4 regression: appending an over-long token to the FEN buffer must
      -- drop the extra characters and never write past the end.
      declare
         Buf  : String (1 .. 16);
         Last : Natural := 0;
         Over : Boolean := False;
      begin
         Append_Bounded (Buf, Last, "12345678901234567890", Over);
         Assert (Last = Buf'Length, "append must stop at the buffer length");
         Assert (Over, "append must report the truncation");
         Append_Bounded (Buf, Last, "abc", Over);
         Assert (Last = Buf'Length and then Over,
                 "append on a full buffer must stay bounded");
      end;

      Ada.Text_IO.Put_Line ("long-token handling OK");

      -- Thread arguments: -T#, --thread=#, and the malformed fallbacks.
      Assert (Thread_Count ("-T4", 0) = 4, "-T4");
      Assert (Thread_Count ("-T1", 0) = 1, "-T1");
      Assert (Thread_Count ("--thread=8", 0) = 8, "--thread=8");
      Assert (Thread_Count ("-T", 0) = 0, "-T without digits");
      Assert (Thread_Count ("-Tx", 0) = 0, "-Tx is not a count");
      Assert (Thread_Count ("--thread=", 0) = 0, "--thread= without digits");
      Assert (Thread_Count ("--threads", 0) = 0, "--threads needs a value");
      Assert (Thread_Count ("-T12", 0) = 12, "two-digit -T12");
      Ada.Text_IO.Put_Line ("thread argument parsing OK");

      Ada.Text_IO.Put_Line ("all self tests OK");
   end Run;
end BBChess.Self_Tests;
