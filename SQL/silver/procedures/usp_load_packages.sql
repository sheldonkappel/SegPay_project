/* =====================================================================
   Procedure : silver.usp_load_packages
   Source    : bronze.packages   (raw text)
   Target    : silver.packages   (cleaned, one row per package)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A package is a price point a site sells: a one-time purchase, a recurring
   membership, or a trial that turns into a recurring membership. Each
   package belongs to one site.

   Key terms
   ---------
   Billing model : One-Time (charged once) / Recurring (same price every
                   rebill period) / Trial (cheap or free trial, then rebills).
   Rebill period : days between renewals (30 / 90 / 365).

   Transformations
   ---------------
     * package_id, site_id : whole numbers. Rows without a package_id are skipped.
     * package_name        : trimmed.
     * billing_model       : 11 spellings -> One-Time / Recurring / Trial.
     * initial_price,
       rebill_price        : util.fn_parse_amount ('$' removed, decimal comma
                             '9,00' -> 9.00); 2 decimals.
     * currency            : 3-letter code, uppercased.
     * trial_days          : whole number.
     * rebill_period_days  : 30d / monthly / 3 months / yearly ... -> 30 / 90 / 365.
     * status              : title case (Active / Retired).
     * created_date,
       updated_date        : any supported format (util.fn_parse_date); slash
                             dates US month/day first.
     * Test data           : packages on test sites (ref.v_test_site) excluded.
     * Duplicates          : one row per package_id - latest updated_date, then
                             newest bronze load.
     * Missing values      : NULL.
     * Lineage             : bronze source columns, load_run_id, silver_loaded_at.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * 47 packages have a created or updated date in the future.
     * 7 packages have updated_date before created_date; each involves a slash
       date valid both ways (the source mixes US and day-first). Kept as US.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date / amount functions and
                 test-site view; audit logging.

   Usage
   -----
     EXEC silver.usp_load_packages;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_packages
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.packages',
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
            THROW 50001, N'silver.packages does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.packages;

        SELECT @Test = COUNT(*)
        FROM bronze.packages b
        WHERE TRY_CAST(TRIM(b.site_id) AS INT) IN (SELECT ts.site_id FROM ref.v_test_site ts);

        BEGIN TRAN;

        TRUNCATE TABLE silver.packages;

        WITH s AS (
            SELECT
                TRY_CAST(TRIM(b.package_id) AS INT)                    AS package_id,
                x.site_id,
                NULLIF(TRIM(b.package_name), '')                       AS package_name,

                -- Billing model: key with spaces, '-', '_', '+' and '>' removed
                CASE x.model_key
                    WHEN 'recurring'      THEN 'Recurring'
                    WHEN 'subscription'   THEN 'Recurring'
                    WHEN 'trial'          THEN 'Trial'
                    WHEN 'trialrecurring' THEN 'Trial'      -- Trial>Recurring, TRIAL_RECURRING
                    WHEN 'trialrebill'    THEN 'Trial'      -- TRIAL+REBILL
                    WHEN 'onetime'        THEN 'One-Time'
                    WHEN 'ot'             THEN 'One-Time'
                END                                                    AS billing_model,

                CAST(ip.amount AS DECIMAL(12,2))                       AS initial_price,
                CASE WHEN UPPER(TRIM(b.currency)) LIKE '[A-Z][A-Z][A-Z]' THEN UPPER(TRIM(b.currency)) END AS currency,
                TRY_CAST(TRIM(b.trial_days) AS INT)                    AS trial_days,
                CAST(rp.amount AS DECIMAL(12,2))                       AS rebill_price,

                CASE
                    WHEN x.period_key IN ('30', '30d', '30days', 'monthly', 'month', '1month')               THEN 30
                    WHEN x.period_key IN ('90', '90d', '90days', 'quarterly', 'quarter', '3months')          THEN 90
                    WHEN x.period_key IN ('365', '365d', '365days', 'annual', 'annually', 'yearly', '1year') THEN 365
                END                                                    AS rebill_period_days,

                CASE WHEN x.status_key IS NOT NULL
                     THEN UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50) END AS status,

                cd.date_us_first                                       AS created_date,
                ud.date_us_first                                       AS updated_date,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.packages b
            CROSS APPLY (
                SELECT
                    site_id    = TRY_CAST(TRIM(b.site_id) AS INT),
                    model_key  = LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.billing_model), ' ', ''), '-', ''), '_', ''), '+', ''), '>', '')),
                    period_key = LOWER(REPLACE(TRIM(b.rebill_period), ' ', '')),
                    status_key = NULLIF(LOWER(TRIM(b.status)), '')
            ) x
            CROSS APPLY util.fn_parse_amount(b.initial_price) ip
            CROSS APPLY util.fn_parse_amount(b.rebill_price)  rp
            CROSS APPLY util.fn_parse_date(b.created_date)    cd
            CROSS APPLY util.fn_parse_date(b.updated_date)    ud
            WHERE NOT EXISTS (SELECT 1 FROM ref.v_test_site ts WHERE ts.site_id = x.site_id)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY package_id ORDER BY updated_date DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE package_id IS NOT NULL
        )
        INSERT silver.packages (
            package_id, site_id, package_name, billing_model, initial_price, currency, trial_days,
            rebill_price, rebill_period_days, status, created_date, updated_date,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT package_id, site_id, package_name, billing_model, initial_price, currency, trial_days,
               rebill_price, rebill_period_days, status, created_date, updated_date,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows            = @Bronze,
               TestRowsExcluded      = @Test,
               SilverRows            = @Loaded,
               DuplicatesDropped     = @Bronze - @Test - @Loaded,
               BillingModelMissing   = (SELECT COUNT(*) FROM silver.packages WHERE billing_model IS NULL),
               InitialPriceMissing   = (SELECT COUNT(*) FROM silver.packages WHERE initial_price IS NULL),
               CurrencyMissing       = (SELECT COUNT(*) FROM silver.packages WHERE currency IS NULL),
               DateMissing           = (SELECT COUNT(*) FROM silver.packages WHERE created_date IS NULL OR updated_date IS NULL),
               FutureDated           = (SELECT COUNT(*) FROM silver.packages
                                        WHERE created_date > CAST(SYSUTCDATETIME() AS DATE) OR updated_date > CAST(SYSUTCDATETIME() AS DATE))
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
