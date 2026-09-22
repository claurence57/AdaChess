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

with Ada.Characters.Handling;

with BBChess.Tunable;

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

   --  Squares on a given "own row" (see the PST row convention), used by the
   --  king-safety pawn shield: own rows 1..3 correspond to rank 1..3 for
   --  White and rank 6..4 for Black. Home_Row_Mask is own row 0 (a pawn on
   --  the back rank is the frontmost and suppresses any shield bonus).
   Shield_Row_Mask : constant array (Color_Type, 1 .. 3) of Bitboard :=
     (White => (Rank_Mask (1), Rank_Mask (2), Rank_Mask (3)),
      Black => (Rank_Mask (6), Rank_Mask (5), Rank_Mask (4)));
   Home_Row_Mask : constant array (Color_Type) of Bitboard :=
     (White => Rank_Mask (0), Black => Rank_Mask (7));

   --  Squares on own rows 3..5 (the zone from which an enemy pawn "storms"
   --  the king's wing).
   Storm_Mask : constant array (Color_Type) of Bitboard :=
     (White => Rank_Mask (3) or Rank_Mask (4) or Rank_Mask (5),
      Black => Rank_Mask (2) or Rank_Mask (3) or Rank_Mask (4));

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
   begin
      -- Union of the shifted copies of Wide over 1 .. 7 ranks, built by a
      -- logarithmic (Kogge-Stone) fill instead of seven sequential shifts:
      -- the doubling shifts 1, 2, 4 ranks cover every distance up to 7, and
      -- the final one-rank shift drops the unshifted copy. The OR of shifted
      -- sets is exact, so the result equals the former loop's.
      if Color = White then
         Wide := Wide or South_1 (Wide);
         Wide := Wide or (Wide / 65536);
         Wide := Wide or (Wide / 4294967296);
         return South_1 (Wide);
      else
         Wide := Wide or North_1 (Wide);
         Wide := Wide or (Wide * 65536);
         Wide := Wide or (Wide * 4294967296);
         return North_1 (Wide);
      end if;
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

   -- Union of the attack squares of every pawn in Pawns, computed with two
   -- bulk shifts instead of one Pawn_Attacks lookup per pawn. A White pawn
   -- on S attacks S+7 (file-1) and S+9 (file+1); the file-A / file-H masks
   -- drop the shifts that would wrap around the board edge. The result is
   -- exactly the OR of the per-pawn attacks.
   function Pawn_Attack_Set (Pawns : in Bitboard;
                             Color : in Color_Type) return Bitboard is
   begin
      if Color = White then
         return ((Pawns and not File_A_BB) * 128)
                or ((Pawns and not File_H_BB) * 512);
      else
         return ((Pawns and not File_A_BB) / 512)
                or ((Pawns and not File_H_BB) / 128);
      end if;
   end Pawn_Attack_Set;
   pragma Inline (Pawn_Attack_Set);

   -- True when a friendly pawn of Color defends Square. A pawn of Color
   -- standing on X attacks Square exactly when X is a square from which a
   -- pawn of the opposite color on Square would attack, i.e. the reverse
   -- attack relation Pawn_Attacks (Opposite (Color), Square).
   function Defended_By_Pawn (Position : in Position_Type;
                              Color    : in Color_Type;
                              Square   : in Square_Type) return Boolean is
   begin
      return (Pawn_Attacks (Opposite (Color), Square)
              and Position.Pieces (Make (Color, Pawn))) /= 0;
   end Defended_By_Pawn;
   pragma Inline (Defended_By_Pawn);

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

   -- Tunable evaluation parameters (see the renames further down and the
   -- Set_Param / Load_Params / Dump_Params interface).
   type Param_Id is
     (P_Pawn, P_Knight, P_Bishop, P_Rook, P_Queen,
      P_Bishop_Pair_Op, P_Bishop_Pair_Eg,
      P_Mobility_N, P_Mobility_B, P_Mobility_R, P_Mobility_Q,
      P_Rook7_Op, P_Rook7_Eg, P_Rook7_King,
      P_RookOpen_Op, P_RookOpen_Eg, P_RookSemi_Op, P_RookSemi_Eg,
      P_RookConn_Op, P_RookConn_Eg,
      P_Doubled_Op, P_Doubled_Eg, P_Isolated_Op, P_Isolated_Eg,
      P_Protected_Op, P_Protected_Eg, P_Outside_Op, P_Outside_Eg,
      P_Shield1, P_Shield2, P_Shield3, P_OpenFile, P_Storm,
      P_Atk_N, P_Atk_B, P_Atk_R, P_Atk_Q, P_Exposed,
      P_Threat_Pawn, P_Threat_Minor);

   type Param_Array is array (Param_Id) of Integer;
   Params : Param_Array :=
     (P_Pawn            => 100,
      P_Knight          => 320,
      P_Bishop          => 330,
      P_Rook            => 500,
      P_Queen           => 900,
      P_Bishop_Pair_Op  => 20,
      P_Bishop_Pair_Eg  => 45,
      P_Mobility_N      => 4,
      P_Mobility_B      => 4,
      P_Mobility_R      => 2,
      P_Mobility_Q      => 1,
      P_Rook7_Op        => 15,
      P_Rook7_Eg        => 35,
      P_Rook7_King      => 25,
      P_RookOpen_Op     => 22,
      P_RookOpen_Eg     => 16,
      P_RookSemi_Op     => 10,
      P_RookSemi_Eg     => 6,
      P_RookConn_Op     => 10,
      P_RookConn_Eg     => 14,
      P_Doubled_Op      => 8,
      P_Doubled_Eg      => 5,
      P_Isolated_Op     => 10,
      P_Isolated_Eg     => 12,
      P_Protected_Op    => 40,
      P_Protected_Eg    => 50,
      P_Outside_Op      => 10,
      P_Outside_Eg      => 15,
      P_Shield1         => 8,
      P_Shield2         => 6,
      P_Shield3         => 3,
      P_OpenFile        => 10,
      P_Storm           => 3,
      P_Atk_N           => 10,
      P_Atk_B           => 10,
      P_Atk_R           => 16,
     P_Atk_Q           => 24,
     P_Exposed         => 28,
     P_Threat_Pawn     => 15,
     P_Threat_Minor    => 10);

   function Piece_Value (Kind : in Kind_Type) return Score_Type is
   begin
      case Kind is
         when Pawn   => return Score_Type (Params (P_Pawn));
         when Knight => return Score_Type (Params (P_Knight));
         when Bishop => return Score_Type (Params (P_Bishop));
         when Rook   => return Score_Type (Params (P_Rook));
         when Queen  => return Score_Type (Params (P_Queen));
         when King   => return 0;
      end case;
   end Piece_Value;
   pragma Inline (Piece_Value);

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
   pragma Inline (PST);

   -- Flat (piece, square) table combining material and PST, precomputed at
   -- elaboration so the hot material loop is a single lookup per piece.
   type Piece_Square_Table is array (Piece_Type, Square_Type) of Score_Type;
   Material_PST : Piece_Square_Table := (others => (others => 0));

   -- King-attack zones indexed by king square: the squares at king distance
   -- 1 (including the king square itself) and 2, precomputed to avoid the
   -- per-call expansion in King_Safety.
   Near_Zone : array (Square_Type) of Bitboard := (others => 0);
   Far_Zone  : array (Square_Type) of Bitboard := (others => 0);

   -- Rebuild the flat material+PST table after a piece value changed.
   procedure Rebuild_Material_PST is
   begin
      for P in Piece_Type loop
         for S in Square_Type loop
            Material_PST (P, S) :=
              Piece_Value (Kind (P)) + PST (Kind (P), Color (P), S);
         end loop;
      end loop;
   end Rebuild_Material_PST;

   procedure Set_Param (Name : in String; Value : in Integer) is
      use Ada.Characters.Handling;
      U : constant String := To_Upper (Name);
   begin
      for Id in Param_Id loop
         if U = Param_Id'Image (Id) then
            Params (Id) := Value;
            if Id in P_Pawn | P_Knight | P_Bishop | P_Rook | P_Queen then
               Rebuild_Material_PST;
            end if;
            return;
         end if;
      end loop;
   end Set_Param;

   -- Real parameters do not exist on the evaluation side: the shared file
   -- loader offers a fractional token here, and it is ignored exactly as the
   -- historical Constraint_Error guard did.
   procedure Set_Real_Param (Name : in String; Value : in Float) is
      pragma Unreferenced (Name, Value);
   begin
      null;
   end Set_Real_Param;

   procedure Load_Params_File is new BBChess.Tunable.Load_File
     (Set_Integer => Set_Param,
      Set_Real    => Set_Real_Param);

   procedure Load_Params (File_Name : in String) is
   begin
      Load_Params_File (File_Name);
      Rebuild_Material_PST;
   end Load_Params;

   procedure Dump_Params is
   begin
      for Id in Param_Id loop
         BBChess.Tunable.Put (Param_Id'Image (Id), Params (Id));
      end loop;
   end Dump_Params;

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
   pragma Inline (Own_Row);

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
   pragma Inline (Piece_Attacks);

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
   pragma Inline (Both);

   function "+" (L, R : in Tapered_Score_Type) return Tapered_Score_Type is
     ((L.Opening + R.Opening, L.End_Game + R.End_Game));
   pragma Inline ("+");

   function Blend (Score : in Tapered_Score_Type; Phase : in Natural)
     return Score_Type is
   begin
      return (Score.Opening * Phase + Score.End_Game * (100 - Phase)) / 100;
   end Blend;
   pragma Inline (Blend);

   -- Game phase from the remaining material (0 = pure endgame,
   -- 100 = full opening). Mirrors the classic phase count.
   function Game_Phase (Position : in Position_Type) return Natural is
      P : Natural;
   begin
      -- Both colors share each kind so a single popcount per kind is enough
      -- (the white and black bitboards are disjoint): one popcount instead of
      -- two added.
      P := 4 * Popcount (Position.Pieces (White_Knight)
                         or Position.Pieces (Black_Knight));
      P := P + 4 * Popcount (Position.Pieces (White_Bishop)
                             or Position.Pieces (Black_Bishop));
      P := P + 9 * Popcount (Position.Pieces (White_Rook)
                             or Position.Pieces (Black_Rook));
      P := P + 16 * Popcount (Position.Pieces (White_Queen)
                              or Position.Pieces (Black_Queen));
      if P > 100 then
         P := 100;
      end if;
      return P;
   end Game_Phase;

   --------------------------
   -- Tunable parameters --
   --------------------------

   -- Every scalar evaluation constant is held in Params so that the
   -- automatic tuner can adjust it at run time. The named constants below
   -- are renames, so the rest of the evaluation is unchanged.
   Bishop_Pair_Opening : Score_Type renames Params (P_Bishop_Pair_Op);
   Bishop_Pair_Endgame : Score_Type renames Params (P_Bishop_Pair_Eg);

   -- Mobility: centipawns per attacked (reachable) square, per piece kind.
   Mobility_N : Score_Type renames Params (P_Mobility_N);
   Mobility_B : Score_Type renames Params (P_Mobility_B);
   Mobility_R : Score_Type renames Params (P_Mobility_R);
   Mobility_Q : Score_Type renames Params (P_Mobility_Q);

   Rook_On_7th_Opening : Score_Type renames Params (P_Rook7_Op);
   Rook_On_7th_Endgame : Score_Type renames Params (P_Rook7_Eg);
   Rook_On_7th_King    : Score_Type renames Params (P_Rook7_King);

   Rook_Open_File_Opening    : Score_Type renames Params (P_RookOpen_Op);
   Rook_Open_File_Endgame    : Score_Type renames Params (P_RookOpen_Eg);
   Rook_Semi_Open_Opening    : Score_Type renames Params (P_RookSemi_Op);
   Rook_Semi_Open_Endgame    : Score_Type renames Params (P_RookSemi_Eg);

   Rook_Connected_Opening : Score_Type renames Params (P_RookConn_Op);
   Rook_Connected_Endgame : Score_Type renames Params (P_RookConn_Eg);

   Doubled_Pawn_Opening : Score_Type renames Params (P_Doubled_Op);
   Doubled_Pawn_Endgame : Score_Type renames Params (P_Doubled_Eg);
   Isolated_Pawn_Opening : Score_Type renames Params (P_Isolated_Op);
   Isolated_Pawn_Endgame : Score_Type renames Params (P_Isolated_Eg);

   -- Passed pawn bonus indexed by the pawn "own row" (0 = back rank).
   -- Row 0 and 7 are unreachable for a pawn, hence 0.
   Passed_Pawn_Opening : constant array (Natural range 0 .. 7) of Score_Type :=
     (0, 5, 8, 12, 16, 22, 30, 0);
   Passed_Pawn_Endgame : constant array (Natural range 0 .. 7) of Score_Type :=
     (0, 12, 22, 38, 60, 90, 130, 0);

   Protected_Passed_Opening : Score_Type renames Params (P_Protected_Op);
   Protected_Passed_Endgame : Score_Type renames Params (P_Protected_Eg);
   Outside_Passed_Opening    : Score_Type renames Params (P_Outside_Op);
   Outside_Passed_Endgame    : Score_Type renames Params (P_Outside_Eg);
   Outside_Passed_Distance   : constant := 2;

   -- King safety.
   Pawn_Shield_Row1      : Score_Type renames Params (P_Shield1);
   Pawn_Shield_Row2      : Score_Type renames Params (P_Shield2);
   Pawn_Shield_Row3      : Score_Type renames Params (P_Shield3);
   Open_File_Near_King   : Score_Type renames Params (P_OpenFile);
   Pawn_Storm            : Score_Type renames Params (P_Storm);
   King_Attack_Knight    : Score_Type renames Params (P_Atk_N);
   King_Attack_Bishop    : Score_Type renames Params (P_Atk_B);
   King_Attack_Rook      : Score_Type renames Params (P_Atk_R);
   King_Attack_Queen     : Score_Type renames Params (P_Atk_Q);
   Exposed_King          : Score_Type renames Params (P_Exposed);
   Threat_Pawn           : Score_Type renames Params (P_Threat_Pawn);
   Threat_Minor          : Score_Type renames Params (P_Threat_Minor);
   King_Safety_Min_Phase : constant Natural := 20;

   --------------------
   -- King safety --
   --------------------

   -- Opening/middlegame safety of Color's king. Positive when the king is
   -- well sheltered, negative when it is exposed / under attack.
   --
   -- The weighted enemy attackers aiming at the king's square and its
   -- neighbourhood (Near_Danger / Far_Danger / Attackers) are supplied by
   -- the caller: Positional_Score of the *enemy* color already computes the
   -- exact same Piece_Attacks sets for its mobility term, so accumulating
   -- the king danger there and passing it here avoids a second scan of the
   -- board (the sums are identical, so the score is unchanged).
   function King_Safety (Position : in Position_Type;
                          Color    : in Color_Type;
                          Near_Danger : in Score_Type;
                          Far_Danger  : in Score_Type;
                          Attackers   : in Natural) return Score_Type
   is
      Enemy    : constant Color_Type := Opposite (Color);
      King_Sq  : constant Square_Type :=
        Lowest_Bit (Position.Pieces (Make (Color, King)));
      King_File : constant Natural := File_Of (King_Sq);
      Result    : Score_Type := 0;
      Lo, Hi   : Integer;
   begin
      -- The danger is applied non-linearly (a coordinated attack by several
      -- pieces is much worse than the sum of the attackers).
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
            -- Only the king's wing files are inspected below, so the pawn
            -- scans can be restricted to those files (same result).
            Wing : constant Bitboard :=
              (if Lo = 0
               then File_Mask (0) or File_Mask (1) or File_Mask (2)
               else File_Mask (5) or File_Mask (6) or File_Mask (7));
            Own_Wing : constant Bitboard :=
              Position.Pieces (Make (Color, Pawn)) and Wing;
         begin
            -- Pawn shield per wing file: the frontmost pawn's own row (the
            -- minimum over the file) decides the bonus. Rows 1..3 are tested
            -- from the front; a pawn on own row 0 suppresses the bonus and
            -- rows 4..7 earn none, matching the former minimum scan. A file
            -- without any own pawn is open.
            for F in Lo .. Hi loop
               declare
                  Pf : constant Bitboard := Own_Wing and File_Mask (F);
               begin
                  if Pf = 0 then
                     Result := Result - Open_File_Near_King;
                  elsif (Pf and Home_Row_Mask (Color)) = 0 then
                     if (Pf and Shield_Row_Mask (Color, 1)) /= 0 then
                        Result := Result + Pawn_Shield_Row1;
                     elsif (Pf and Shield_Row_Mask (Color, 2)) /= 0 then
                        Result := Result + Pawn_Shield_Row2;
                     elsif (Pf and Shield_Row_Mask (Color, 3)) /= 0 then
                        Result := Result + Pawn_Shield_Row3;
                     end if;
                  end if;
               end;
            end loop;

            -- Advanced enemy pawns storming the wing. Every square of Wing
            -- lies in the king's file range, so only the rank test remains.
            -- Each storming pawn subtracts Pawn_Storm, which is a plain
            -- popcount of the enemy pawns on the wing's storm rows.
            declare
               Stormers : constant Natural :=
                 Popcount (Position.Pieces (Make (Enemy, Pawn))
                           and Wing and Storm_Mask (Color));
            begin
               if Stormers /= 0 then
                  Result := Result
                    - Pawn_Storm * Score_Type (Stormers);
               end if;
            end;
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
                               Occ      : in Bitboard;
                               Near_Danger : out Score_Type;
                               Far_Danger  : out Score_Type;
                               Attackers   : out Natural)
     return Tapered_Score_Type
   is
      Enemy    : constant Color_Type := Opposite (Color);
      Own      : constant Bitboard := Color_Board (Position, Color);
      Free     : constant Bitboard := not Own;
      Own_Pawns   : constant Bitboard := Position.Pieces (Make (Color, Pawn));
      Enemy_Pawns : constant Bitboard := Position.Pieces (Make (Enemy, Pawn));
      Enemy_Non_Pawn : constant Bitboard :=
        Position.Pieces (Make (Enemy, Knight))
        or Position.Pieces (Make (Enemy, Bishop))
        or Position.Pieces (Make (Enemy, Rook))
        or Position.Pieces (Make (Enemy, Queen));
      Enemy_King  : constant Square_Type :=
        Lowest_Bit (Position.Pieces (Make (Enemy, King)));
      -- Enemy rooks/queens: used by the minor-piece threat bonus, computed
      -- below from the same attack sets as the mobility term.
      Majors : constant Bitboard :=
        Position.Pieces (Make (Enemy, Rook))
        or Position.Pieces (Make (Enemy, Queen));
      -- The king square itself is included so that a direct check counts.
      Near     : constant Bitboard := Near_Zone (Enemy_King);
      Far      : constant Bitboard := Far_Zone (Enemy_King);
      Result   : Tapered_Score_Type := (Opening => 0, End_Game => 0);
   begin
      -- Enemy-king danger posed by Color's pieces, accumulated below along
      -- the mobility loop (same attack sets) and consumed by the enemy's
      -- King_Safety term in Static.
      Near_Danger := 0;
      Far_Danger  := 0;
      Attackers   := 0;

      -- Bishop pair.
      if Popcount (Position.Pieces (Make (Color, Bishop))) = 2 then
         Result := Result +
           (Opening => Bishop_Pair_Opening, End_Game => Bishop_Pair_Endgame);
      end if;

      -- Mobility (and the special rook-on-7th bonus). Split into one inlined
      -- body per kind so that Piece_Attacks and the (loop-invariant) weights
      -- see a literal Kind and constant-fold; the emitted move scores and the
      -- accumulation order are unchanged.
      declare
         procedure Mobility_Of (Kind          : in Kind_Type;
                                Weight        : in Score_Type;
                                Attack_Weight : in Score_Type) is
            Pieces_Here : Bitboard := Position.Pieces (Make (Color, Kind));
         begin
            while Pieces_Here /= 0 loop
               declare
                  Sq  : constant Square_Type := Lowest_Bit (Pieces_Here);
                  A   : constant Bitboard := Piece_Attacks (Kind, Sq, Occ);
               begin
                  Result := Result +
                    Both (Weight * Score_Type (Popcount (A and Free)));

                  -- Weighted attacker of the enemy king (mirrors the old
                  -- King_Safety scan, now sharing this attack set).
                  if (A and Near) /= 0 then
                     Attackers := Attackers + 1;
                     Near_Danger := Near_Danger + Attack_Weight;
                  elsif (A and Far) /= 0 then
                     Far_Danger := Far_Danger + Attack_Weight / 2;
                  end if;

                  -- Minor-piece threat: a knight/bishop attacking an enemy
                  -- rook or queen (same attack set as the mobility term).
                  if Kind in Knight | Bishop then
                     declare
                        Hit : Bitboard := A and Majors;
                     begin
                        while Hit /= 0 loop
                           declare
                              Sq2 : constant Square_Type := Lowest_Bit (Hit);
                              Pc  : Piece_Type;
                           begin
                              if Piece_At (Position, Sq2, Pc) then
                                 Result := Result +
                                   Both (Threat_Minor
                                         * Piece_Value
                                             (BBChess.Pieces.Kind (Pc)) / 100);
                              end if;
                           end;
                           Hit := Hit and (Hit - 1);
                        end loop;
                     end;
                  end if;

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
               Pieces_Here := Pieces_Here and (Pieces_Here - 1);
            end loop;
         end Mobility_Of;
         pragma Inline (Mobility_Of);
      begin
         Mobility_Of (Knight, Mobility_N, King_Attack_Knight);
         Mobility_Of (Bishop, Mobility_B, King_Attack_Bishop);
         Mobility_Of (Rook,   Mobility_R, King_Attack_Rook);
         Mobility_Of (Queen,  Mobility_Q, King_Attack_Queen);
      end;

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
         -- Per-file presence collapse: OR the eight ranks of each file into
         -- the low byte (square = Rank*8+File, so a right shift by 8*k brings
         -- rank r to r-k). Bit f is set iff the file holds at least one own
         -- pawn. This replaces the former eight per-file popcounts.
         Files_Byte : Bitboard;
         Num_Files  : Natural;
         Iso_Files  : Bitboard;
         Iso_Mask   : Bitboard;
      begin
         Files_Byte := Own_Pawns or (Own_Pawns / 256);
         Files_Byte := Files_Byte or (Files_Byte / 65536);
         Files_Byte := Files_Byte or (Files_Byte / 4294967296);
         Files_Byte := Files_Byte and 16#FF#;
         Num_Files := Popcount (Files_Byte);

         -- Doubled penalty: sum over files of max (Cnt - 1, 0) is the total
         -- pawn count minus the number of occupied files (linear in Cnt, so
         -- hoisting it out of the eight-file loop is exact).
         declare
            Doubled : constant Natural := Popcount (Own_Pawns) - Num_Files;
         begin
            if Doubled /= 0 then
               Result := Result +
                 (Opening => (-Doubled_Pawn_Opening) * Score_Type (Doubled),
                  End_Game => (-Doubled_Pawn_Endgame) * Score_Type (Doubled));
            end if;
         end;

         -- Isolated pawns: files whose own pawns have no neighbour-file pawn.
         -- Shifting the presence byte produces the neighbour mask; expanding
         -- each isolated file bit to its full column then counts them with a
         -- single popcount (the multiplication cannot carry: the set bits of
         -- the constant and the byte value occupy distinct file positions).
         Iso_Files := Files_Byte
           and not (Files_Byte * 2 or Files_Byte / 2) and 16#FF#;
         if Iso_Files /= 0 then
            Iso_Mask := Iso_Files * 16#0101010101010101#;
            declare
               Isolated : constant Natural :=
                 Popcount (Own_Pawns and Iso_Mask);
            begin
               if Isolated /= 0 then
                  Result := Result +
                    (Opening => (-Isolated_Pawn_Opening)
                       * Score_Type (Isolated),
                     End_Game => (-Isolated_Pawn_Endgame)
                       * Score_Type (Isolated));
               end if;
            end;
         end if;

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

      -- Threats: pawns attacking enemy pieces, and minor pieces attacking
      -- enemy rooks/queens. Computed per color and mirrored, so symmetric.
      -- The pawn attack set is the union of the attack squares of all the
      -- side's pawns: one bulk pair of shifts instead of a per-pawn loop.
      declare
         P_Att : constant Bitboard := Pawn_Attack_Set (Own_Pawns, Color);
         Hit : Bitboard := P_Att and Enemy_Non_Pawn;
      begin
         while Hit /= 0 loop
            declare
               Sq : constant Square_Type := Lowest_Bit (Hit);
               Pc : Piece_Type;
            begin
               if Piece_At (Position, Sq, Pc) then
                  Result := Result +
                    Both (Threat_Pawn * Piece_Value (Kind (Pc)) / 100);
               end if;
            end;
            Hit := Hit and (Hit - 1);
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

      -- King safety (middlegame only) is applied by Static, which has the
      -- enemy-king danger produced by this color's mobility scan above.

      return Result;
   end Positional_Score;

   function Static (Position : in Position_Type) return Score_Type is
      Result : Score_Type := 0;
      Phase  : constant Natural := Game_Phase (Position);
      Occ    : constant Bitboard := Occupancy (Position);
      -- Danger each color's pieces pose to the enemy king, collected while
      -- the mobility term computes their attack sets (see Positional_Score).
      W_Near, W_Far : Score_Type;
      W_Att         : Natural;
      B_Near, B_Far : Score_Type;
      B_Att         : Natural;
   begin
      -- Material + piece-square tables: maintained incrementally by
      -- Make_Move / Unmake_Move (White-positive).
      Result := Position.Material;

      -- Positional terms, tapered by the game phase.
      declare
         White_Positional : Tapered_Score_Type :=
           Positional_Score (Position, White, Occ, W_Near, W_Far, W_Att);
         Black_Positional : Tapered_Score_Type :=
           Positional_Score (Position, Black, Occ, B_Near, B_Far, B_Att);
         Diff : Tapered_Score_Type;
      begin
         -- King safety (middlegame only), per color. It must be folded into
         -- the per-color tapered scores *before* the single Blend below:
         -- splitting the division would change the truncation of negative
         -- intermediate sums. Each term is flat (equal opening / endgame
         -- values), so folding Both(KS) here is the previous arithmetic.
         if Phase >= King_Safety_Min_Phase then
            declare
               KS_W : constant Score_Type :=
                 King_Safety (Position, White, B_Near, B_Far, B_Att);
               KS_B : constant Score_Type :=
                 King_Safety (Position, Black, W_Near, W_Far, W_Att);
            begin
               White_Positional := White_Positional + Both (KS_W);
               Black_Positional := Black_Positional + Both (KS_B);
            end;
         end if;

         Diff :=
           (Opening  => White_Positional.Opening - Black_Positional.Opening,
            End_Game => White_Positional.End_Game - Black_Positional.End_Game);
         Result := Result + Blend (Diff, Phase);
      end;

      return Result;
   end Static;

   function Material_PST_Value (Piece  : in Piece_Type;
                                Square : in Square_Type) return Integer is
   begin
      return Material_PST (Piece, Square);
   end Material_PST_Value;

   function Compute_Material (Position : in Position_Type) return Integer is
      Total : Integer := 0;
   begin
      for P in Piece_Type loop
         declare
            Sign : constant Integer := (if Color (P) = White then 1 else -1);
            B    : Bitboard := Position.Pieces (P);
         begin
            while B /= 0 loop
               Total := Total + Sign * Material_PST (P, Lowest_Bit (B));
               B := B and (B - 1);
            end loop;
         end;
      end loop;
      return Total;
   end Compute_Material;

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
   Rebuild_Material_PST;

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
