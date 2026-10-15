/* =====================================================================
   Script    : deploy_tests.sql
   Purpose   : Deploys the test framework and all tests, then runs them.

   Safe to re-run: the results table is created only if missing; tests
   use CREATE OR ALTER.

   How to run (from the SQL\tests folder - :r paths are relative):
       sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_tests.sql
   Requires the bronze, silver, gold and audit layers.
   Exits with an error if any test fails.
   ===================================================================== */
:on error exit

PRINT N'1/3 Test framework';
GO
:r 00_test_framework.sql

PRINT N'2/3 Tests';
GO
:r 01_util_tests.sql
:r 02_silver_tests.sql
:r 03_gold_tests.sql
:r 04_audit_tests.sql

PRINT N'3/3 Run tests';
GO
EXEC test.usp_run_all;
GO
