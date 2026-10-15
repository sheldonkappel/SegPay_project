/* =====================================================================
   Procedure : silver.usp_load_clearing_transactions
   Source    : bronze.clearing_transactions   (raw text, acquirer clearing files)
   Target    : silver.clearing_transactions   (cleaned, one row per ARN)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Clearing is the acquirer's record of each card sale it settled, with the
   interchange fee paid to the card issuer. Used to reconcile what was
   authorized (silver.transactions) with what was cleared, and to link
   chargebacks (by ARN) to the original sale.

   Key terms
   ---------
   ARN          : Acquirer Reference Number - unique per cleared item.
   Interchange  : fee paid to the card issuer on each sale.
   Minor units  : amounts in the smallest currency unit (cents): 2995 = 29.95.

   Transformations
   ---------------
     * arn              : trimmed. Rows without one are skipped.
     * acquirer         : one name per acquirer via ref.acquirer_alias.
     * batch_period     : valid YYYY-MM only.
     * batch_item_count : whole number.
     * mid              : trimmed; merchant_id from silver.merchant_accounts.
     * auth_date,
       clear_date       : any supported format (util.fn_parse_date).
     * amount, interchange : converted to major units - is_minor_unit 'Y'
                          divides by 10^exponent (2 for most currencies, 0 for
                          JPY/KRW, 3 for KWD/BHD); 'N' used as is; anything
                          else -> NULL (unit unknown, not guessed).
     * amount_usd,
       interchange_usd  : most recent US Treasury rate on or before auth_date;
                          USD unchanged; no rate -> NULL.
     * Test data        : items on test merchants' accounts excluded.
     * Duplicates       : one row per ARN - the newest bronze load wins.
     * Missing values   : NULL.
     * Lineage          : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; merchant_id added; shared date and
                 acquirer lookups; test-merchant rule; audit logging.

   Usage
   -----
     EXEC silver.usp_load_clearing_transactions;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_clearing_transactions
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.clearing_transactions',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Test      INT,
            @UnitNA    INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.clearing_transactions does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*),
               @UnitNA = SUM(CASE WHEN ISNULL(UPPER(TRIM(is_minor_unit)), '') NOT IN ('Y', 'N') THEN 1 ELSE 0 END)
        FROM bronze.clearing_transactions;

        SELECT @Test = COUNT(*)
        FROM bronze.clearing_transactions b
        JOIN silver.merchant_accounts ma ON ma.mid = TRIM(b.mid)
        WHERE ma.merchant_id IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        SELECT currency, rate_date, usd_per_unit
        INTO #fx
        FROM silver.fx_rates_daily;
        CREATE CLUSTERED INDEX CX_fx ON #fx (currency, rate_date);

        BEGIN TRAN;

        TRUNCATE TABLE silver.clearing_transactions;

        WITH c AS (
            SELECT
                b.*,
                x.ccy                                                  AS currency_clean,
                ad.date_us_first                                       AS auth_date_clean,
                -- Amounts in major units: minor -> divide by 10^exponent; unknown unit -> NULL
                CASE UPPER(TRIM(b.is_minor_unit))
                    WHEN 'Y' THEN TRY_CAST(TRIM(b.amount) AS DECIMAL(18,4)) / POWER(CAST(10 AS DECIMAL(18,4)), x.exponent)
                    WHEN 'N' THEN TRY_CAST(TRIM(b.amount) AS DECIMAL(18,4))
                END                                                    AS amount_major,
                CASE UPPER(TRIM(b.is_minor_unit))
                    WHEN 'Y' THEN TRY_CAST(TRIM(b.interchange) AS DECIMAL(18,4)) / POWER(CAST(10 AS DECIMAL(18,4)), x.exponent)
                    WHEN 'N' THEN TRY_CAST(TRIM(b.interchange) AS DECIMAL(18,4))
                END                                                    AS interchange_major
            FROM bronze.clearing_transactions b
            CROSS APPLY (
                SELECT ccy      = UPPER(TRIM(b.currency_code)),
                       -- ISO 4217 minor-unit exponent
                       exponent = CASE UPPER(TRIM(b.currency_code))
                                      WHEN 'JPY' THEN 0 WHEN 'KRW' THEN 0
                                      WHEN 'KWD' THEN 3 WHEN 'BHD' THEN 3
                                      ELSE 2 END
            ) x
            CROSS APPLY util.fn_parse_date(b.auth_date) ad
        ),
        s AS (
            SELECT
                NULLIF(TRIM(c.arn), '')                                AS arn,
                COALESCE(aq.acquirer, NULLIF(TRIM(c.acquirer), ''))    AS acquirer,
                CASE WHEN TRIM(c.batch_period) LIKE '[12][0-9][0-9][0-9]-[01][0-9]' THEN TRIM(c.batch_period) END AS batch_period,
                TRY_CAST(TRIM(c.batch_item_count) AS INT)              AS batch_item_count,
                NULLIF(TRIM(c.mid), '')                                AS mid,
                ma.merchant_id,
                c.auth_date_clean                                      AS auth_date,
                cd.date_us_first                                       AS clear_date,
                NULLIF(TRIM(c.bin), '')                                AS bin,
                NULLIF(TRIM(c.last4), '')                              AS last4,
                CASE WHEN c.currency_clean LIKE '[A-Z][A-Z][A-Z]' THEN c.currency_clean END AS currency_code,
                CAST(ROUND(c.amount_major, 2)      AS DECIMAL(18,2))   AS amount,
                CAST(ROUND(c.interchange_major, 4) AS DECIMAL(18,4))   AS interchange,
                CASE WHEN c.currency_clean = 'USD' THEN CAST(ROUND(c.amount_major, 2) AS DECIMAL(18,2))
                     ELSE CAST(ROUND(c.amount_major * r.usd_per_unit, 2) AS DECIMAL(18,2)) END AS amount_usd,
                CASE WHEN c.currency_clean = 'USD' THEN CAST(ROUND(c.interchange_major, 4) AS DECIMAL(18,4))
                     ELSE CAST(ROUND(c.interchange_major * r.usd_per_unit, 4) AS DECIMAL(18,4)) END AS interchange_usd,
                r.usd_per_unit                                         AS fx_rate,
                r.rate_date                                            AS fx_rate_date,
                c.source_system, c.source_file_name, c.batch_id,
                c.ingested_at                                          AS bronze_ingested_at,
                c.ingested_by
            FROM c
            CROSS APPLY util.fn_parse_date(c.clear_date) cd
            LEFT JOIN ref.acquirer_alias aq        ON aq.alias = UPPER(REPLACE(TRIM(c.acquirer), ' ', ''))
            LEFT JOIN silver.merchant_accounts ma  ON ma.mid = NULLIF(TRIM(c.mid), '')
            OUTER APPLY (
                SELECT TOP (1) f.usd_per_unit, f.rate_date
                FROM #fx f
                WHERE c.currency_clean <> 'USD'
                  AND f.currency  = c.currency_clean
                  AND f.rate_date <= c.auth_date_clean
                ORDER BY f.rate_date DESC
            ) r
            WHERE ISNULL(ma.merchant_id, '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY arn ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE arn IS NOT NULL
        )
        INSERT silver.clearing_transactions (
            arn, acquirer, batch_period, batch_item_count, mid, merchant_id, auth_date, clear_date,
            bin, last4, currency_code, amount, interchange, amount_usd, interchange_usd, fx_rate, fx_rate_date,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            arn, acquirer, batch_period, batch_item_count, mid, merchant_id, auth_date, clear_date,
            bin, last4, currency_code, amount, interchange, amount_usd, interchange_usd, fx_rate, fx_rate_date,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               TestRowsExcluded  = @Test,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Test - @Loaded,
               UnitFlagInvalid   = @UnitNA,
               UsdNotAvailable   = (SELECT COUNT(*) FROM silver.clearing_transactions WHERE amount IS NOT NULL AND amount_usd IS NULL),
               MerchantNotFound  = (SELECT COUNT(*) FROM silver.clearing_transactions WHERE merchant_id IS NULL)
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
