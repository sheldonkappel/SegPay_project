/* =====================================================================
   Procedure : silver.usp_load_sites
   Source    : bronze.sites   (raw text)
   Target    : silver.sites   (cleaned, one row per site)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A site is a website a merchant sells through. Each site belongs to one
   merchant and sells one or more packages. The billing descriptor is the
   text on the cardholder's bank statement.

   Transformations
   ---------------
     * site_id            : whole number. Rows without one are skipped.
     * merchant_id        : trimmed and uppercased.
     * site_name          : trimmed (' Pixel Pass' -> 'Pixel Pass').
     * site_url           : bare lowercase domain (https://emberhub.com/ ->
                            emberhub.com, www.emberpro.com -> emberpro.com).
     * category           : trimmed.
     * launch_date        : any supported format (util.fn_parse_date); slash
                            dates US month/day first.
     * status             : title case only - Live, Active, Closed, Inactive,
                            Paused and Under Review stay distinct.
     * billing_descriptor : prefix unified and uppercased
                            (Segpay *Bluehub, Segpay.Com*Novaplus -> SEGPAY*BLUEHUB, SEGPAY*NOVAPLUS).
     * support_email      : trimmed and lowercased.
     * Test data          : test sites (ref.v_test_site: category 'Test' or a
                            test merchant) excluded.
     * Duplicates         : one row per site_id - the newest bronze load wins.
     * Missing values     : NULL.
     * Lineage            : bronze source columns, load_run_id, silver_loaded_at.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * 12 sites are assigned to merchants MRC-00201 - MRC-00205, which are not
       in silver.merchant_accounts; their purchases and transactions all name
       a different merchant, so the sites file is probably wrong.
     * 4 sites have a launch_date in the future (5194, 5198, 5734, 5757).

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date function and test-site
                 view; audit logging.

   Usage
   -----
     EXEC silver.usp_load_sites;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_sites
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.sites',
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
            THROW 50001, N'silver.sites does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.sites;

        SELECT @Test = COUNT(*)
        FROM bronze.sites b
        WHERE TRY_CAST(TRIM(b.site_id) AS INT) IN (SELECT ts.site_id FROM ref.v_test_site ts);

        BEGIN TRAN;

        TRUNCATE TABLE silver.sites;

        WITH s AS (
            SELECT
                x.site_id,
                NULLIF(UPPER(TRIM(b.merchant_id)), '')                 AS merchant_id,
                NULLIF(TRIM(b.site_name), '')                          AS site_name,

                -- Bare domain: scheme, leading 'www.' and anything after the domain removed
                NULLIF(LEFT(x.url_no_www, CHARINDEX('/', x.url_no_www + '/') - 1), '') AS site_url,

                NULLIF(TRIM(b.category), '')                           AS category,
                ld.date_us_first                                       AS launch_date,

                CASE x.status_key
                    WHEN 'live'         THEN 'Live'
                    WHEN 'active'       THEN 'Active'
                    WHEN 'closed'       THEN 'Closed'
                    WHEN 'inactive'     THEN 'Inactive'
                    WHEN 'paused'       THEN 'Paused'
                    WHEN 'under review' THEN 'Under Review'
                    ELSE UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50)
                END                                                    AS status,

                -- Whatever prefix comes before '*' becomes 'SEGPAY*'; all uppercase
                CASE WHEN CHARINDEX('*', x.descr) > 0
                     THEN 'SEGPAY*' + UPPER(TRIM(SUBSTRING(x.descr, CHARINDEX('*', x.descr) + 1, 100)))
                     ELSE UPPER(x.descr)
                END                                                    AS billing_descriptor,

                NULLIF(LOWER(TRIM(b.support_email)), '')               AS support_email,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.sites b
            CROSS APPLY (
                SELECT
                    site_id    = TRY_CAST(TRIM(b.site_id) AS INT),
                    url_no_www = CASE WHEN u.url LIKE 'www.%' THEN SUBSTRING(u.url, 5, 500) ELSE u.url END,
                    status_key = NULLIF(LOWER(TRIM(b.status)), ''),
                    descr      = NULLIF(TRIM(b.billing_descriptor), '')
                FROM (SELECT url = REPLACE(REPLACE(LOWER(TRIM(b.site_url)), 'https://', ''), 'http://', '')) u
            ) x
            CROSS APPLY util.fn_parse_date(b.launch_date) ld
            WHERE NOT EXISTS (SELECT 1 FROM ref.v_test_site ts WHERE ts.site_id = x.site_id)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY site_id ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE site_id IS NOT NULL
        )
        INSERT silver.sites (
            site_id, merchant_id, site_name, site_url, category, launch_date, status,
            billing_descriptor, support_email,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT site_id, merchant_id, site_name, site_url, category, launch_date, status,
               billing_descriptor, support_email,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows            = @Bronze,
               TestRowsExcluded      = @Test,
               SilverRows            = @Loaded,
               DuplicatesDropped     = @Bronze - @Test - @Loaded,
               LaunchDateMissing     = (SELECT COUNT(*) FROM silver.sites WHERE launch_date IS NULL),
               FutureLaunchDate      = (SELECT COUNT(*) FROM silver.sites WHERE launch_date > CAST(SYSUTCDATETIME() AS DATE)),
               SupportEmailMissing   = (SELECT COUNT(*) FROM silver.sites WHERE support_email IS NULL),
               MerchantNotInAccounts = (SELECT COUNT(*) FROM silver.sites s
                                        WHERE NOT EXISTS (SELECT 1 FROM silver.merchant_accounts a WHERE a.merchant_id = s.merchant_id))
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
