--
--  AdaChess-BB : self tests
--
--  Smoke, perft (CPW oracle) and search sanity checks. Run the engine with
--  "--selftest" to execute them.
--

package BBChess.Self_Tests is

   procedure Run;
   -- Run every test; raises Program_Error on the first failure.

end BBChess.Self_Tests;
