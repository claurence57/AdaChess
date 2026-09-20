--
--  AdaChess-BB : move-time allocation (soft/hard split)
--
--  Pure arithmetic, kept out of the protocol driver so that the self-test can
--  exercise it directly. BBChess.Search then uses the two limits as follows:
--  the hard limit is the deadline polled every 1024 nodes (a started iteration
--  may not run past it), while the soft limit is only checked between
--  iterations -- the search starts no new iteration once the soft limit is
--  reached or when the elapsed time plus a conservative estimate of the next
--  iteration clearly overshoots it.
--

package BBChess.Clocks is
   pragma Pure;

   --  A move budget has two limits: the iterative deepening aims to stay
   --  under Soft across iterations, while an iteration already started is
   --  allowed to run up to Hard -- never more.
   type Allocation is record
      Soft : Duration := 0.0;
      Hard : Duration := 0.0;
   end record;

   --  Fraction of the remaining clock reserved at all times, so the engine
   --  never plays a move with an empty clock (GUI latency, final I/O).
   Safety_Margin : constant Duration := 0.1;

   --  No allocation may exceed this many seconds when the number of moves to
   --  go is unknown (anti-spike guard); an explicit "movestogo" / "level"
   --  count lifts the ceiling.
   Max_Soft : constant Duration := 2.0;

   --  Estimated moves to go when the GUI does not provide one.
   Moves_To_Go_Default : constant := 30;

   --  Exact budget ("st" / UCI movetime): soft = hard = the requested time.
   --  The caller asked for exactly this, so no clock reserve is applied.
   function Exact (Move_Time : Duration) return Allocation;

   --  Clock-based budget.
   --    Clock_Left  remaining time of the engine (seconds, > 0)
   --    Increment   per-move increment (seconds)
   --    Moves_To_Go 0 = unknown (use Moves_To_Go_Default), else the value
   --                announced by the GUI ("movestogo" / "level" moves).
   function Clock_Based (Clock_Left  : Duration;
                         Increment   : Duration;
                         Moves_To_Go : Natural) return Allocation;

end BBChess.Clocks;
