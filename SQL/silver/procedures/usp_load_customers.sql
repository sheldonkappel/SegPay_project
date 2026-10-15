/* =====================================================================
   Procedure : silver.usp_load_customers
   Source    : bronze.customers   (raw text)
   Target    : silver.customers   (cleaned, one row per customer)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   One row per customer (cardholder account): contact details, country,
   account creation date and marketing consent. Purchases and transactions
   carry customer_id.

   Transformations
   ---------------
     * customer_id      : trimmed and uppercased. Rows without one are skipped.
     * email            : trimmed and lowercased.
     * country          : 2-letter ISO code via ref.country_alias.
     * postal_code      : trimmed and uppercased, kept as text.
     * created_at,
       last_updated     : any supported format (util.fn_parse_date); slash
                          dates US month/day first.
     * marketing_opt_in : 1 = opted in, 0 = opted out (util.fn_parse_flag);
                          NULL = no answer recorded - do not market.
     * Duplicates       : one row per customer - latest last_updated, then
                          newest bronze load.
     * Missing values   : NULL.
     * Lineage          : bronze source columns, load_run_id, silver_loaded_at.

   PII
   ---
   email and postal_code are personal data; both are masked for users
   without UNMASK permission.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date / country / flag
                 functions. created_at now reads 'Aug 24, 2026' and
                 '24/08/2026' - 3,230 customers previously had no date.
                 Audit logging.

   Usage
   -----
     EXEC silver.usp_load_customers;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_customers
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.customers',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT = 0,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.customers does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.customers;

        BEGIN TRAN;

        TRUNCATE TABLE silver.customers;

        WITH s AS (
            SELECT
                NULLIF(UPPER(TRIM(b.customer_id)), '')                 AS customer_id,
                NULLIF(LOWER(TRIM(b.email)), '')                       AS email,
                COALESCE(ca.country_code,
                         CASE WHEN x.ctry LIKE '[A-Z][A-Z]' THEN x.ctry END) AS country,
                NULLIF(UPPER(TRIM(b.postal_code)), '')                 AS postal_code,
                cr.date_us_first                                       AS created_at,
                mo.flag                                                AS marketing_opt_in,
                lu.date_us_first                                       AS last_updated,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.customers b
            CROSS APPLY (SELECT ctry = UPPER(REPLACE(TRIM(b.country), '.', ''))) x
            CROSS APPLY util.fn_parse_date(b.created_at)        cr
            CROSS APPLY util.fn_parse_date(b.last_updated)      lu
            CROSS APPLY util.fn_parse_flag(b.marketing_opt_in)  mo
            LEFT JOIN ref.country_alias ca ON ca.alias = x.ctry
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY last_updated DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE customer_id IS NOT NULL
        )
        INSERT silver.customers (
            customer_id, email, country, postal_code, created_at, marketing_opt_in, last_updated,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT customer_id, email, country, postal_code, created_at, marketing_opt_in, last_updated,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows         = @Bronze,
               SilverRows         = @Loaded,
               DuplicatesDropped  = @Bronze - @Loaded,
               CreatedAtMissing   = (SELECT COUNT(*) FROM silver.customers WHERE created_at IS NULL),
               CountryNotMapped   = (SELECT COUNT(*) FROM silver.customers WHERE country IS NULL),
               MarketingOptedIn   = (SELECT COUNT(*) FROM silver.customers WHERE marketing_opt_in = 1),
               MarketingNoAnswer  = (SELECT COUNT(*) FROM silver.customers WHERE marketing_opt_in IS NULL)
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
