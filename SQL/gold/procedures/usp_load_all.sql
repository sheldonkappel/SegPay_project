/* =====================================================================
   Procedure : gold.usp_load_all
   Purpose   : Builds the whole gold layer from silver, in dependency
               order, under one run_id.

   Run order
   ---------
     Stage 1 - dimensions      1 dim_date            6 dim_customer
                               2 dim_merchant        7 dim_affiliate
                               3 dim_merchant_account 8 dim_card_bin
                               4 dim_site            9 dim_response_code
                               5 dim_package        10 dim_chargeback_reason
     Stage 2 - facts          11 fact_transaction   12 fact_chargeback

   Summaries (gold.agg_chargeback_monitoring) are views over the facts -
   nothing to load.

   Run silver first (EXEC silver.usp_load_all) so gold reads fresh data.
   PowerShell scripts\Load-All.ps1 -LoadGold runs bronze, silver and gold.

   Behavior
   --------
   * One run_id (GUID) for every step; each step writes its own row to
     audit.load_log, plus one run-level row for this procedure.
   * Stops at the first failed step and re-raises the error; steps already
     finished keep their data (each commits on its own).
   * Returns a run log: one row per step plus a TOTAL line.

   Usage
   -----
     EXEC gold.usp_load_all;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_all
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Steps TABLE (step_no INT NOT NULL PRIMARY KEY, stage INT NOT NULL, proc_name SYSNAME NOT NULL);

    INSERT @Steps (step_no, stage, proc_name) VALUES
        -- Stage 1: dimensions (read silver)
        ( 1, 1, N'gold.usp_load_dim_date'),
        ( 2, 1, N'gold.usp_load_dim_merchant'),
        ( 3, 1, N'gold.usp_load_dim_merchant_account'),
        ( 4, 1, N'gold.usp_load_dim_site'),
        ( 5, 1, N'gold.usp_load_dim_package'),
        ( 6, 1, N'gold.usp_load_dim_customer'),
        ( 7, 1, N'gold.usp_load_dim_affiliate'),
        ( 8, 1, N'gold.usp_load_dim_card_bin'),
        ( 9, 1, N'gold.usp_load_dim_response_code'),
        (10, 1, N'gold.usp_load_dim_chargeback_reason'),
        -- Stage 2: facts (need the dimensions)
        (11, 2, N'gold.usp_load_fact_transaction'),
        (12, 2, N'gold.usp_load_fact_chargeback');              -- reads fact_transaction

    -- Run log: one row per step, returned at the end
    DECLARE @Log TABLE (
        step_no     INT            NOT NULL,
        stage       INT            NOT NULL,
        proc_name   SYSNAME        NOT NULL,
        status      VARCHAR(10)    NOT NULL,   -- Succeeded / Failed / Skipped
        started_at  DATETIME2(0)   NULL,       -- UTC
        seconds     INT            NULL,
        error_text  NVARCHAR(4000) NULL
    );

    DECLARE @RunId    UNIQUEIDENTIFIER = NEWID(),
            @RunStart  DATETIME2(3)     = SYSUTCDATETIME(),
            @StepNo    INT,
            @StepCount INT,
            @Stage     INT,
            @Proc      SYSNAME,
            @Start     DATETIME2(3),
            @Failed    BIT = 0,
            @FailedAt  SYSNAME,
            @ErrMsg    NVARCHAR(4000),
            @Ok        INT,
            @Metrics   NVARCHAR(MAX);

    SELECT @StepCount = COUNT(*) FROM @Steps;

    DECLARE @RunIdText NVARCHAR(36) = CONVERT(NVARCHAR(36), @RunId);
    RAISERROR(N'gold.usp_load_all - run_id %s', 0, 1, @RunIdText) WITH NOWAIT;

    DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT step_no, stage, proc_name FROM @Steps ORDER BY step_no;
    OPEN step_cursor;
    FETCH NEXT FROM step_cursor INTO @StepNo, @Stage, @Proc;

    WHILE @@FETCH_STATUS = 0 AND @Failed = 0
    BEGIN
        SET @Start = SYSUTCDATETIME();
        RAISERROR(N'Step %d (stage %d): %s ...', 0, 1, @StepNo, @Stage, @Proc) WITH NOWAIT;

        BEGIN TRY
            EXEC @Proc @run_id = @RunId;

            INSERT @Log (step_no, stage, proc_name, status, started_at, seconds)
            VALUES (@StepNo, @Stage, @Proc, 'Succeeded', @Start, DATEDIFF(SECOND, @Start, SYSUTCDATETIME()));
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            SET @ErrMsg   = ERROR_MESSAGE();
            SET @Failed   = 1;
            SET @FailedAt = @Proc;
            INSERT @Log (step_no, stage, proc_name, status, started_at, seconds, error_text)
            VALUES (@StepNo, @Stage, @Proc, 'Failed', @Start, DATEDIFF(SECOND, @Start, SYSUTCDATETIME()), @ErrMsg);
        END CATCH

        FETCH NEXT FROM step_cursor INTO @StepNo, @Stage, @Proc;
    END

    CLOSE step_cursor;
    DEALLOCATE step_cursor;

    -- Steps that never ran because an earlier one failed
    INSERT @Log (step_no, stage, proc_name, status)
    SELECT s.step_no, s.stage, s.proc_name, 'Skipped'
    FROM @Steps s
    WHERE NOT EXISTS (SELECT 1 FROM @Log l WHERE l.step_no = s.step_no);

    -- Run-level row in audit.load_log (step details are in the steps' own rows)
    SELECT @Ok = COUNT(*) FROM @Log WHERE status = 'Succeeded';
    SET @Metrics = (SELECT StepsTotal = @StepCount,
                           StepsSucceeded = @Ok,
                           StepsFailed  = (SELECT COUNT(*) FROM @Log WHERE status = 'Failed'),
                           StepsSkipped = (SELECT COUNT(*) FROM @Log WHERE status = 'Skipped')
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

    DECLARE @RunStatus VARCHAR(10) = CASE WHEN @Failed = 1 THEN 'Failed' ELSE 'Succeeded' END;
    EXEC audit.usp_log_load @run_id = @RunId, @proc_name = N'gold.usp_load_all', @target_table = N'gold (all)',
         @started_at = @RunStart, @status = @RunStatus, @metrics = @Metrics, @error_message = @ErrMsg;

    -- Run log, plus a TOTAL line at the bottom
    SELECT run_id = @RunId, step_no, stage, proc_name, status, started_at, seconds, error_text
    FROM (
        SELECT step_no, stage, proc_name, status, started_at, seconds, error_text, 0 AS is_total FROM @Log
        UNION ALL
        SELECT NULL, NULL, N'TOTAL', @RunStatus, @RunStart, DATEDIFF(SECOND, @RunStart, SYSUTCDATETIME()), NULL, 1
    ) r
    ORDER BY is_total, step_no;

    IF @Failed = 1
    BEGIN
        SET @ErrMsg = N'gold.usp_load_all stopped at ' + @FailedAt + N': ' + @ErrMsg;
        THROW 50999, @ErrMsg, 1;
    END
END
GO
