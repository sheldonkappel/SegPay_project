/* =====================================================================
   Procedure : silver.usp_load_merchant_xref
   Source    : bronze.merchant_xref   (raw text)
   Target    : silver.merchant_xref   (cleaned, one row per legacy merchant ID)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   The payment gateway migrated in March 2026. The old gateway identified
   merchants with numbers (e.g. 1005); the new one uses MRC-nnnnn. This table
   maps each legacy number to its new merchant ID so pre-migration
   transactions can be linked to the merchant.

   Transformations
   ---------------
     * legacy_merchant_id : converted to a whole number. Rows without one are skipped.
     * merchant_id        : trimmed and uppercased.
     * effective_from     : any supported format (util.fn_parse_date).
     * notes              : trimmed.
     * Test data          : rows with notes = 'test' or a test merchant
                            (ref.test_merchant, e.g. 9999 -> MRC-99999) excluded.
     * Duplicates         : one row per legacy ID - latest effective_from, then
                            newest bronze load.
     * Missing values     : NULL.
     * Lineage            : bronze source columns, load_run_id, silver_loaded_at.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Legacy IDs 1002, 1229 and 1310 have no mapping here. silver.transactions
       fills them from the risk engine's events (flagged merchant_id_inferred).

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date function; test-merchant
                 table; audit logging.

   Usage
   -----
     EXEC silver.usp_load_merchant_xref;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_merchant_xref
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.merchant_xref',
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
            THROW 50001, N'silver.merchant_xref does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.merchant_xref;

        SELECT @Test = COUNT(*)
        FROM bronze.merchant_xref
        WHERE LOWER(TRIM(notes)) = 'test'
           OR UPPER(TRIM(merchant_id)) IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
           OR TRY_CAST(TRIM(legacy_merchant_id) AS INT) IN (SELECT tm.legacy_merchant_id FROM ref.test_merchant tm);

        BEGIN TRAN;

        TRUNCATE TABLE silver.merchant_xref;

        WITH s AS (
            SELECT
                TRY_CAST(TRIM(b.legacy_merchant_id) AS INT)        AS legacy_merchant_id,
                NULLIF(UPPER(TRIM(b.merchant_id)), '')             AS merchant_id,
                ef.date_us_first                                   AS effective_from,
                NULLIF(TRIM(b.notes), '')                          AS notes,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                      AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.merchant_xref b
            CROSS APPLY util.fn_parse_date(b.effective_from) ef
            WHERE ISNULL(LOWER(TRIM(b.notes)), '') <> 'test'
              AND ISNULL(UPPER(TRIM(b.merchant_id)), '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
              AND ISNULL(TRY_CAST(TRIM(b.legacy_merchant_id) AS INT), -1) NOT IN (SELECT ISNULL(tm.legacy_merchant_id, -1) FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY legacy_merchant_id ORDER BY effective_from DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE legacy_merchant_id IS NOT NULL
        )
        INSERT silver.merchant_xref (
            legacy_merchant_id, merchant_id, effective_from, notes,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT legacy_merchant_id, merchant_id, effective_from, notes,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               TestRowsExcluded  = @Test,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Test - @Loaded,
               NewMerchantIds    = (SELECT COUNT(DISTINCT merchant_id) FROM silver.merchant_xref)
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
