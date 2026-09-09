--
--  AdaChess-BB : static evaluation (body)
--
--  Material plus piece-square tables (PST), stored from each side's own
--  point of view: rows run from the back rank (row 0) to the enemy side
--  (row 7). A White piece uses row = Rank_Of(square); a Black piece uses
--  the mirrored rank, so the same table serves both colors.
--
--  The evaluation is "tapered": every positional term is scored for the
--  opening and for the endgame, then interpolated according to the game
--  phase (computed from the remaining material). The positional terms,
--  evaluated per color and mirrored for the opponent, are:
--    * bishop pair;
--    * piece mobility (attacked squares, weighted per piece kind);
--    * rooks on the 7th rank (bonus grows when the enemy king is still on
--      its back ranks), stronger in the endgame;
--    * rooks on open / semi-open files;
--    * pawn structure: doubled and isolated pawns, passed pawns (no enemy
--      pawn in front on the same or adjacent files), with a larger bonus for
--      connected passed pawns; all derived from bitboard file masks;
--    * king safety (pawn shelter, open files near the king, pawn storm,
--      enemy attackers around the king) - opening/middlegame only;
--    * king endgame activity (the base PST keeps the king at home in the
--      middlegame; the endgame table drives it toward the center).
--
--  Every per-side term uses only color-generic helpers, so subtracting the
--  White and Black scores keeps the whole evaluation symmetric and equal to
--  0 on the initial position. Occupancy is computed once per Static call and
--  shared between both colors and the king-safety term.
--

with BBChess.Attacks;
use BBChess.Attacks;

