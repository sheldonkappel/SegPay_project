/* =====================================================================
   Procedure : silver.usp_load_all
   Purpose   : Rebuilds the whole silver layer by running every silver load
               procedure in dependency order, under one run_id.

   Dependencies between silver tables
   ----------------------------------
       sites                      <- merchant_accounts
       conversions                <- clicks (summary check)
       transactions               <- fx_rates_daily, merchant_xref, risk_events,
                                     response_codes, sites, packages
       clearing_transactions      <- fx_rates_daily, merchant_accounts
       purchases_snapshot         <- transactions, packages
       chargebacks_acquirer_feed  <- fx_rates_daily, chargeback_reason_codes,
                                     merchant_accounts, transactions (summary check)
   Everything else reads bronze (and the ref / util objects) only.

   Run order
   ---------
     Stage 1 - bronze only
          1 merchant_accounts         6 bin_reference            11 settlements_weekly
          2 merchants_crm_export      7 response_codes           12 packages
          3 merchant_xref             8 chargeback_reason_codes  13 helpdesk_tickets
          4 affiliates                9 fx_rates_daily           14 clicks
          5 customers                10 risk_events
     Stage 2   15 sites   16 conversions
     Stage 3   17 transactions   18 clearing_transactions
     Stage 4   19 purchases_snapshot   20 chargebacks_acquirer_feed

   Behavior
   --------
   * One run_id (GUID) is created and passed to every step; each step writes
     its own row to audit.load_log, and this procedure adds a run-level row.
   * Each procedure returns its one-row summary.
   * If a step fails, the run stops there (later steps may depend on it) and
     the error is re-raised. Steps already finished keep their new data -
     each procedure commits on its own.
   * A run log (one row per step, plus a TOTAL line) is returned at the end.

   Usage
   -----
     EXEC silver.usp_load_all;

     -- History of runs:
     SELECT * FROM audit.load_log ORDER BY log_id DESC;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_all
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Steps TABLE (step_no INT NOT NULL PRIMARY KEY, stage INT NOT NULL, proc_name SYSNAME NOT NULL);

    INSERT @Steps (step_no, stage, proc_name) VALUES
        -- Stage 1: read bronze only
        ( 1, 1, N'silver.usp_load_merchant_accounts'),
        ( 2, 1, N'silver.usp_load_merchants_crm_export'),
        ( 3, 1, N'silver.usp_load_merchant_xref'),
        ( 4, 1, N'silver.usp_load_affiliates'),
        ( 5, 1, N'silver.usp_load_customers'),
        ( 6, 1, N'silver.usp_load_bin_reference'),
        ( 7, 1, N'silver.usp_load_response_codes'),
        ( 8, 1, N'silver.usp_load_chargeback_reason_codes'),
        ( 9, 1, N'silver.usp_load_fx_rates_daily'),
        (10, 1, N'silver.usp_load_risk_events'),
        (11, 1, N'silver.usp_load_settlements_weekly'),
        (12, 1, N'silver.usp_load_packages'),
        (13, 1, N'silver.usp_load_helpdesk_tickets'),
        (14, 1, N'silver.usp_load_clicks'),
        -- Stage 2
        (15, 2, N'silver.usp_load_sites'),                       -- merchant_accounts
        (16, 2, N'silver.usp_load_conversions'),                 -- clicks
        -- Stage 3
        (17, 3, N'silver.usp_load_transactions'),                -- fx, merchant_xref, risk_events, response_codes, sites, packages
        (18, 3, N'silver.usp_load_clearing_transactions'),       -- fx, merchant_accounts
        -- Stage 4
        (19, 4, N'silver.usp_load_purchases_snapshot'),          -- transactions, packages
        (20, 4, N'silver.usp_load_chargebacks_acquirer_feed');   -- fx, reason codes, merchant_accounts, transactions

    DECLARE @Log TABLE (
        step_no     INT            NOT NULL,
        stage       INT            NOT NULL,
        proc_name   SYSNAME        NOT NULL,
        status      VARCHAR(10)    NOT NULL,   -- Succeeded / Failed / Skipped
        started_at  DATETIME2(0)   NULL,       -- UTC
        seconds     INT            NULL,
        error_text  NVARCHAR(4000) NULL
    );

    DECLARE @RunId     UNIQUEIDENTIFIER = NEWID(),
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
    RAISERROR(N'silver.usp_load_all - run_id %s', 0, 1, @RunIdText) WITH NOWAIT;

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
    EXEC audit.usp_log_load @run_id = @RunId, @proc_name = N'silver.usp_load_all', @target_table = N'silver (all)',
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
        SET @ErrMsg = N'silver.usp_load_all stopped at ' + @FailedAt + N': ' + @ErrMsg;
        THROW 50999, @ErrMsg, 1;
    END
END
GO
