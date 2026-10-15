/* =====================================================================
   Procedure : silver.usp_load_response_codes
   Source    : bronze.response_codes   (raw text)
   Target    : silver.response_codes   (cleaned, one row per response code)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Reference list of authorization response codes returned by card issuers
   (00 = approved, 51 = insufficient funds, ...). silver.transactions takes
   its response_text from here, so every code has one description.

   Transformations
   ---------------
     * response_code : trimmed and uppercased, kept as text ('05', 'N7').
     * description   : title case - first letter of each word capitalized;
                       letters already in capitals kept ('CVV2 / CVC2 failure'
                       -> 'CVV2 / CVC2 Failure').
     * Duplicates    : one row per code - the newest bronze load wins.
     * Missing values: NULL.
     * Lineage       : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  NULLs instead of 'N/A'; audit logging.

   Usage
   -----
     EXEC silver.usp_load_response_codes;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_response_codes
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.response_codes',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @i         INT = 1,
            @MaxLen    INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.response_codes does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.response_codes;

        -- Step 1: clean and de-duplicate into #rc (newest bronze load per code)
        SELECT response_code, description, source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by
        INTO #rc
        FROM (
            SELECT NULLIF(UPPER(TRIM(response_code)), '') AS response_code,
                   NULLIF(TRIM(description), '')         AS description,
                   source_system, source_file_name, batch_id,
                   ingested_at                           AS bronze_ingested_at,
                   ingested_by,
                   ROW_NUMBER() OVER (PARTITION BY UPPER(TRIM(response_code)) ORDER BY ingested_at DESC) AS rn
            FROM bronze.response_codes
        ) b
        WHERE rn = 1 AND response_code IS NOT NULL;

        -- Step 2: title case - capitalize a letter at the start or after ' ', '/', '-', '('
        SELECT @MaxLen = MAX(LEN(description)) FROM #rc;
        WHILE @i <= @MaxLen
        BEGIN
            UPDATE #rc
            SET description = STUFF(description, @i, 1, UPPER(SUBSTRING(description, @i, 1)))
            WHERE LEN(description) >= @i
              AND (@i = 1 OR SUBSTRING(description, @i - 1, 1) IN (' ', '/', '-', '('));
            SET @i += 1;
        END

        BEGIN TRAN;

        TRUNCATE TABLE silver.response_codes;

        INSERT silver.response_codes (
            response_code, description, source_system, source_file_name, batch_id,
            bronze_ingested_at, ingested_by, load_run_id)
        SELECT response_code, description, source_system, source_file_name, batch_id,
               bronze_ingested_at, ingested_by, @run_id
        FROM #rc;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded
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