package body BBChess.Eval is

   type PST_Table is array (Natural range 0 .. 7, Natural range 0 .. 7)
     of Score_Type;

   -- One-bit-per-square mask of every file (used for pawn-file queries).
   type File_Mask_Table is array (Natural range 0 .. 7) of Bitboard;
   File_Mask : constant File_Mask_Table :=
     (0 => Bit (0)  or Bit (8)  or Bit (16) or Bit (24)
            or Bit (32) or Bit (40) or Bit (48) or Bit (56),
      1 => Bit (1)  or Bit (9)  or Bit (17) or Bit (25)
            or Bit (33) or Bit (41) or Bit (49) or Bit (57),
      2 => Bit (2)  or Bit (10) or Bit (18) or Bit (26)
            or Bit (34) or Bit (42) or Bit (50) or Bit (58),
      3 => Bit (3)  or Bit (11) or Bit (19) or Bit (27)
            or Bit (35) or Bit (43) or Bit (51) or Bit (59),
      4 => Bit (4)  or Bit (12) or Bit (20) or Bit (28)
            or Bit (36) or Bit (44) or Bit (52) or Bit (60),
      5 => Bit (5)  or Bit (13) or Bit (21) or Bit (29)
            or Bit (37) or Bit (45) or Bit (53) or Bit (61),
      6 => Bit (6)  or Bit (14) or Bit (22) or Bit (30)
            or Bit (38) or Bit (46) or Bit (54) or Bit (62),
       7 => Bit (7)  or Bit (15) or Bit (23) or Bit (31)
             or Bit (39) or Bit (47) or Bit (55) or Bit (63));

   -- One-bit-per-square mask of every rank (0 = rank 1 / a1..h1).
   type Rank_Mask_Table is array (Natural range 0 .. 7) of Bitboard;
   Rank_Mask : constant Rank_Mask_Table :=
     (0 => Bit (0) or Bit (1)  or Bit (2)  or Bit (3)
            or Bit (4) or Bit (5)  or Bit (6)  or Bit (7),
      1 => Bit (8) or Bit (9)  or Bit (10) or Bit (11)
            or Bit (12) or Bit (13) or Bit (14) or Bit (15),
      2 => Bit (16) or Bit (17) or Bit (18) or Bit (19)
            or Bit (20) or Bit (21) or Bit (22) or Bit (23),
      3 => Bit (24) or Bit (25) or Bit (26) or Bit (27)
            or Bit (28) or Bit (29) or Bit (30) or Bit (31),
      4 => Bit (32) or Bit (33) or Bit (34) or Bit (35)
            or Bit (36) or Bit (37) or Bit (38) or Bit (39),
      5 => Bit (40) or Bit (41) or Bit (42) or Bit (43)
            or Bit (44) or Bit (45) or Bit (46) or Bit (47),
      6 => Bit (48) or Bit (49) or Bit (50) or Bit (51)
            or Bit (52) or Bit (53) or Bit (54) or Bit (55),
      7 => Bit (56) or Bit (57) or Bit (58) or Bit (59)
            or Bit (60) or Bit (61) or Bit (62) or Bit (63));

   -- Squares strictly above (White's forward) / below a given rank.
   type Rank_Span_Table is array (Natural range 0 .. 7) of Bitboard;
   Above_Rank : constant Rank_Span_Table :=
     (Rank_Mask (1) or Rank_Mask (2) or Rank_Mask (3) or Rank_Mask (4)
        or Rank_Mask (5) or Rank_Mask (6) or Rank_Mask (7),
      Rank_Mask (2) or Rank_Mask (3) or Rank_Mask (4) or Rank_Mask (5)
        or Rank_Mask (6) or Rank_Mask (7),
      Rank_Mask (3) or Rank_Mask (4) or Rank_Mask (5) or Rank_Mask (6)
        or Rank_Mask (7),
      Rank_Mask (4) or Rank_Mask (5) or Rank_Mask (6) or Rank_Mask (7),
      Rank_Mask (5) or Rank_Mask (6) or Rank_Mask (7),
      Rank_Mask (6) or Rank_Mask (7),
      Rank_Mask (7),
      0);
   Below_Rank : constant Rank_Span_Table :=
     (0,
      Rank_Mask (0),
      Rank_Mask (0) or Rank_Mask (1),
      Rank_Mask (0) or Rank_Mask (1) or Rank_Mask (2),
      Rank_Mask (0) or Rank_Mask (1) or Rank_Mask (2) or Rank_Mask (3),
      Rank_Mask (0) or Rank_Mask (1) or Rank_Mask (2) or Rank_Mask (3)
        or Rank_Mask (4),
      Rank_Mask (0) or Rank_Mask (1) or Rank_Mask (2) or Rank_Mask (3)
        or Rank_Mask (4) or Rank_Mask (5),
      Rank_Mask (0) or Rank_Mask (1) or Rank_Mask (2) or Rank_Mask (3)
        or Rank_Mask (4) or Rank_Mask (5) or Rank_Mask (6));

   -- The three files that make up the "front" of a pawn on File.
   function Front_Files (File : in Natural) return Bitboard is
     (File_Mask (Natural'Max (0, File - 1))
      or File_Mask (File)
      or File_Mask (Natural'Min (7, File + 1)));

   -- Pawns of Color that are passed: no enemy pawn on the same or adjacent
   -- files in front of them (purely bitboard: mask + intersection, no loop).
   function Passed_Pawns (Position : in Position_Type;
                          Color    : in Color_Type) return Bitboard is
      Own    : constant Bitboard := Position.Pieces (Make (Color, Pawn));
      Enemy  : constant Bitboard :=
        Position.Pieces (Make (Opposite (Color), Pawn));
      Block  : Bitboard := 0;
      Res    : Bitboard := 0;
      B      : Bitboard := Own;
   begin
      -- A pawn on a given file is blocked when an enemy pawn stands on one
      -- of its front files at a rank strictly in front (above for White,
      -- below for Black). Build, per occupied own pawn, the blocking mask.
      while B /= 0 loop
         declare
            Sq    : constant Square_Type := Lowest_Bit (B);
            R     : constant Natural := Rank_Of (Sq);
            Front : Bitboard;
         begin
            if Color = White then
               Front := Enemy and Above_Rank (R) and Front_Files (File_Of (Sq));
            else
               Front := Enemy and Below_Rank (R) and Front_Files (File_Of (Sq));
            end if;
            if Front = 0 then
               Res := Res or Bit (Sq);
            end if;
         end;
         B := B and (B - 1);
      end loop;
      return Res;
   end Passed_Pawns;

   -- Rows: 0 = own back rank, 7 = just before the opponent's back rank.
   Pawn_PST : constant PST_Table :=
     ((0, 0, 0, 0, 0, 0, 0, 0),
      (0, 0, 0, 0, 0, 0, 0, 0),
      (0, 0, 5, 10, 10, 5, 0, 0),
      (0, 0, 5, 20, 20, 5, 0, 0),
      (0, 0, 10, 25, 25, 10, 0, 0),
      (0, 0, 10, 30, 30, 10, 0, 0),
      (0, 10, 20, 50, 50, 20, 10, 0),
      (0, 0, 0, 0, 0, 0, 0, 0));

   Knight_PST : constant PST_Table :=
     ((-50, -40, -30, -30, -30, -30, -40, -50),
      (-40, -20, 0, 0, 0, 0, -20, -40),
      (-30, 0, 10, 15, 15, 10, 0, -30),
      (-30, 5, 15, 20, 20, 15, 5, -30),
      (-30, 0, 15, 20, 20, 15, 0, -30),
      (-30, 5, 10, 15, 15, 10, 5, -30),
      (-40, -20, 0, 5, 5, 0, -20, -40),
      (-50, -40, -30, -30, -30, -30, -40, -50));

   Bishop_PST : constant PST_Table :=
     ((-20, -10, -10, -10, -10, -10, -10, -20),
      (-10, 0, 0, 0, 0, 0, 0, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-10, 5, 5, 10, 10, 5, 5, -10),
      (-10, 0, 10, 10, 10, 10, 0, -10),
      (-10, 5, 5, 10, 10, 5, 5, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-20, -10, -10, -10, -10, -10, -10, -20));

   Rook_PST : constant PST_Table :=
     ((0, 0, 0, 0, 0, 0, 0, 0),
      (5, 10, 10, 10, 10, 10, 10, 5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (-5, 0, 0, 0, 0, 0, 0, -5),
      (5, 10, 10, 10, 10, 10, 10, 5),
      (0, 0, 0, 0, 0, 0, 0, 0));

   Queen_PST : constant PST_Table :=
     ((-20, -10, -10, -5, -5, -10, -10, -20),
      (-10, 0, 0, 0, 0, 0, 0, -10),
      (-10, 0, 5, 5, 5, 5, 0, -10),
      (-5, 0, 5, 5, 5, 5, 0, -5),
      (0, 0, 5, 5, 5, 5, 0, -5),
      (-10, 5, 5, 5, 5, 5, 0, -10),
      (-10, 0, 5, 0, 0, 0, 0, -10),
      (-20, -10, -10, -5, -5, -10, -10, -20));

   -- Middlegame: the king belongs near its castled squares.
   King_PST : constant PST_Table :=
     ((20, 30, 10, 0, 0, 10, 30, 20),
      (-10, -10, 0, 0, 0, 0, -10, -10),
      (-20, -20, -20, -20, -20, -20, -20, -20),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-30, -30, -30, -30, -30, -30, -30, -30),
      (-40, -40, -40, -40, -40, -40, -40, -40),
      (-40, -40, -40, -40, -40, -40, -40, -40));

   -- Endgame: the king must be active and central.
   King_End_PST : constant PST_Table :=
     ((-20, -15, -10, -5, -5, -10, -15, -20),
      (-15, -10, -5, 0, 0, -5, -10, -15),
      (-10, -5, 0, 5, 5, 0, -5, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-10, 0, 5, 10, 10, 5, 0, -10),
      (-10, -5, 0, 5, 5, 0, -5, -10),
      (-15, -10, -5, 0, 0, -5, -10, -15),
      (-20, -15, -10, -5, -5, -10, -15, -20));

   function Piece_Value (Kind : in Kind_Type) return Score_Type is
   begin
      case Kind is
         when Pawn   => return 100;
         when Knight => return 320;
         when Bishop => return 330;
         when Rook   => return 500;
         when Queen  => return 900;
         when King   => return 0;
      end case;
   end Piece_Value;

   function PST (Kind : in Kind_Type; Color : in Color_Type;
                 Square : in Square_Type) return Score_Type is
      File_Idx : constant Natural := File_Of (Square);
      Row      : Natural;
   begin
      if Color = White then
         Row := Rank_Of (Square);
      else
         Row := 7 - Rank_Of (Square);
      end if;

      case Kind is
         when Pawn   => return Pawn_PST (Row, File_Idx);
         when Knight => return Knight_PST (Row, File_Idx);
         when Bishop => return Bishop_PST (Row, File_Idx);
         when Rook   => return Rook_PST (Row, File_Idx);
         when Queen  => return Queen_PST (Row, File_Idx);
         when King   => return King_PST (Row, File_Idx);
      end case;
   end PST;

   -- Row of Square from the given side's own point of view (same convention
   -- as the PSTs).
   function Own_Row (Color : in Color_Type; Sq : in Square_Type) return Natural is
   begin
      if Color = White then
         return Rank_Of (Sq);
      else
         return 7 - Rank_Of (Sq);
      end if;
   end Own_Row;

   -- Pseudo-legal attacks of a piece (sliders take the occupancy into
   -- account; leapers do not need it).
   function Piece_Attacks (Kind     : in Kind_Type;
                           Square   : in Square_Type;
                           Occupancy : in Bitboard) return Bitboard is
   begin
      case Kind is
         when Knight => return Knight_Attacks (Square);
         when Bishop => return Bishop_Attacks (Square, Occupancy);
         when Rook   => return Rook_Attacks (Square, Occupancy);
         when Queen  => return Queen_Attacks (Square, Occupancy);
         when others => return 0;
      end case;
   end Piece_Attacks;

   ----------------------------------
   -- Tapered (phase) scores --
   ----------------------------------

   -- A score is evaluated for the opening (Phase = 100) and for the
   -- endgame (Phase = 0), then interpolated linearly.
   type Tapered_Score_Type is
      record
         Opening  : Score_Type;
         End_Game : Score_Type;
      end record;

   function Both (Value : in Score_Type) return Tapered_Score_Type is
     ((Value, Value));

   function "+" (L, R : in Tapered_Score_Type) return Tapered_Score_Type is
     ((L.Opening + R.Opening, L.End_Game + R.End_Game));

   function Blend (Score : in Tapered_Score_Type; Phase : in Natural)
     return Score_Type is
   begin
      return (Score.Opening * Phase + Score.End_Game * (100 - Phase)) / 100;
   end Blend;

   -- Game phase from the remaining material (0 = pure endgame,
   -- 100 = full opening). Mirrors the classic phase count.
   function Game_Phase (Position : in Position_Type) return Natural is
      P : Natural := 0;
   begin
      for Color in Color_Type loop
         P := P + 4 * Popcount (Position.Pieces (Make (Color, Knight)));
         P := P + 4 * Popcount (Position.Pieces (Make (Color, Bishop)));
         P := P + 9 * Popcount (Position.Pieces (Make (Color, Rook)));
         P := P + 16 * Popcount (Position.Pieces (Make (Color, Queen)));
      end loop;
      if P > 100 then
         P := 100;
      end if;
      return P;
   end Game_Phase;

   --------------------------
   -- Positional constants --
   --------------------------

   Bishop_Pair_Opening : constant Score_Type := 20;
   Bishop_Pair_Endgame : constant Score_Type := 45;

   -- Mobility: centipawns per attacked (reachable) square, per piece kind.
   Mobility_N : constant Score_Type := 4;
   Mobility_B : constant Score_Type := 4;
   Mobility_R : constant Score_Type := 2;
   Mobility_Q : constant Score_Type := 1;

   Rook_On_7th_Opening : constant Score_Type := 15;
   Rook_On_7th_Endgame : constant Score_Type := 35;
   -- Extra bonus when the enemy king is still close to its back ranks.
   Rook_On_7th_King    : constant Score_Type := 25;

   -- Rook on an open (no pawn at all) / semi-open (no friendly pawn) file.
   -- A rook is activated by the absence of *friendly* pawns in front of it;
   -- a fully open file is worth a bit more than a semi-open one.
   Rook_Open_File_Opening    : constant Score_Type := 22;
   Rook_Open_File_Endgame    : constant Score_Type := 16;
   Rook_Semi_Open_Opening    : constant Score_Type := 10;
   Rook_Semi_Open_Endgame    : constant Score_Type := 6;

   -- Pawn structure penalties (per offending pawn).
   Doubled_Pawn_Opening : constant Score_Type := 8;
   Doubled_Pawn_Endgame : constant Score_Type := 5;
   Isolated_Pawn_Opening : constant Score_Type := 10;
   Isolated_Pawn_Endgame : constant Score_Type := 12;

   -- Passed pawn bonus indexed by the pawn "own row" (0 = back rank).
   -- Row 0 and 7 are unreachable for a pawn, hence 0.
   Passed_Pawn_Opening : constant array (Natural range 0 .. 7) of Score_Type :=
     (0, 5, 8, 12, 16, 22, 30, 0);
   Passed_Pawn_Endgame : constant array (Natural range 0 .. 7) of Score_Type :=
     (0, 12, 22, 38, 60, 90, 130, 0);

   -- King safety.
   Pawn_Shield_Row1      : constant Score_Type := 8;
   Pawn_Shield_Row2      : constant Score_Type := 6;
   Pawn_Shield_Row3      : constant Score_Type := 3;
   Open_File_Near_King   : constant Score_Type := 10;
   Pawn_Storm            : constant Score_Type := 3;
   King_Attack_Knight    : constant Score_Type := 5;
   King_Attack_Bishop    : constant Score_Type := 5;
   King_Attack_Rook      : constant Score_Type := 8;
   King_Attack_Queen     : constant Score_Type := 12;
   King_Safety_Min_Phase : constant Natural := 20;
   -- Below this phase, king safety is irrelevant (its weight is ~0 anyway)
   -- and is not even computed, which keeps the endgame evaluation cheap.

   --------------------
   -- King safety --
   --------------------

   -- Opening/middlegame safety of Color's king. Positive when the king is
   -- well sheltered, negative when it is exposed / under attack.
   function King_Safety (Position : in Position_Type;
                         Color    : in Color_Type;
                         Occ      : in Bitboard) return Score_Type
   is
      Enemy    : constant Color_Type := Opposite (Color);
      King_Sq  : constant Square_Type :=
        Lowest_Bit (Position.Pieces (Make (Color, King)));
      King_File : constant Natural := File_Of (King_Sq);
      Zone     : constant Bitboard := King_Attacks (King_Sq);
      Result   : Score_Type := 0;
      Lo, Hi   : Integer;
      B        : Bitboard;
   begin
      -- Weighted enemy attackers aiming at the squares around our king.
      for Kind in Knight .. Queen loop
         declare
            Pieces : Bitboard := Position.Pieces (Make (Enemy, Kind));
         begin
            while Pieces /= 0 loop
               declare
                  Sq  : constant Square_Type := Lowest_Bit (Pieces);
                  Att : constant Bitboard := Piece_Attacks (Kind, Sq, Occ);
               begin
                  if (Att and Zone) /= 0 then
                     case Kind is
                        when Knight => Result := Result - King_Attack_Knight;
                        when Bishop => Result := Result - King_Attack_Bishop;
                        when Rook   => Result := Result - King_Attack_Rook;
                        when Queen  => Result := Result - King_Attack_Queen;
                        when others => null;
                     end case;
                  end if;
               end;
               Pieces := Pieces and (Pieces - 1);
            end loop;
         end;
      end loop;

      -- Pawn shield / open files / pawn storm, only for a wing (castled or
      -- edge) king. A central king gets no shelter but is already punished
      -- by the king PST.
      if King_File <= 1 then
         Lo := 0;
         Hi := 2;
      elsif King_File >= 6 then
         Lo := 5;
         Hi := 7;
      else
         Lo := 1;
         Hi := 0;   -- empty range: no wing
      end if;

      if Lo <= Hi then
         declare
            Has_Pawn  : array (0 .. 7) of Boolean := (others => False);
            Front_Row : array (0 .. 7) of Natural := (others => 9);
         begin
            B := Position.Pieces (Make (Color, Pawn));
            while B /= 0 loop
               declare
                  S : constant Square_Type := Lowest_Bit (B);
                  F : constant Natural := File_Of (S);
                  R : constant Natural := Own_Row (Color, S);
               begin
                  Has_Pawn (F) := True;
                  if R < Front_Row (F) then
                     Front_Row (F) := R;
                  end if;
               end;
               B := B and (B - 1);
            end loop;

            for F in Lo .. Hi loop
               if Has_Pawn (F) then
                  case Front_Row (F) is
                     when 1 => Result := Result + Pawn_Shield_Row1;
                     when 2 => Result := Result + Pawn_Shield_Row2;
                     when 3 => Result := Result + Pawn_Shield_Row3;
                     when others => null;
                  end case;
               else
                  Result := Result - Open_File_Near_King;
               end if;
            end loop;

            -- Advanced enemy pawns storming the wing.
            B := Position.Pieces (Make (Enemy, Pawn));
            while B /= 0 loop
               declare
                  S : constant Square_Type := Lowest_Bit (B);
                  F : constant Natural := File_Of (S);
                  R : constant Natural := Own_Row (Color, S);
               begin
                  if F in Lo .. Hi and then R in 3 .. 5 then
                     Result := Result - Pawn_Storm;
                  end if;
               end;
               B := B and (B - 1);
            end loop;
         end;
      end if;

      return Result;
   end King_Safety;

   -------------------------
   -- Positional (per side) --
   -------------------------

   -- Positional score of one side (positive for that side), split between
   -- the opening and the endgame values. Color-generic, so calling it with
   -- White then Black and subtracting stays symmetric.
   function Positional_Score (Position : in Position_Type;
                              Color    : in Color_Type;
                              Phase    : in Natural;
                              Occ      : in Bitboard) return Tapered_Score_Type
   is
      Enemy    : constant Color_Type := Opposite (Color);
      Own      : constant Bitboard := Color_Board (Position, Color);
      Free     : constant Bitboard := not Own;
      Own_Pawns   : constant Bitboard := Position.Pieces (Make (Color, Pawn));
      Enemy_Pawns : constant Bitboard := Position.Pieces (Make (Enemy, Pawn));
      Enemy_King  : constant Square_Type :=
        Lowest_Bit (Position.Pieces (Make (Enemy, King)));
      Result   : Tapered_Score_Type := (Opening => 0, End_Game => 0);
      B        : Bitboard;
   begin
      -- Bishop pair.
      if Popcount (Position.Pieces (Make (Color, Bishop))) = 2 then
         Result := Result +
           (Opening => Bishop_Pair_Opening, End_Game => Bishop_Pair_Endgame);
      end if;

      -- Mobility (and the special rook-on-7th bonus).
      for Kind in Knight .. Queen loop
         declare
            Weight : constant Score_Type :=
              (case Kind is
                  when Knight => Mobility_N,
                  when Bishop => Mobility_B,
                  when Rook   => Mobility_R,
                  when Queen  => Mobility_Q,
                  when others => 0);
         begin
            B := Position.Pieces (Make (Color, Kind));
            while B /= 0 loop
               declare
                  Sq  : constant Square_Type := Lowest_Bit (B);
                  Cnt : constant Natural :=
                    Popcount (Piece_Attacks (Kind, Sq, Occ) and Free);
               begin
                   Result := Result + Both (Weight * Score_Type (Cnt));

                   if Kind = Rook then
                      declare
                         Fm : constant Bitboard := File_Mask (File_Of (Sq));
                      begin
                         -- Open (no pawn at all) or semi-open (no friendly
                         -- pawn) file: the rook is activated.
                         if (Own_Pawns and Fm) = 0 then
                            if (Enemy_Pawns and Fm) = 0 then
                               Result := Result +
                                 (Opening => Rook_Open_File_Opening,
                                  End_Game => Rook_Open_File_Endgame);
                            else
                               Result := Result +
                                 (Opening => Rook_Semi_Open_Opening,
                                  End_Game => Rook_Semi_Open_Endgame);
                            end if;
                         end if;
                      end;

                      if Own_Row (Color, Sq) = 6 then
                         Result := Result +
                           (Opening => Rook_On_7th_Opening,
                            End_Game => Rook_On_7th_Endgame);
                         if Own_Row (Enemy, Enemy_King) <= 1 then
                            Result := Result + Both (Rook_On_7th_King);
                         end if;
                      end if;
                   end if;
               end;
               B := B and (B - 1);
            end loop;
         end;
      end loop;

      -- Pawn structure, all bitboard-wise: doubled / isolated penalties
      -- derived from per-file counts, and a passed-pawn bonus (with an
      -- extra reward when a passed pawn is connected / supported).
      declare
         Counts  : array (0 .. 7) of Natural := (others => 0);
         Passed  : Bitboard := Passed_Pawns (Position, Color);
         B2      : Bitboard := Own_Pawns;
      begin
         -- Per-file counts of friendly pawns.
         while B2 /= 0 loop
            Counts (File_Of (Lowest_Bit (B2))) :=
              Counts (File_Of (Lowest_Bit (B2))) + 1;
            B2 := B2 and (B2 - 1);
         end loop;

         -- Doubled penalty (each pawn beyond the first on its file).
         for F in 0 .. 7 loop
            if Counts (F) >= 2 then
               Result := Result +
                 (Opening => (-Doubled_Pawn_Opening)
                    * Score_Type (Counts (F) - 1),
                  End_Game => (-Doubled_Pawn_Endgame)
                    * Score_Type (Counts (F) - 1));
            end if;
         end loop;

         -- Isolated: no friendly pawn on an adjacent file.
         for F in 0 .. 7 loop
            if Counts (F) >= 1 then
               declare
                  Has_Neighbour : Boolean;
               begin
                  if F = 0 then
                     Has_Neighbour := Counts (1) > 0;
                  elsif F = 7 then
                     Has_Neighbour := Counts (6) > 0;
                  else
                     Has_Neighbour := Counts (F - 1) > 0 or Counts (F + 1) > 0;
                  end if;
                  if not Has_Neighbour then
                     Result := Result +
                       (Opening => (-Isolated_Pawn_Opening)
                          * Score_Type (Counts (F)),
                        End_Game => (-Isolated_Pawn_Endgame)
                          * Score_Type (Counts (F)));
                  end if;
               end;
            end if;
         end loop;

         -- Passed pawns: iterate the bitboard, giving the row bonus and a
         -- connected bonus when a friendly pawn stands on an adjacent file
         -- at most one rank away (they defend each other).
         while Passed /= 0 loop
            declare
               Sq  : constant Square_Type := Lowest_Bit (Passed);
               F   : constant Natural := File_Of (Sq);
               Row : constant Natural := Own_Row (Color, Sq);
               Connected : Boolean := False;
            begin
               for DF in -1 .. 1 loop
                  declare
                     NF : constant Integer := Integer (F) + DF;
                  begin
                     if DF /= 0 and then NF in 0 .. 7
                       and then Counts (NF) > 0
                     then
                        -- A friendly pawn on an adjacent file within one
                        -- rank is a supporting neighbour.
                        declare
                           NB : Bitboard :=
                             Position.Pieces (Make (Color, Pawn))
                             and File_Mask (NF);
                        begin
                           while NB /= 0 loop
                              if abs (Integer (Own_Row (Color, Lowest_Bit (NB)))
                                      - Integer (Row)) <= 1 then
                                 Connected := True;
                                 exit;
                              end if;
                              NB := NB and (NB - 1);
                           end loop;
                        end;
                     end if;
                  end;
                  exit when Connected;
               end loop;

               Result := Result +
                 (Opening => Passed_Pawn_Opening (Row),
                  End_Game => Passed_Pawn_Endgame (Row));
               if Connected then
                  Result := Result +
                    (Opening => Passed_Pawn_Opening (Row) / 2,
                     End_Game => Passed_Pawn_Endgame (Row) / 2);
               end if;
            end;
            Passed := Passed and (Passed - 1);
         end loop;
      end;

      -- King: endgame activity replaces the home-oriented PST.
      declare
         King_Sq : constant Square_Type :=
           Lowest_Bit (Position.Pieces (Make (Color, King)));
         K_Row   : constant Natural := Own_Row (Color, King_Sq);
         K_File  : constant Natural := File_Of (King_Sq);
      begin
         Result := Result +
           (Opening => 0,
            End_Game => King_End_PST (K_Row, K_File) - PST (King, Color, King_Sq));
      end;

      -- King safety (middlegame only).
      if Phase >= King_Safety_Min_Phase then
         Result := Result + Both (King_Safety (Position, Color, Occ));
      end if;

      return Result;
   end Positional_Score;

   function Static (Position : in Position_Type) return Score_Type is
      Result : Score_Type := 0;
      Phase  : constant Natural := Game_Phase (Position);
      Occ    : constant Bitboard := Occupancy (Position);
   begin
      -- Material + piece-square tables (flat, both phases).
      for Color in Color_Type loop
         declare
            Sign : constant Score_Type := (if Color = White then 1 else -1);
         begin
            for Kind in Kind_Type loop
               declare
                  Piece : constant Piece_Type := Make (Color, Kind);
                  B     : Bitboard := Position.Pieces (Piece);
               begin
                  while B /= 0 loop
                     declare
                        Sq : constant Square_Type := Lowest_Bit (B);
                     begin
                        Result := Result +
                          Sign * (Piece_Value (Kind) + PST (Kind, Color, Sq));
                     end;
                     B := B and (B - 1);
                  end loop;
               end;
            end loop;
         end;
      end loop;

      -- Positional terms, tapered by the game phase.
      declare
         White_Positional : constant Tapered_Score_Type :=
           Positional_Score (Position, White, Phase, Occ);
         Black_Positional : constant Tapered_Score_Type :=
           Positional_Score (Position, Black, Phase, Occ);
         Diff : constant Tapered_Score_Type :=
           (Opening  => White_Positional.Opening - Black_Positional.Opening,
            End_Game => White_Positional.End_Game - Black_Positional.End_Game);
      begin
         Result := Result + Blend (Diff, Phase);
      end;

      return Result;
   end Static;

   function Evaluate (Position : in Position_Type) return Score_Type is
   begin
      if Position.Side = White then
         return Static (Position);
      else
         return -Static (Position);
      end if;
   end Evaluate;

end BBChess.Eval;
