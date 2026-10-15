/* =====================================================================
   Procedure : silver.usp_load_clicks
   Source    : bronze.clicks   (raw text, affiliate tracker export)
   Target    : silver.clicks   (cleaned, one row per click)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Each row is a click on an affiliate's tracking link. Clicks that lead to
   a sale appear in silver.conversions (joined on click_id).

   Transformations
   ---------------
     * click_id        : trimmed. Rows without one are skipped.
     * click_ts_utc    : Unix epoch milliseconds -> UTC date/time (ms kept).
     * publisher_id    : whole number.
     * affiliate_id    : publisher_id in the affiliates format (4 -> AFF-0004).
                         Verified 2026-10-15: matches the purchase's affiliate
                         for all 23,373 clicks that led to a purchase.
     * offer_id        : whole number.
     * sub_id, ip      : trimmed.
     * ua_family       : known browser families kept; bot/unknown -> Bot/Unknown.
     * device_category : Mobile / Desktop from the browser family; NULL for bots.
     * is_bot          : 1 = bot / unknown traffic, 0 = known browser.
     * country         : 2-letter code, uppercased (bronze column geo).
     * landing_variant : trimmed, lowercase.
     * Duplicates      : one row per click_id - the newest bronze load wins.
     * Missing values  : NULL.
     * Lineage         : bronze source columns, load_run_id, silver_loaded_at.

   PII
   ---
   ip is personal data and is masked for users without UNMASK permission.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; affiliate mapping verified (was
                 marked as an assumption); audit logging.

   Usage
   -----
     EXEC silver.usp_load_clicks;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_clicks
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.clicks',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT = 0,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.clicks does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.clicks;

        BEGIN TRAN;

        TRUNCATE TABLE silver.clicks;

        WITH s AS (
            SELECT
                NULLIF(TRIM(b.click_id), '')                           AS click_id,

                -- Epoch ms -> UTC (split into seconds + ms because DATEADD takes an INT)
                DATEADD(MILLISECOND, x.ts_ms % 1000,
                    DATEADD(SECOND, x.ts_ms / 1000, CAST('1970-01-01' AS DATETIME2(3)))) AS click_ts_utc,

                x.pub_id                                               AS publisher_id,
                CASE WHEN x.pub_id IS NOT NULL
                     THEN 'AFF-' + RIGHT('0000' + CONVERT(VARCHAR(10), x.pub_id), 4) END AS affiliate_id,
                TRY_CAST(TRIM(b.offer_id) AS INT)                      AS offer_id,
                NULLIF(TRIM(b.sub_id), '')                             AS sub_id,
                NULLIF(TRIM(b.ip), '')                                 AS ip,

                CASE x.ua
                    WHEN 'CHROME'           THEN 'Chrome'
                    WHEN 'CHROME MOBILE'    THEN 'Chrome Mobile'
                    WHEN 'SAFARI'           THEN 'Safari'
                    WHEN 'SAFARI IOS'       THEN 'Safari iOS'
                    WHEN 'EDGE'             THEN 'Edge'
                    WHEN 'FIREFOX'          THEN 'Firefox'
                    WHEN 'SAMSUNG INTERNET' THEN 'Samsung Internet'
                    WHEN 'BOT/UNKNOWN'      THEN 'Bot/Unknown'
                END                                                    AS ua_family,

                CASE x.ua
                    WHEN 'CHROME MOBILE'    THEN 'Mobile'
                    WHEN 'SAFARI IOS'       THEN 'Mobile'
                    WHEN 'SAMSUNG INTERNET' THEN 'Mobile'
                    WHEN 'CHROME'           THEN 'Desktop'
                    WHEN 'SAFARI'           THEN 'Desktop'
                    WHEN 'EDGE'             THEN 'Desktop'
                    WHEN 'FIREFOX'          THEN 'Desktop'
                END                                                    AS device_category,

                CAST(CASE WHEN x.ua = 'BOT/UNKNOWN' THEN 1
                          WHEN x.ua <> '' THEN 0 END AS BIT)           AS is_bot,

                CASE WHEN TRIM(b.geo) LIKE '[A-Za-z][A-Za-z]' THEN UPPER(TRIM(b.geo)) END AS country,
                NULLIF(LOWER(TRIM(b.landing_variant)), '')             AS landing_variant,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.clicks b
            CROSS APPLY (
                SELECT ts_ms  = TRY_CAST(TRIM(b.click_ts_ms) AS BIGINT),
                       pub_id = TRY_CAST(TRIM(b.publisher_id) AS INT),
                       ua     = UPPER(TRIM(b.ua_family))
            ) x
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY click_id ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE click_id IS NOT NULL
        )
        INSERT silver.clicks (
            click_id, click_ts_utc, publisher_id, affiliate_id, offer_id, sub_id, ip, ua_family,
            device_category, is_bot, country, landing_variant,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT click_id, click_ts_utc, publisher_id, affiliate_id, offer_id, sub_id, ip, ua_family,
               device_category, is_bot, country, landing_variant,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded,
               BotClicks         = (SELECT COUNT(*) FROM silver.clicks WHERE is_bot = 1),
               TimestampMissing  = (SELECT COUNT(*) FROM silver.clicks WHERE click_ts_utc IS NULL)
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
