--
--  AdaChess-BB : move-time allocation (body)
--

package body BBChess.Clocks is

   function Exact (Move_Time : Duration) return Allocation is
      T : Duration := Move_Time;
   begin
      if T < 0.0 then
         T := 0.0;
      end if;
      return (Soft => T, Hard => T);
   end Exact;

   function Clock_Based (Clock_Left  : Duration;
                         Increment   : Duration;
                         Moves_To_Go : Natural) return Allocation is
      Inc     : Duration := Increment;
      Budget  : Duration;
      Cap     : Duration;
      Hard    : Duration;
      Reserve : constant Duration := Clock_Left - Safety_Margin;
   begin
      if Inc < 0.0 then
         Inc := 0.0;
      end if;

      if Moves_To_Go > 0 then
         --  The GUI announced the moves left in the session: spread the
         --  clock over exactly that many moves, so the fraction per move
         --  grows as the session limit approaches. The anti-spike ceiling is
         --  lifted (only the clock reserve still bounds the budget).
         Budget := Clock_Left / Duration (Moves_To_Go) + 0.75 * Inc;
         Cap := Clock_Left;
      else
         Budget := Clock_Left / Duration (Moves_To_Go_Default) + 0.75 * Inc;
         Cap := Max_Soft;
      end if;

      if Budget > Cap then
         Budget := Cap;
      end if;
      if Budget > Reserve then
         Budget := Reserve;
      end if;

      --  Hard = 2 x soft, but never past the clock reserve.
      Hard := 2.0 * Budget;
      if Hard > Reserve then
         Hard := Reserve;
      end if;
      if Hard < Budget then
         Hard := Budget;
      end if;

      --  Floor so a search always gets a usable (if tiny) budget.
      if Budget < 0.001 then
         Budget := 0.001;
      end if;
      if Hard < Budget then
         Hard := Budget;
      end if;

      return (Soft => Budget, Hard => Hard);
   end Clock_Based;

end BBChess.Clocks;
