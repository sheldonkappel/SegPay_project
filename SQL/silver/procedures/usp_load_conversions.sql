/* =====================================================================
   Procedure : silver.usp_load_conversions
   Source    : bronze.conversions   (raw text, affiliate tracker export)
   Target    : silver.conversions   (cleaned, one row per conversion)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A conversion is a click that turned into a sale, with the commission owed
   to the affiliate. click_id joins to silver.clicks; order_id is the
   purchase_id in silver.purchases_snapshot and silver.transactions.

   Transformations
   ---------------
     * conversion_id, click_id : trimmed. Rows without a conversion_id are skipped.
     * conversion_ts_utc       : Unix epoch milliseconds -> UTC date/time.
     * order_id                : whole number.
     * event, status           : capitalized ('sale' -> 'Sale').
     * payout_usd              : util.fn_parse_amount; 2 decimals.
     * Duplicates              : one row per conversion - the newest bronze load wins.
     * Missing values          : NULL.
     * Lineage                 : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared amount function; audit logging.

   Usage
   -----
     EXEC silver.usp_load_conversions;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_conversions
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.conversions',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT = 0,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.conversions does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.conversions;

        BEGIN TRAN;

        TRUNCATE TABLE silver.conversions;

        WITH s AS (
            SELECT
                NULLIF(TRIM(b.conversion_id), '')                      AS conversion_id,
                NULLIF(TRIM(b.click_id), '')                           AS click_id,
                DATEADD(MILLISECOND, x.ts_ms % 1000,
                    DATEADD(SECOND, x.ts_ms / 1000, CAST('1970-01-01' AS DATETIME2(3)))) AS conversion_ts_utc,
                TRY_CAST(TRIM(b.order_id) AS BIGINT)                   AS order_id,
                NULLIF(UPPER(LEFT(TRIM(b.event), 1))  + LOWER(SUBSTRING(TRIM(b.event), 2, 50)), '')  AS event,
                CAST(ROUND(po.amount, 2) AS DECIMAL(18,2))             AS payout_usd,
                NULLIF(UPPER(LEFT(TRIM(b.status), 1)) + LOWER(SUBSTRING(TRIM(b.status), 2, 50)), '') AS status,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.conversions b
            CROSS APPLY (SELECT ts_ms = TRY_CAST(TRIM(b.conversion_ts_ms) AS BIGINT)) x
            CROSS APPLY util.fn_parse_amount(b.payout_usd) po
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY conversion_id ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE conversion_id IS NOT NULL
        )
        INSERT silver.conversions (
            conversion_id, click_id, conversion_ts_utc, order_id, event, payout_usd, status,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT conversion_id, click_id, conversion_ts_utc, order_id, event, payout_usd, status,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded,
               OrderIdMissing    = (SELECT COUNT(*) FROM silver.conversions WHERE order_id IS NULL),
               ClickNotFound     = (SELECT COUNT(*) FROM silver.conversions c
                                    WHERE NOT EXISTS (SELECT 1 FROM silver.clicks k WHERE k.click_id = c.click_id))
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Dropped = @Bronze - @Loaded;

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
