/* =====================================================================
   Procedure : silver.usp_load_settlements_weekly
   Source    : bronze.settlements_weekly   (raw text, finance export)
   Target    : silver.settlements_weekly   (cleaned, one row per settlement - latest version)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A settlement is the weekly statement of what SegPay pays a merchant for
   one Monday-Sunday period:
       net_payout = gross_sales + refunds (negative) - chargebacks - fees_total
                    - reserve_held + reserve_released + adjustments
   A settlement can be reissued with a higher version (e.g. after a fee
   recalculation); silver keeps the latest version.

   Transformations
   ---------------
     * settlement_id     : trimmed and uppercased (STL-YYYYMMDD-NNNNN; the date
                           is the period start).
     * merchant_id       : trimmed and uppercased.
     * period_start,
       period_end,
       payout_date       : util.fn_parse_date. A slash date valid both ways is
                           resolved against the settlement_id date:
                             period_start = ID date, period_end = ID date + 6,
                             payout_date  = 1-14 days after period_end
                           otherwise US month/day.
     * amounts           : util.fn_parse_amount ('$1,671.14' -> 1671.14,
                           '(0.99)' -> -0.99); 2 decimals. refunds stored as
                           negative (the source mixes signs; the formula only
                           holds with refunds as a deduction).
     * currency          : uppercased.
     * payout_status     : Paid (incl. Complete) / Pending / Scheduled / Held
                           (incl. On Hold) / Failed / Returned (incl. Returned by bank).
     * adjustment_note,
       bank_ref          : trimmed.
     * version           : whole number.
     * payout_reconciles : 1 when net_payout equals the formula (within 2 cents).
     * created_ts        : YYYY-MM-DD hh:mm:ss.
     * Test data         : test merchants (ref.test_merchant) excluded.
     * Duplicates        : one row per settlement - highest version, then latest
                           created_ts, then newest bronze load.
     * Missing values    : NULL.
     * Lineage           : bronze source columns, load_run_id, silver_loaded_at.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * ~40 settlements have a net_payout that does not match its components
       (payout_reconciles = 0); kept as sent.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date / amount functions and
                 test-merchant table; audit logging.

   Usage
   -----
     EXEC silver.usp_load_settlements_weekly;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_settlements_weekly
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.settlements_weekly',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Test      INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.settlements_weekly does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.settlements_weekly;

        SELECT @Test = COUNT(*)
        FROM bronze.settlements_weekly
        WHERE UPPER(TRIM(merchant_id)) IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        BEGIN TRAN;

        TRUNCATE TABLE silver.settlements_weekly;

        WITH s AS (
            SELECT
                x.settlement_id,
                NULLIF(UPPER(TRIM(b.merchant_id)), '')                 AS merchant_id,

                -- Period start: an ambiguous slash date takes the reading equal to the ID date
                COALESCE(ps.fixed_date,
                    CASE WHEN ps.dm_date = x.id_date AND ps.us_date <> x.id_date THEN ps.dm_date
                         ELSE COALESCE(ps.us_date, ps.dm_date) END)    AS period_start,

                -- Period end: the reading equal to ID date + 6
                COALESCE(pe.fixed_date,
                    CASE WHEN pe.dm_date = DATEADD(DAY, 6, x.id_date) AND pe.us_date <> DATEADD(DAY, 6, x.id_date) THEN pe.dm_date
                         ELSE COALESCE(pe.us_date, pe.dm_date) END)    AS period_end,

                CASE WHEN UPPER(TRIM(b.currency)) LIKE '[A-Z][A-Z][A-Z]' THEN UPPER(TRIM(b.currency)) END AS currency,

                CAST(gs.amount AS DECIMAL(18,2))                       AS gross_sales,
                CAST(-ABS(rf.amount) AS DECIMAL(18,2))                 AS refunds,       -- always a deduction
                CAST(cb.amount AS DECIMAL(18,2))                       AS chargebacks,
                CAST(fe.amount AS DECIMAL(18,2))                       AS fees_total,
                CAST(rh.amount AS DECIMAL(18,2))                       AS reserve_held,
                CAST(rr.amount AS DECIMAL(18,2))                       AS reserve_released,
                CAST(ad.amount AS DECIMAL(18,2))                       AS adjustments,
                NULLIF(TRIM(b.adjustment_note), '')                    AS adjustment_note,
                CAST(np.amount AS DECIMAL(18,2))                       AS net_payout,

                CAST(CASE WHEN ABS(gs.amount - ABS(rf.amount) - cb.amount - fe.amount - rh.amount
                                   + rr.amount + ad.amount - np.amount) <= 0.02 THEN 1
                          WHEN np.amount IS NOT NULL THEN 0 END AS BIT) AS payout_reconciles,

                -- Payout date: an ambiguous slash date takes the reading 1-14 days after the period end
                COALESCE(pd.fixed_date,
                    CASE WHEN DATEDIFF(DAY, DATEADD(DAY, 6, x.id_date), pd.dm_date) BETWEEN 1 AND 14
                          AND NOT DATEDIFF(DAY, DATEADD(DAY, 6, x.id_date), pd.us_date) BETWEEN 1 AND 14
                         THEN pd.dm_date
                         ELSE COALESCE(pd.us_date, pd.dm_date) END)    AS payout_date,

                CASE UPPER(TRIM(b.payout_status))
                    WHEN 'PAID'             THEN 'Paid'
                    WHEN 'COMPLETE'         THEN 'Paid'
                    WHEN 'PENDING'          THEN 'Pending'
                    WHEN 'SCHEDULED'        THEN 'Scheduled'
                    WHEN 'HELD'             THEN 'Held'
                    WHEN 'ON HOLD'          THEN 'Held'
                    WHEN 'FAILED'           THEN 'Failed'
                    WHEN 'RETURNED'         THEN 'Returned'
                    WHEN 'RETURNED BY BANK' THEN 'Returned'
                END                                                    AS payout_status,

                NULLIF(UPPER(TRIM(b.bank_ref)), '')                    AS bank_ref,
                TRY_CAST(TRIM(b.version) AS INT)                       AS version,
                TRY_CONVERT(DATETIME2(0), LEFT(TRIM(b.created_ts), 19), 120) AS created_ts,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.settlements_weekly b
            CROSS APPLY (
                SELECT settlement_id = NULLIF(UPPER(TRIM(b.settlement_id)), ''),
                       id_date       = TRY_CONVERT(DATE, SUBSTRING(TRIM(b.settlement_id), 5, 8), 112)  -- STL-20240930-... -> 2024-09-30
            ) x
            CROSS APPLY util.fn_parse_date(b.period_start)       ps
            CROSS APPLY util.fn_parse_date(b.period_end)         pe
            CROSS APPLY util.fn_parse_date(b.payout_date)        pd
            CROSS APPLY util.fn_parse_amount(b.gross_sales)      gs
            CROSS APPLY util.fn_parse_amount(b.refunds)          rf
            CROSS APPLY util.fn_parse_amount(b.chargebacks)      cb
            CROSS APPLY util.fn_parse_amount(b.fees_total)       fe
            CROSS APPLY util.fn_parse_amount(b.reserve_held)     rh
            CROSS APPLY util.fn_parse_amount(b.reserve_released) rr
            CROSS APPLY util.fn_parse_amount(b.adjustments)      ad
            CROSS APPLY util.fn_parse_amount(b.net_payout)       np
            WHERE ISNULL(UPPER(TRIM(b.merchant_id)), '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY settlement_id
                                         ORDER BY version DESC, created_ts DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE settlement_id IS NOT NULL
        )
        INSERT silver.settlements_weekly (
            settlement_id, merchant_id, period_start, period_end, currency, gross_sales, refunds,
            chargebacks, fees_total, reserve_held, reserve_released, adjustments, adjustment_note,
            net_payout, payout_reconciles, payout_date, payout_status, bank_ref, version, created_ts,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            settlement_id, merchant_id, period_start, period_end, currency, gross_sales, refunds,
            chargebacks, fees_total, reserve_held, reserve_released, adjustments, adjustment_note,
            net_payout, payout_reconciles, payout_date, payout_status, bank_ref, version, created_ts,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows             = @Bronze,
               TestRowsExcluded       = @Test,
               SilverRows             = @Loaded,
               OlderVersionsDropped   = @Bronze - @Test - @Loaded,
               ReissuedSettlements    = (SELECT COUNT(*) FROM silver.settlements_weekly WHERE version > 1),
               PayoutNotReconciling   = (SELECT COUNT(*) FROM silver.settlements_weekly WHERE payout_reconciles = 0),
               PeriodDateMissing      = (SELECT COUNT(*) FROM silver.settlements_weekly WHERE period_start IS NULL OR period_end IS NULL)
        INTO #summary;

        SET @Metrics  = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Excluded = @Test;
        SET @Dropped  = @Bronze - @Test - @Loaded;

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
