/* =====================================================================
   Procedure : silver.usp_load_risk_events
   Source    : bronze.risk_events        (one JSON event per row)
   Targets   : silver.risk_events        (one row per event)
               silver.risk_event_rules   (one row per rule triggered by an event)
   Load type : Full refresh - both tables rebuilt in one transaction.

   Purpose
   -------
   The fraud engine scores each payment attempt (1 = low risk, 99 = high) and
   decides Approve (1-64) / Review (65-87) / Decline (88-99), listing the rules
   that fired and the signals it used.

   Engine versions handled
   -----------------------
   The engine was upgraded in February 2026 and its JSON changed. Bronze only
   has the old field names, so both versions are read from raw_json:
       2.9.1 (Oct 2024 - Jan 2026)            3.1.0 (Feb 2026 onward)
       score                                  risk_score
       rules_triggered: [{"rule_id":...,      rules: ["R130:PREPAID_BIN"]
          "rule_name":...,"weight":6}]          (no weight)
       signals.device_id                      signals.device_fp

   Transformations
   ---------------
     * event_id              : as sent (evt_...). Events without one are skipped.
     * txn_id, purchase_id   : whole numbers; txn_id NULL when the attempt never
                               became a transaction.
     * merchant_id           : trimmed and uppercased.
     * event_ts_utc          : ISO 8601 UTC -> YYYY-MM-DD hh:mm:ss.
     * risk_score            : score or risk_score.
     * decision              : Approve / Review / Decline.
     * rules_triggered_count,
       rule_ids              : how many rules fired and their IDs ('R104, R130').
     * signals               : countries uppercased; email age and velocity as
                               whole numbers; proxy as 1 / 0; device fingerprint.
                               Events without a signals block have NULL signals.
     * risk_event_rules      : rule_id, rule_name, rule_weight (NULL for 3.1.0).
     * Test data             : test merchants (ref.test_merchant) excluded.
     * Duplicates            : one row per event_id (duplicates are identical copies).
     * Missing values        : NULL.
     * Lineage               : bronze source columns, load_run_id, silver_loaded_at.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Events for old-gateway merchants name the MRC- merchant that
       silver.merchant_xref is missing (1002 -> MRC-00001, 1310 -> MRC-00148,
       1229 -> MRC-00107). silver.transactions uses this as a fallback mapping.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; test-merchant table; audit logging.

   Usage
   -----
     EXEC silver.usp_load_risk_events;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_risk_events
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.risk_events',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Invalid   INT,
            @Test      INT,
            @Loaded    INT,
            @RuleRows  INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(N'silver.risk_events', N'U') IS NULL OR OBJECT_ID(N'silver.risk_event_rules', N'U') IS NULL
            THROW 50001, N'silver.risk_events / risk_event_rules do not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze  = COUNT(*),
               @Invalid = SUM(CASE WHEN ISJSON(raw_json) = 1 THEN 0 ELSE 1 END)
        FROM bronze.risk_events;

        SELECT @Test = COUNT(*)
        FROM bronze.risk_events
        WHERE ISJSON(raw_json) = 1
          AND UPPER(TRIM(JSON_VALUE(raw_json, '$.merchant'))) IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        /* -------------------------------------------------------------
           Step 1: parse every event from raw_json (both layouts) into #e
           ------------------------------------------------------------- */
        SELECT
            TRIM(j.event_id)                                            AS event_id,
            TRY_CAST(j.txn_id AS BIGINT)                                AS txn_id,
            TRY_CAST(j.purchase_id AS BIGINT)                           AS purchase_id,
            NULLIF(UPPER(TRIM(j.merchant)), '')                         AS merchant_id,
            TRY_CONVERT(DATETIME2(0), REPLACE(LEFT(j.event_ts, 19), 'T', ' '), 120) AS event_ts_utc,
            NULLIF(TRIM(j.engine_version), '')                          AS engine_version,
            TRY_CAST(COALESCE(j.score, j.risk_score) AS SMALLINT)       AS risk_score,
            CASE UPPER(TRIM(j.decision))
                WHEN 'APPROVE' THEN 'Approve'
                WHEN 'REVIEW'  THEN 'Review'
                WHEN 'DECLINE' THEN 'Decline'
            END                                                         AS decision,
            COALESCE(j.rules_triggered, j.rules)                        AS rules_json,
            CASE WHEN UPPER(TRIM(j.ip_country))  LIKE '[A-Z][A-Z]' THEN UPPER(TRIM(j.ip_country))  END AS signal_ip_country,
            CASE WHEN UPPER(TRIM(j.bin_country)) LIKE '[A-Z][A-Z]' THEN UPPER(TRIM(j.bin_country)) END AS signal_bin_country,
            TRY_CAST(j.email_age_days AS INT)                           AS signal_email_age_days,
            TRY_CAST(j.velocity_1h AS INT)                              AS signal_velocity_1h,
            px.flag                                                     AS signal_proxy,
            NULLIF(TRIM(COALESCE(j.device_id, j.device_fp)), '')        AS signal_device_id,
            CASE WHEN j.signals IS NULL THEN 1 ELSE 0 END               AS no_signals,
            b.source_system, b.source_file_name, b.batch_id,
            b.ingested_at                                               AS bronze_ingested_at,
            b.ingested_by,
            ROW_NUMBER() OVER (PARTITION BY TRIM(j.event_id) ORDER BY b.ingested_at DESC) AS rn
        INTO #e
        FROM bronze.risk_events b
        CROSS APPLY OPENJSON(b.raw_json) WITH (
            event_id        VARCHAR(40)   '$.event_id',
            txn_id          VARCHAR(30)   '$.txn_id',
            purchase_id     VARCHAR(30)   '$.purchase_id',
            merchant        VARCHAR(30)   '$.merchant',
            event_ts        VARCHAR(40)   '$.event_ts',
            engine_version  VARCHAR(10)   '$.engine_version',
            score           VARCHAR(10)   '$.score',              -- 2.9.1
            risk_score      VARCHAR(10)   '$.risk_score',         -- 3.1.0
            decision        VARCHAR(20)   '$.decision',
            rules_triggered NVARCHAR(MAX) '$.rules_triggered' AS JSON,   -- 2.9.1
            rules           NVARCHAR(MAX) '$.rules'           AS JSON,   -- 3.1.0
            signals         NVARCHAR(MAX) '$.signals'         AS JSON,
            ip_country      VARCHAR(10)   '$.signals.ip_country',
            bin_country     VARCHAR(10)   '$.signals.bin_country',
            email_age_days  VARCHAR(20)   '$.signals.email_age_days',
            velocity_1h     VARCHAR(20)   '$.signals.velocity_1h',
            proxy           VARCHAR(10)   '$.signals.proxy',
            device_id       VARCHAR(50)   '$.signals.device_id',  -- 2.9.1
            device_fp       VARCHAR(50)   '$.signals.device_fp'   -- 3.1.0
        ) j
        CROSS APPLY util.fn_parse_flag(j.proxy) px
        WHERE ISJSON(b.raw_json) = 1
          AND NULLIF(TRIM(j.event_id), '') IS NOT NULL
          AND ISNULL(UPPER(TRIM(j.merchant)), '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        DELETE FROM #e WHERE rn > 1;

        /* -------------------------------------------------------------
           Step 2: one row per rule per event into #r
             2.9.1: {"rule_id":"R130","rule_name":"PREPAID_BIN","weight":6}
             3.1.0: "R130:PREPAID_BIN"  - split at ':'
           ------------------------------------------------------------- */
        SELECT DISTINCT
            e.event_id,
            UPPER(TRIM(COALESCE(r.rule_id,   LEFT(r.rule_text, NULLIF(CHARINDEX(':', r.rule_text), 0) - 1))))       AS rule_id,
            UPPER(TRIM(COALESCE(r.rule_name, SUBSTRING(r.rule_text, NULLIF(CHARINDEX(':', r.rule_text), 0) + 1, 100)))) AS rule_name,
            TRY_CAST(r.weight AS INT)                                   AS rule_weight,
            e.engine_version,
            e.source_file_name,
            e.batch_id
        INTO #r
        FROM #e e
        CROSS APPLY OPENJSON(e.rules_json) WITH (
            rule_id    VARCHAR(10)  '$.rule_id',
            rule_name  VARCHAR(100) '$.rule_name',
            weight     VARCHAR(10)  '$.weight',
            rule_text  VARCHAR(120) '$'
        ) r
        WHERE e.rules_json IS NOT NULL;

        DELETE FROM #r WHERE rule_id IS NULL OR rule_id = '';

        /* -------------------------------------------------------------
           Step 3: write both tables in one transaction
           ------------------------------------------------------------- */
        BEGIN TRAN;

        TRUNCATE TABLE silver.risk_event_rules;
        TRUNCATE TABLE silver.risk_events;

        INSERT silver.risk_events (
            event_id, txn_id, purchase_id, merchant_id, event_ts_utc, engine_version, risk_score,
            decision, rules_triggered_count, rule_ids, signal_ip_country, signal_bin_country,
            signal_email_age_days, signal_velocity_1h, signal_proxy, signal_device_id,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            e.event_id, e.txn_id, e.purchase_id, e.merchant_id, e.event_ts_utc, e.engine_version, e.risk_score,
            e.decision, ISNULL(rl.rule_count, 0), rl.rule_ids, e.signal_ip_country, e.signal_bin_country,
            e.signal_email_age_days, e.signal_velocity_1h, e.signal_proxy, e.signal_device_id,
            e.source_system, e.source_file_name, e.batch_id, e.bronze_ingested_at, e.ingested_by, @run_id
        FROM #e e
        OUTER APPLY (
            SELECT COUNT(*) AS rule_count,
                   STRING_AGG(r.rule_id, ', ') WITHIN GROUP (ORDER BY r.rule_id) AS rule_ids
            FROM #r r
            WHERE r.event_id = e.event_id
        ) rl;

        SET @Loaded = @@ROWCOUNT;

        INSERT silver.risk_event_rules (event_id, rule_id, rule_name, rule_weight, engine_version, source_file_name, batch_id, load_run_id)
        SELECT event_id, rule_id, NULLIF(rule_name, ''), rule_weight, engine_version, source_file_name, batch_id, @run_id
        FROM #r;

        SET @RuleRows = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows           = @Bronze,
               InvalidJsonSkipped   = @Invalid,
               TestRowsExcluded     = @Test,
               SilverEvents         = @Loaded,
               Engine291Events      = (SELECT COUNT(*) FROM #e WHERE engine_version = '2.9.1'),
               Engine310Events      = (SELECT COUNT(*) FROM #e WHERE engine_version = '3.1.0'),
               DuplicatesDropped    = @Bronze - @Invalid - @Test - @Loaded,
               RuleRows             = @RuleRows,
               EventsWithoutSignals = (SELECT SUM(no_signals) FROM #e),
               EventsWithoutTxn     = (SELECT COUNT(*) FROM #e WHERE txn_id IS NULL)
        INTO #summary;

        SET @Metrics  = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Excluded = @Test;
        SET @Dropped  = @Bronze - @Invalid - @Test - @Loaded;

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Bronze, @rows_loaded = @Loaded,
             @rows_excluded = @Excluded, @rows_dropped = @Dropped, @metrics = @Metrics;

        SELECT * FROM #summary;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Failed', @error_message = @Err;
        THROW;
    END CATCH
END
GO
