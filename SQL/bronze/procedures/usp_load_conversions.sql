/* =====================================================================================
   Procedure : bronze.usp_load_conversions
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the affiliate tracker's conversion export CSV into bronze.conversions
     exactly as received.
     A conversion is a click that led to a paying event (for example a sale or rebill).
     Each row links back to the original click (click_id), records the order it
     produced (order_id), what kind of event it was, the payout owed to the affiliate
     in USD, and the conversion's status. Conversions are later joined to clicks,
     affiliates and gateway transactions to reconcile affiliate payouts.
     No business cleaning or type conversion is done here (no timestamp conversion,
     numeric checks, or code mapping); that happens in silver. The only change made
     to the data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local affiliate tracker export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'conversions_export'.

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
     source_file_name  file name extracted from @file_path (e.g. conversions.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.conversions)

   Errors raised
     50021  CSV file was empty or could not be read
     50023  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50022 - non-numeric conversion_ts_ms / order_id / payout_usd - was removed;
      that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.conversions conversion_ts_ms, order_id and payout_usd must be text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_conversions;                                      -- default file
     EXEC bronze.usp_load_conversions @file_path = N'C:\Data\conversions.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_conversions]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\affiliate_tracker\conversions.csv',
    @source_system VARCHAR(50)   = 'conversions_export'
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
    -- e.g. 'C:\...\affiliate_tracker\conversions.csv' -> 'conversions.csv'
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- rows read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Stage the raw CSV as text
    -- Temporary table (#) that exists only for this procedure call.
    -- Columns map by position, so they must match the CSV column order exactly;
    -- the header text itself is ignored.
    -- Everything is VARCHAR(1000) so one bad value can't fail the whole bulk load.
    ------------------------------------------------------------
    CREATE TABLE #conversions_stage
    (
        conversion_id     VARCHAR(1000),   -- unique ID of the conversion
        click_id          VARCHAR(1000),   -- click that led to it (joins to bronze.clicks)
        conversion_ts_ms  VARCHAR(1000),   -- conversion time as Unix epoch milliseconds (ms since 1970-01-01 UTC)
        order_id          VARCHAR(1000),   -- order/purchase produced by the conversion
        event             VARCHAR(1000),   -- type of conversion event, e.g. sale, rebill, trial
        payout_usd        VARCHAR(1000),   -- amount owed to the affiliate for this conversion, in USD
        status            VARCHAR(1000)    -- conversion status, e.g. approved, pending, reversed
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #conversions_stage
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
    SELECT @staged_count = COUNT(*) FROM #conversions_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50021, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.conversions
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.conversions
        (
            conversion_id, click_id, conversion_ts_ms, order_id,
            event, payout_usd, status,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(conversion_id, ''),
            NULLIF(click_id, ''),
            NULLIF(conversion_ts_ms, ''),
            NULLIF(order_id, ''),
            NULLIF(event, ''),
            NULLIF(payout_usd, ''),
            NULLIF(status, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #conversions_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50023, 'Loaded row count does not match staged row count.', 1;

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
