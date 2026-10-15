/* =====================================================================
   Script    : 00_test_framework.sql
   Purpose   : A small test framework for the warehouse.
               Safe to re-run: the results table is created only if missing;
               procedures use CREATE OR ALTER.

   How it works
   ------------
   * A test is a stored procedure in the test schema named
         test.usp_test_<area>_<name>      e.g. test.usp_test_gold_reconcile_transactions
     <area> is util, bronze, silver, gold or audit.
   * A test passes if it finishes without an error. It fails by raising an
     error that says what is wrong - use the assert procedures below, which
     raise error numbers 50100-50199 ("Failed"). Any other error (a typo, a
     missing table) is reported as "Error".
   * test.usp_run_all runs every test (or one area), each inside a
     transaction that is always rolled back, so a test can never change
     data. Every result is written to audit.test_result. If any test did
     not pass, it then raises an error listing them, so callers
     (Load-All.ps1, a scheduler) see the run as failed.

   Usage
   -----
     EXEC test.usp_run_all;                          -- all tests
     EXEC test.usp_run_all @area = N'gold';          -- one area
     EXEC test.usp_run_all @fail_on_error = 0;       -- report only, never raise
     EXEC test.usp_test_gold_merchant_history;       -- a single test
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF SCHEMA_ID(N'test')  IS NULL EXEC (N'CREATE SCHEMA test');
IF SCHEMA_ID(N'audit') IS NULL EXEC (N'CREATE SCHEMA audit');
GO

/* ---------------------------------------------------------------------
   audit.test_result - one row per test per run
   --------------------------------------------------------------------- */
