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
--    * connected rooks (defending each other on the same file/rank);
--    * pawn structure, evaluated in pure bitboard: doubled and isolated
--      pawns (from per-file popcounts) and passed pawns (front span built by
--      rank-wise propagation of the enemy pawns widened to their neighbouring
--      files), with extra bonuses for protected and outside passed pawns;
--    * king safety (pawn shelter, open files near the king, pawn storm,
--      enemy attackers around the king) - opening/middlegame only;
--    * king endgame activity (the base PST keeps the king at home in the
--      middlegame; the endgame table drives it toward the center).
--
--  Every per-side term uses only color-generic helpers, so subtracting the
--  White and Black scores keeps the tempo-free evaluation (Static) symmetric
--  and equal to 0 on the initial position. Evaluate adds the Tempo bonus for
--  the side to move, so its antisymmetry holds on Static only. Occupancy is
--  computed once per Static call and shared between both colors and the
--  king-safety term.
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

   -- Pure-bitboard helpers: shifts by one file / one rank. Board layout:
   -- square = Rank*8 + File, so +1 file = bit index +1, +1 rank = +8.
   -- Masks keep the bits from wrapping around the board edges.
   function East_1 (B : in Bitboard) return Bitboard is
     ((B and not File_Mask (7)) * 2);
   function West_1 (B : in Bitboard) return Bitboard is
     ((B and not File_Mask (0)) / 2);
   function North_1 (B : in Bitboard) return Bitboard is
     ((B and not Rank_Mask (7)) * 256);
   function South_1 (B : in Bitboard) return Bitboard is
     (B / 256);

   -- Squares that have an enemy pawn on the same or an adjacent file at any
   -- rank strictly in front of them, from the point of view of a pawn of
   -- Color. A White pawn is blocked by Black pawns standing north of it, so
   -- the enemy pawns (widened to their neighbouring files) are propagated
   -- south; symmetrically for Black. Pure bitboard, no per-pawn loop.
   function Front_Blockers (Enemy   : in Bitboard;
                            Color   : in Color_Type) return Bitboard is
      Wide : Bitboard := Enemy or East_1 (Enemy) or West_1 (Enemy);
      Res  : Bitboard := 0;
   begin
      for Step in 1 .. 7 loop
         if Color = White then
            Wide := South_1 (Wide);
         else
            Wide := North_1 (Wide);
         end if;
         Res := Res or Wide;
      end loop;
      return Res;
   end Front_Blockers;

   -- Pawns of Color that are passed: no enemy pawn on the same or adjacent
   -- files in front of them (pure bitboard front-span, no per-pawn loop).
   function Passed_Pawns (Position : in Position_Type;
                          Color    : in Color_Type) return Bitboard is
      Own   : constant Bitboard := Position.Pieces (Make (Color, Pawn));
      Enemy : constant Bitboard :=
        Position.Pieces (Make (Opposite (Color), Pawn));
   begin
      return Own and not Front_Blockers (Enemy, Color);
   end Passed_Pawns;

   -- True when a friendly pawn of Color defends Square. A pawn defends the
   -- two squares diagonally in front of it, so the defenders of Square stand
   -- one rank behind it on the adjacent files (Square - 9 / - 7 for White,
   -- Square + 7 / + 9 for Black).
   function Defended_By_Pawn (Position : in Position_Type;
                              Color    : in Color_Type;
                              Square   : in Square_Type) return Boolean is
      Def1, Def2 : Integer;
      F1, F2     : Integer;
   begin
      if Color = White then
         Def1 := Integer (Square) - 9;
         Def2 := Integer (Square) - 7;
      else
         Def1 := Integer (Square) + 7;
         Def2 := Integer (Square) + 9;
      end if;
      if Def1 not in Square_Type then
         return Def2 in Square_Type
           and then (Position.Pieces (Make (Color, Pawn))
                     and Bit (Square_Type (Def2))) /= 0;
      end if;
      F1 := Integer (File_Of (Square_Type (Def1)));
      F2 := Integer (File_Of (Square_Type (Def2)));
      -- Def1 / Def2 are on the adjacent files only when they did not wrap
      -- around a rank edge: check the file differs by exactly 1.
      if abs (F1 - Integer (File_Of (Square))) = 1 then
         if (Position.Pieces (Make (Color, Pawn))
             and Bit (Square_Type (Def1))) /= 0 then
            return True;
         end if;
      end if;
      if Def2 in Square_Type
        and then abs (F2 - Integer (File_Of (Square))) = 1
      then
         return (Position.Pieces (Make (Color, Pawn))
                 and Bit (Square_Type (Def2))) /= 0;
      end if;
      return False;
   end Defended_By_Pawn;

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

   -- Flat (piece, square) table combining material and PST, precomputed at
   -- elaboration so the hot material loop is a single lookup per piece.
   type Piece_Square_Table is array (Piece_Type, Square_Type) of Score_Type;
   Material_PST : Piece_Square_Table := (others => (others => 0));

   -- King-attack zones indexed by king square: the squares at king distance
   -- 1 (including the king square itself) and 2, precomputed to avoid the
   -- per-call expansion in King_Safety.
   Near_Zone : array (Square_Type) of Bitboard := (others => 0);
   Far_Zone  : array (Square_Type) of Bitboard := (others => 0);

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

   -- Two rooks defending each other (same file or rank, line clear).
   Rook_Connected_Opening : constant Score_Type := 10;
   Rook_Connected_Endgame : constant Score_Type := 14;

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

   -- Extra bonus (fraction of the row bonus) for a passed pawn that is
   -- defended by a friendly pawn ("protected" passed pawn).
   Protected_Passed_Opening : constant Score_Type := 40;
   Protected_Passed_Endgame : constant Score_Type := 50;
   -- "Outside" passed pawn: far from the enemy king (useful to deflect it).
   Outside_Passed_Opening    : constant Score_Type := 10;
   Outside_Passed_Endgame    : constant Score_Type := 15;
   -- Minimum file distance from the enemy king to count as "outside".
   Outside_Passed_Distance   : constant := 2;

   -- King safety.
   Pawn_Shield_Row1      : constant Score_Type := 8;
   Pawn_Shield_Row2      : constant Score_Type := 6;
   Pawn_Shield_Row3      : constant Score_Type := 3;
   Open_File_Near_King   : constant Score_Type := 10;
   Pawn_Storm            : constant Score_Type := 3;
   King_Attack_Knight    : constant Score_Type := 10;
   King_Attack_Bishop    : constant Score_Type := 10;
   King_Attack_Rook      : constant Score_Type := 16;
   King_Attack_Queen     : constant Score_Type := 24;
   -- Penalty when the king has left its back rank in the middlegame (it is
   -- then much easier to expose to an attack).
   Exposed_King          : constant Score_Type := 28;
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
      -- The king square itself is included so that a direct check counts.
      Near     : constant Bitboard := Near_Zone (King_Sq);
      Far      : constant Bitboard := Far_Zone (King_Sq);
      Near_Danger : Score_Type := 0;
      Far_Danger  : Score_Type := 0;
      Attackers   : Natural := 0;
      Result    : Score_Type := 0;
      Lo, Hi   : Integer;
      B        : Bitboard;
   begin
      -- Weighted enemy attackers aiming at the king's square or the squares
      -- around it. The danger is applied non-linearly (a coordinated attack
      -- by several pieces is much worse than the sum of the attackers).
      for Kind in Knight .. Queen loop
         declare
            W : constant Score_Type :=
              (case Kind is
                  when Knight => King_Attack_Knight,
                  when Bishop => King_Attack_Bishop,
                  when Rook   => King_Attack_Rook,
                  when Queen  => King_Attack_Queen,
                  when others => 0);
            Pieces : Bitboard := Position.Pieces (Make (Enemy, Kind));
         begin
            while Pieces /= 0 loop
               declare
                  Sq  : constant Square_Type := Lowest_Bit (Pieces);
                  Att : constant Bitboard := Piece_Attacks (Kind, Sq, Occ);
               begin
                  if (Att and Near) /= 0 then
                     Attackers := Attackers + 1;
                     Near_Danger := Near_Danger + W;
                  elsif (Att and Far) /= 0 then
                     Far_Danger := Far_Danger + W / 2;
                  end if;
               end;
               Pieces := Pieces and (Pieces - 1);
            end loop;
         end;
      end loop;
      Result := Result
        - (Near_Danger * Score_Type (Attackers + 1)) / 2
        - Far_Danger;

      -- A king that has left its back rank is exposed.
      if Own_Row (Color, King_Sq) > 0 then
         Result := Result - Exposed_King;
      end if;

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

      -- Connected rooks: when a rook is defended by a friendly rook (same
      -- file or rank with a clear line), both gain a small bonus.
      declare
         RR : Bitboard := Position.Pieces (Make (Color, Rook));
         R1 : Square_Type;
      begin
         if Popcount (RR) = 2 then
            R1 := Lowest_Bit (RR);
            RR := RR and (RR - 1);
            if (Rook_Attacks (R1, Occ) and RR) /= 0 then
               Result := Result +
                 (Opening => Rook_Connected_Opening,
                  End_Game => Rook_Connected_Endgame);
            end if;
         end if;
      end;

      -- Pawn structure, pure bitboard: per-file counts derived from masks
      -- (doubled / isolated penalties), and a passed-pawn bonus read from
      -- the front-span bitboard, with an extra reward when the passed pawn
      -- is defended by a friendly pawn ("protected") or far from the enemy
      -- king ("outside", good to deflect it in king-pawn endgames).
      declare
         Passed : constant Bitboard := Passed_Pawns (Position, Color);
         PB     : Bitboard;
      begin
         -- Doubled penalty and isolation, driven by per-file counts.
         for F in 0 .. 7 loop
            declare
               Cnt : constant Natural :=
                 Popcount (Own_Pawns and File_Mask (F));
            begin
               if Cnt >= 2 then
                  Result := Result +
                    (Opening => (-Doubled_Pawn_Opening)
                       * Score_Type (Cnt - 1),
                     End_Game => (-Doubled_Pawn_Endgame)
                       * Score_Type (Cnt - 1));
               end if;

               if Cnt >= 1 then
                  declare
                     Adj : Bitboard := 0;
                  begin
                     if F > 0 then
                        Adj := Adj or File_Mask (F - 1);
                     end if;
                     if F < 7 then
                        Adj := Adj or File_Mask (F + 1);
                     end if;
                     if (Own_Pawns and Adj) = 0 then
                        Result := Result +
                          (Opening => (-Isolated_Pawn_Opening)
                             * Score_Type (Cnt),
                           End_Game => (-Isolated_Pawn_Endgame)
                             * Score_Type (Cnt));
                     end if;
                  end;
               end if;
            end;
         end loop;

         -- Passed pawns: iterate the front-span bitboard for the row bonus.
         PB := Passed;
         while PB /= 0 loop
            declare
               Sq      : constant Square_Type := Lowest_Bit (PB);
               F       : constant Natural := File_Of (Sq);
               Row     : constant Natural := Own_Row (Color, Sq);
               Defended_Pawn : constant Boolean :=
                 Defended_By_Pawn (Position, Color, Sq);
               Outside_Pawn  : constant Boolean :=
                 abs (Integer (F) - Integer (File_Of (Enemy_King)))
                 >= Outside_Passed_Distance;
            begin
               Result := Result +
                 (Opening => Passed_Pawn_Opening (Row),
                  End_Game => Passed_Pawn_Endgame (Row));
               if Defended_Pawn then
                  Result := Result +
                    (Opening => Passed_Pawn_Opening (Row)
                       * Protected_Passed_Opening / 100,
                     End_Game => Passed_Pawn_Endgame (Row)
                       * Protected_Passed_Endgame / 100);
               end if;
               if Outside_Pawn then
                  Result := Result +
                    (Opening => Outside_Passed_Opening,
                     End_Game => Outside_Passed_Endgame);
               end if;
            end;
            PB := PB and (PB - 1);
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
                        Result := Result + Sign * Material_PST (Piece, Sq);
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
      -- Static from the side to move's point of view, plus the tempo bonus
      -- for having the move (helps to avoid zugzwang artifacts).
      if Position.Side = White then
         return Static (Position) + Tempo;
      else
         return -Static (Position) + Tempo;
      end if;
   end Evaluate;

begin
   -- Precompute the flat material+PST table.
   for P in Piece_Type loop
      for S in Square_Type loop
         Material_PST (P, S) :=
           Piece_Value (Kind (P)) + PST (Kind (P), Color (P), S);
      end loop;
   end loop;

   -- Precompute the king near/far attack zones.
   for S in Square_Type loop
      Near_Zone (S) := King_Attacks (S) or Bit (S);
      declare
         X : Bitboard := Near_Zone (S);
         F : Bitboard := 0;
      begin
         while X /= 0 loop
            F := F or King_Attacks (Lowest_Bit (X));
            X := X and (X - 1);
         end loop;
         Far_Zone (S) := F and not Near_Zone (S);
      end;
   end loop;
end BBChess.Eval;
