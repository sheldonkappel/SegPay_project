/* =====================================================================
   Procedure : silver.usp_load_fx_rates_daily
   Source    : bronze.fx_rates_daily   (raw text; US Treasury and other feeds)
   Target    : silver.fx_rates_daily   (US Treasury rates only, one per currency per day)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Daily exchange rates used to convert amounts to USD in transactions,
   chargebacks and clearing. Only the US Treasury feed is kept, so every
   USD figure in silver uses the same source.

   Transformations
   ---------------
     * Source filter  : source = 'treasury-feed' only (ECB etc. excluded).
     * rate_date      : YYYY-MM-DD (util.fn_parse_date).
     * currency       : the non-USD side of the pair ('GBP/USD' -> GBP,
                        'USD/CAD' -> CAD). Pairs without USD are skipped.
     * usd_per_unit   : USD per 1 unit of the currency - for XXX/USD the rate
                        as sent, for USD/XXX its inverse (8 decimals).
     * units_per_usd  : the inverse of usd_per_unit.
     * Missing, zero or negative rates are skipped.
     * Duplicates     : one row per currency + date - the newest bronze load wins.
     * Lineage        : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns; shared date function; audit logging.

   Usage
   -----
     EXEC silver.usp_load_fx_rates_daily;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_fx_rates_daily
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.fx_rates_daily',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Treasury  INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.fx_rates_daily does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze   = COUNT(*),
               @Treasury = SUM(CASE WHEN UPPER(TRIM(source)) = 'TREASURY-FEED' THEN 1 ELSE 0 END)
        FROM bronze.fx_rates_daily;

        BEGIN TRAN;

        TRUNCATE TABLE silver.fx_rates_daily;

        WITH c AS (
            SELECT b.*,
                   rd.date_us_first                               AS rate_date_clean,
                   UPPER(REPLACE(TRIM(b.pair), '/', ''))           AS pair_clean,   -- 'gbp/usd' -> 'GBPUSD'
                   TRY_CAST(TRIM(b.rate) AS DECIMAL(18,8))         AS rate_num
            FROM bronze.fx_rates_daily b
            CROSS APPLY util.fn_parse_date(b.rate_date) rd
            WHERE UPPER(TRIM(b.source)) = 'TREASURY-FEED'
        ),
        s AS (
            SELECT
                c.rate_date_clean                                  AS rate_date,
                CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' AND c.pair_clean <> 'USDUSD' THEN LEFT(c.pair_clean, 3)
                     WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]'                             THEN RIGHT(c.pair_clean, 3)
                END                                                AS currency,
                CAST(ROUND(CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' THEN c.rate_num
                                WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]' THEN 1.0 / c.rate_num END, 8) AS DECIMAL(18,8)) AS usd_per_unit,
                CAST(ROUND(CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' THEN 1.0 / c.rate_num
                                WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]' THEN c.rate_num END, 8) AS DECIMAL(18,8)) AS units_per_usd,
                c.source_system, c.source_file_name, c.batch_id,
                c.ingested_at                                      AS bronze_ingested_at,
                c.ingested_by
            FROM c
            WHERE c.rate_num > 0
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY currency, rate_date ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE currency IS NOT NULL AND rate_date IS NOT NULL
        )
        INSERT silver.fx_rates_daily (
            rate_date, currency, usd_per_unit, units_per_usd,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT rate_date, currency, usd_per_unit, units_per_usd,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows          = @Bronze,
               OtherSourcesRemoved = @Bronze - @Treasury,
               TreasuryRows        = @Treasury,
               SilverRows          = @Loaded,
               TreasuryRowsDropped = @Treasury - @Loaded
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        SET @Excluded = @Bronze - @Treasury;
        SET @Dropped  = @Treasury - @Loaded;

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
