/* =====================================================================================
   Procedure : bronze.usp_load_chargeback_reason_codes
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the chargeback reason code reference CSV into bronze.chargeback_reason_codes
     exactly as received.
     When a cardholder disputes a transaction, the card network (Visa, Mastercard, etc.)
     assigns a reason code explaining why, for example fraud, an authorization problem,
     or a consumer dispute. This table maps each network's codes to a description and
     category, and is used to explain chargebacks in later layers.
     No business cleaning is done here (no trimming, type conversion, or code mapping);
     that happens in silver. The only change made to the data is that empty strings
     are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local reference export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'chargeback_reason_codes_export'.

   Behavior
     1. Bulk loads the CSV into a temporary staging table (all columns as text).
     2. Stops with an error if the file produced no rows.
     3. In one transaction:
          - deletes any rows previously loaded from a file with the same name
            (so re-running a file replaces it instead of duplicating it)
          - inserts the staged rows with load metadata
            (source system, file name, file path, batch ID)
          - checks the inserted row count equals the staged row count
     4. Any error rolls back the transaction, leaving bronze as it was.

   Metadata columns written
     source_system     from @source_system
     source_file_name  file name extracted from @file_path (e.g. chargeback_reason_codes.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.chargeback_reason_codes)

   Errors raised
     50151  CSV file was empty or could not be read
     50153  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path

   Usage
     EXEC bronze.usp_load_chargeback_reason_codes;                         -- default file
     EXEC bronze.usp_load_chargeback_reason_codes @file_path = N'C:\Data\chargeback_reason_codes.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_chargeback_reason_codes]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\reference\chargeback_reason_codes.csv',
    @source_system VARCHAR(50)   = 'chargeback_reason_codes_export'
AS
BEGIN
    -- Suppress "(n rows affected)" messages so callers only see real results/errors
    SET NOCOUNT ON;

    -- Any run-time error aborts the batch and rolls back an open transaction
    SET XACT_ABORT ON;

    ------------------------------------------------------------
    -- Variables
    ------------------------------------------------------------
    -- Holds the dynamic BULK INSERT statement (BULK INSERT cannot take a variable file path directly)
    DECLARE @sql NVARCHAR(MAX);

    -- Unique ID for this run; stamped on every row so one load can be identified or removed later
    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();

    -- File name only, taken from the full path:
    -- REVERSE the path, find the first '\' (the last one in the original), take everything after it.
    -- The appended '\' makes it work even if @file_path contains no folder.
    -- e.g. 'C:\...\reference\chargeback_reason_codes.csv' -> 'chargeback_reason_codes.csv'
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- rows read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Stage the raw CSV as text
    -- Temporary table (#) that exists only for this procedure call.
    -- Columns must match the CSV column order exactly, because BULK INSERT maps by position.
    -- Everything is VARCHAR(1000) so no value is rejected for type or length - bronze keeps raw text.
    -- Keeping reason_code as text matters: codes such as Visa '10.4' or Mastercard '4837'
    -- are identifiers, not numbers, and converting them could change them (e.g. '10.40' -> 10.4).
    ------------------------------------------------------------
    CREATE TABLE #reason_stage
    (
        network      VARCHAR(1000),   -- card network that owns the code, e.g. Visa, Mastercard
        reason_code  VARCHAR(1000),   -- the network's code, e.g. 10.4, 4837
        description  VARCHAR(1000),   -- what the code means
        category     VARCHAR(1000)    -- grouping, e.g. fraud, authorization, processing error, consumer dispute
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (descriptions often contain commas)
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #reason_stage
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (
            FORMAT = ''CSV'',
            FIRSTROW = 2,
            FIELDQUOTE = ''"'',
            CODEPAGE = ''65001'',
            TABLOCK
        );';

    -- Run the dynamic statement. The temp table is visible to it because
    -- sp_executesql runs inside the same session and scope chain.
    EXEC sys.sp_executesql @sql;

    ------------------------------------------------------------
    -- Validate the file produced data
    ------------------------------------------------------------
    SELECT @staged_count = COUNT(*) FROM #reason_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50151, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.chargeback_reason_codes
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        INSERT INTO bronze.chargeback_reason_codes
        (
            network, reason_code, description, category,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(network, ''),
            NULLIF(reason_code, ''),
            NULLIF(description, ''),
            NULLIF(category, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #reason_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50153, 'Loaded row count does not match staged row count.', 1;

        -- Make the delete + insert permanent
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Undo any partial work so bronze keeps its previous contents
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Re-raise the original error so the caller (SSMS, PowerShell, a job) sees it
        THROW;
    END CATCH;
END;
GO