IF OBJECT_ID(N'audit.test_result', N'U') IS NULL
    CREATE TABLE audit.test_result (
        result_id    BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_test_result PRIMARY KEY,
        run_id       UNIQUEIDENTIFIER NOT NULL,       -- same for every test in one usp_run_all call
        test_name    SYSNAME          NOT NULL,       -- e.g. usp_test_gold_reconcile_transactions
        area         VARCHAR(20)      NOT NULL,       -- util / silver / gold / audit
        status       VARCHAR(10)      NOT NULL,       -- Passed / Failed / Error
        message      NVARCHAR(4000)   NULL,           -- why it failed
        duration_ms  INT              NOT NULL,
        run_at       DATETIME2(3)     NOT NULL CONSTRAINT DF_audit_test_result_run_at DEFAULT SYSUTCDATETIME(),  -- UTC
        run_by       NVARCHAR(128)    NOT NULL CONSTRAINT DF_audit_test_result_run_by DEFAULT ORIGINAL_LOGIN()
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_test_result_run' AND object_id = OBJECT_ID(N'audit.test_result'))
    CREATE INDEX IX_audit_test_result_run ON audit.test_result (run_id) INCLUDE (status);
GO

/* ---------------------------------------------------------------------
   Asserts
   --------------------------------------------------------------------- */
-- Fails unless @actual = 0. @what describes what was counted ("transactions with a negative sale amount").
CREATE OR ALTER PROCEDURE test.usp_assert_zero
    @actual  BIGINT,
    @what    NVARCHAR(1000),
    @details NVARCHAR(2000) = NULL      -- e.g. examples of the offending rows
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(@actual, 0) <> 0
    BEGIN
        DECLARE @msg NVARCHAR(2048) = LEFT(CONCAT(N'Expected 0 ', @what, N', found ', FORMAT(@actual, N'N0'), N'.',
                                                  N' ' + @details), 2048);
        THROW 50100, @msg, 1;
    END
END
GO

-- Fails unless @expected = @actual (NULL equals NULL). Works for numbers, dates and text.
-- Pass both values as the same kind of type: a DATE never equals the text '2025-03-04'.
CREATE OR ALTER PROCEDURE test.usp_assert_equal
    @expected SQL_VARIANT,
    @actual   SQL_VARIANT,
    @what     NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT (@expected = @actual OR (@expected IS NULL AND @actual IS NULL))
    BEGIN
        DECLARE @msg NVARCHAR(2048) = LEFT(CONCAT(@what, N': expected ', ISNULL(CONVERT(NVARCHAR(200), @expected), N'NULL'),
                                                  N', found ', ISNULL(CONVERT(NVARCHAR(200), @actual), N'NULL'), N'.'), 2048);
        THROW 50101, @msg, 1;
    END
END
GO

/* ---------------------------------------------------------------------
   test.usp_run_all
   --------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE test.usp_run_all
    @area          VARCHAR(20) = NULL,   -- util / bronze / silver / gold / audit; NULL = all
    @fail_on_error BIT         = 1       -- 1 = raise an error if any test did not pass
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;                   -- let each test's error be caught and recorded

    DECLARE @run_id UNIQUEIDENTIFIER = NEWID(),
            @name   SYSNAME,
            @t_area VARCHAR(20),
            @status VARCHAR(10),
            @msg    NVARCHAR(4000),
            @start  DATETIME2(3),
            @sql    NVARCHAR(400);

    DECLARE tests CURSOR LOCAL FAST_FORWARD FOR
        SELECT p.name,
               LEFT(SUBSTRING(p.name, 10, 100), CHARINDEX(N'_', SUBSTRING(p.name, 10, 100) + N'_') - 1)
        FROM sys.procedures p
        WHERE p.schema_id = SCHEMA_ID(N'test')
          AND p.name LIKE N'usp[_]test[_]%[_]%'
        ORDER BY CASE LEFT(SUBSTRING(p.name, 10, 100), CHARINDEX(N'_', SUBSTRING(p.name, 10, 100) + N'_') - 1)
                      WHEN 'util' THEN 1 WHEN 'bronze' THEN 2 WHEN 'silver' THEN 3 WHEN 'gold' THEN 4 WHEN 'audit' THEN 5 ELSE 6 END,
                 p.name;

    OPEN tests;
    FETCH NEXT FROM tests INTO @name, @t_area;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @area IS NULL OR @t_area = @area
        BEGIN
            SELECT @start = SYSUTCDATETIME(), @status = 'Passed', @msg = NULL,
                   @sql = N'EXEC test.' + QUOTENAME(@name) + N';';
            BEGIN TRY
                BEGIN TRAN;
                EXEC sys.sp_executesql @sql;
                ROLLBACK;                                   -- tests never keep changes
            END TRY
            BEGIN CATCH
                IF @@TRANCOUNT > 0 ROLLBACK;
                SELECT @status = CASE WHEN ERROR_NUMBER() BETWEEN 50100 AND 50199 THEN 'Failed' ELSE 'Error' END,
                       @msg    = ERROR_MESSAGE();
            END CATCH;

            INSERT audit.test_result (run_id, test_name, area, status, message, duration_ms)
            VALUES (@run_id, @name, @t_area, @status, @msg, DATEDIFF(MILLISECOND, @start, SYSUTCDATETIME()));
        END
        FETCH NEXT FROM tests INTO @name, @t_area;
    END
    CLOSE tests;
    DEALLOCATE tests;

    -- Results, then a one-row summary (the last result set - Load-All.ps1 reads it)
    SELECT area, test_name, status, duration_ms, message
    FROM audit.test_result WHERE run_id = @run_id ORDER BY result_id;

    DECLARE @total INT, @passed INT, @not_passed NVARCHAR(3000);
    SELECT @total  = COUNT(*),
           @passed = SUM(CASE WHEN status = 'Passed' THEN 1 ELSE 0 END)
    FROM audit.test_result WHERE run_id = @run_id;

    SELECT @not_passed = STRING_AGG(CAST(test_name AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY result_id)
    FROM audit.test_result WHERE run_id = @run_id AND status <> 'Passed';

    SELECT run_id = @run_id, tests = @total, passed = @passed, not_passed = @total - @passed,
           status = CASE WHEN @total = 0 THEN 'No tests' WHEN @passed = @total THEN 'Passed' ELSE 'Failed' END;

    IF @fail_on_error = 1 AND @passed < @total
    BEGIN
        SET @msg = LEFT(CONCAT(@total - @passed, N' of ', @total, N' tests did not pass: ', @not_passed,
                               N'. Details: SELECT * FROM audit.test_result WHERE run_id = ''', CONVERT(NVARCHAR(36), @run_id), N''';'), 2048);
        THROW 50199, @msg, 1;
    END
END
GO
