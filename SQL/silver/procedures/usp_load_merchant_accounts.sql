/* =====================================================================
   Procedure : silver.usp_load_merchant_accounts
   Source    : bronze.merchant_accounts   (raw text)
   Target    : silver.merchant_accounts   (cleaned, one row per MID)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A merchant's processing accounts at the acquiring banks. Each account has
   a MID (the acquirer's merchant account ID); chargebacks, clearing items
   and transactions carry the MID, and this table maps it to merchant_id.

   Transformations
   ---------------
     * mid            : trimmed.
     * merchant_id    : trimmed and uppercased.
     * acquirer_name  : one name per acquirer via ref.acquirer_alias; unknown
                        names kept as written.
     * currency_group : uppercase, spaces removed ('usd / cad' -> 'USD/CAD').
     * mcc            : padded to 4 digits ('742' -> '0742').
     * effective_from : any supported format (util.fn_parse_date).
     * status         : capitalized ('ACTIVE' -> 'Active').
     * Test data      : accounts of test merchants (ref.test_merchant) excluded.
     * Duplicates     : one row per MID - latest effective_from, then newest bronze load.
     * Missing values : NULL.
     * Lineage        : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date and acquirer lookups;
                 test-merchant rule; audit logging.

   Usage
   -----
     EXEC silver.usp_load_merchant_accounts;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_merchant_accounts
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.merchant_accounts',
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
            THROW 50001, N'silver.merchant_accounts does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.merchant_accounts;

        SELECT @Test = COUNT(*)
        FROM bronze.merchant_accounts
        WHERE UPPER(TRIM(merchant_id)) IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        BEGIN TRAN;

        TRUNCATE TABLE silver.merchant_accounts;

        WITH s AS (
            SELECT
                NULLIF(TRIM(b.mid), '')                                    AS mid,
                NULLIF(UPPER(TRIM(b.merchant_id)), '')                     AS merchant_id,
                COALESCE(aq.acquirer, NULLIF(TRIM(b.acquirer_name), ''))   AS acquirer_name,
                NULLIF(REPLACE(UPPER(TRIM(b.currency_group)), ' ', ''), '') AS currency_group,
                CASE WHEN TRIM(b.mcc) NOT LIKE '%[^0-9]%' AND LEN(TRIM(b.mcc)) BETWEEN 1 AND 4
                     THEN RIGHT('0000' + TRIM(b.mcc), 4) END               AS mcc,
                ef.date_us_first                                           AS effective_from,
                NULLIF(UPPER(LEFT(TRIM(b.status), 1)) + LOWER(SUBSTRING(TRIM(b.status), 2, 50)), '') AS status,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                              AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.merchant_accounts b
            CROSS APPLY util.fn_parse_date(b.effective_from) ef
            LEFT JOIN ref.acquirer_alias aq ON aq.alias = UPPER(REPLACE(TRIM(b.acquirer_name), ' ', ''))
            WHERE ISNULL(UPPER(TRIM(b.merchant_id)), '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY mid ORDER BY effective_from DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE mid IS NOT NULL
        )
        INSERT silver.merchant_accounts (
            mid, merchant_id, acquirer_name, currency_group, mcc, effective_from, status,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT mid, merchant_id, acquirer_name, currency_group, mcc, effective_from, status,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               TestRowsExcluded  = @Test,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Test - @Loaded
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

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
