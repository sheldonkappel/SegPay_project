/* =====================================================================
   Procedure : silver.usp_load_affiliates
   Source    : bronze.affiliates   (raw text)
   Target    : silver.affiliates   (cleaned, one row per affiliate)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Affiliates are partners who send customers to merchant sites and earn a
   commission on the sales they bring in. Clicks, conversions, purchases and
   transactions carry affiliate_id.

   Transformations
   ---------------
     * affiliate_id, affiliate_name, affiliate_type : trimmed.
     * commission_pct : stored as a fraction with 4 decimals (0.3500 = 35%).
                        '35%' -> 0.3500; a bare number above 1 is a percent
                        ('15' -> 0.1500); a number up to 1 is already a fraction.
     * status         : Active / Inactive / Suspended (any casing);
                        unrecognized -> NULL.
     * join_date      : any supported format (util.fn_parse_date); slash dates
                        read US month/day first, day-first only when the US
                        reading is impossible.
     * country        : 2-letter ISO code via ref.country_alias.
     * payout_method  : trimmed.
     * Duplicates     : one row per affiliate_id - the newest bronze load wins.
     * Missing values : NULL.
     * Lineage        : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs (was text / 'N/A'); shared date and
                 country functions; slash dates now US first (previously read
                 day-first, e.g. 04/12/2024 was 2024-12-04); commission kept
                 at 4 decimals (was rounded to 2 before storing); audit logging.

   Usage
   -----
     EXEC silver.usp_load_affiliates;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_affiliates
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.affiliates',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.affiliates does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.affiliates;

        BEGIN TRAN;

        TRUNCATE TABLE silver.affiliates;

        /* -------------------------------------------------------------
           s     : every column cleaned and typed
           dedup : one row per affiliate_id, newest bronze load first
           ------------------------------------------------------------- */
        WITH s AS (
            SELECT
                NULLIF(TRIM(b.affiliate_id), '')                    AS affiliate_id,
                NULLIF(TRIM(b.affiliate_name), '')                  AS affiliate_name,
                NULLIF(TRIM(b.affiliate_type), '')                  AS affiliate_type,

                -- Commission as a fraction: '%' or a number above 1 means "percent"
                CAST(CASE WHEN b.commission_pct LIKE '%[%]%' OR c.pct > 1 THEN c.pct / 100
                          ELSE c.pct END AS DECIMAL(7,4))           AS commission_pct,

                CASE UPPER(TRIM(b.status))
                    WHEN 'ACTIVE'    THEN 'Active'
                    WHEN 'INACTIVE'  THEN 'Inactive'
                    WHEN 'SUSPENDED' THEN 'Suspended'
                END                                                 AS status,

                jd.date_us_first                                    AS join_date,

                -- Country: alias table, else an existing 2-letter code
                COALESCE(ca.country_code,
                         CASE WHEN x.ctry LIKE '[A-Z][A-Z]' THEN x.ctry END) AS country,

                NULLIF(TRIM(b.payout_method), '')                   AS payout_method,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                       AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.affiliates b
            CROSS APPLY (SELECT ctry = UPPER(REPLACE(TRIM(b.country), '.', ''))) x
            CROSS APPLY (SELECT pct = TRY_CAST(REPLACE(TRIM(b.commission_pct), '%', '') AS DECIMAL(10,4))) c
            CROSS APPLY util.fn_parse_date(b.join_date) jd
            LEFT JOIN ref.country_alias ca ON ca.alias = x.ctry
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY affiliate_id ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE affiliate_id IS NOT NULL
        )
        INSERT silver.affiliates (
            affiliate_id, affiliate_name, affiliate_type, commission_pct, status, join_date,
            country, payout_method, source_system, source_file_name, batch_id,
            bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            affiliate_id, affiliate_name, affiliate_type, commission_pct, status, join_date,
            country, payout_method, source_system, source_file_name, batch_id,
            bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        -- Summary: returned to the caller and written to audit.load_log
        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded,
               CountryNotMapped  = (SELECT COUNT(*) FROM silver.affiliates WHERE country IS NULL),
               JoinDateMissing   = (SELECT COUNT(*) FROM silver.affiliates WHERE join_date IS NULL)
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        SET @Excluded = 0;
        SET @Dropped  = @Bronze - @Loaded;

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
