/* =====================================================================================
   Procedure : bronze.usp_load_packages
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the pricing system's package export into bronze.packages exactly as
     received.
     A package is a price point a merchant sells on one of its sites: for example a
     one-time purchase, or a subscription with an optional free/discounted trial
     followed by recurring rebills. Each row gives the package and site IDs (which
     match package_id and site_id on gateway transactions), its name, billing model,
     initial price and currency, trial length, rebill price and period, status, and
     when it was created and last updated.
     Packages are used in later layers to check that transactions were charged the
     expected price and to analyze trial-to-rebill conversion.
     No business cleaning or type conversion is done here (no numeric, price or date
     parsing, no code mapping); that happens in silver. The only change made to the
     data is that empty strings are stored as NULL.

   File format
     Unlike most exports, this is a PIPE-delimited (|) text file (.txt) with a header
     row. Values may be wrapped in double quotes.

   Parameters
     @file_path      Full path to the file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local pricing export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'packages_export'.

   Behavior
     1. Bulk loads the file into a temporary staging table (all columns as text).
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
     source_file_name  file name extracted from @file_path (e.g. packages.txt)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.packages)

   Errors raised
     50131  File was empty or could not be read
     50133  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50132 - non-numeric package_id / site_id / trial_days - was removed;
      that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.packages package_id, site_id and trial_days must be text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_packages;                                     -- default file
     EXEC bronze.usp_load_packages @file_path = N'C:\Data\packages.txt';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_packages]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\pricing\packages.txt',
    @source_system VARCHAR(50)   = 'packages_export'
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
    -- e.g. 'C:\...\pricing\packages.txt' -> 'packages.txt'
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- rows read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Stage the raw file as text
    -- Temporary table (#) that exists only for this procedure call.
    -- Columns map by position, so they must match the file's column order exactly;
    -- the header text itself is ignored.
    -- Everything is VARCHAR(1000) so one bad value can't fail the whole bulk load.
    ------------------------------------------------------------
    CREATE TABLE #packages_stage
    (
        package_id      VARCHAR(1000),   -- package ID (matches package_id on gateway transactions)
        site_id         VARCHAR(1000),   -- site the package is sold on (matches site_id on transactions)
        package_name    VARCHAR(1000),   -- display name of the package
        billing_model   VARCHAR(1000),   -- e.g. one-time, recurring, trial-then-recurring
        initial_price   VARCHAR(1000),   -- price of the first charge
        currency        VARCHAR(1000),   -- currency of the prices
        trial_days      VARCHAR(1000),   -- length of the trial period in days (empty/0 = no trial)
        rebill_price    VARCHAR(1000),   -- price of each recurring charge
        rebill_period   VARCHAR(1000),   -- how often rebills happen, e.g. 30 days, monthly
        status          VARCHAR(1000),   -- e.g. active, retired
        created_date    VARCHAR(1000),   -- when the package was created
        updated_date    VARCHAR(1000)    -- when the package was last changed
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'         : RFC 4180 parsing, so quoted values load correctly
    --   FIELDTERMINATOR = '|'  : this file separates columns with pipes, not commas
    --   FIRSTROW = 2           : skip the header row
    --   FIELDQUOTE = '"'       : character that wraps quoted values
    --   CODEPAGE = '65001'     : read the file as UTF-8
    --   TABLOCK                : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #packages_stage
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (
            FORMAT = ''CSV'',
            FIELDTERMINATOR = ''|'',
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
    SELECT @staged_count = COUNT(*) FROM #packages_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50131, 'File was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.packages
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.packages
        (
            package_id, site_id, package_name, billing_model,
            initial_price, currency, trial_days, rebill_price, rebill_period,
            status, created_date, updated_date,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(package_id, ''),
            NULLIF(site_id, ''),
            NULLIF(package_name, ''),
            NULLIF(billing_model, ''),
            NULLIF(initial_price, ''),
            NULLIF(currency, ''),
            NULLIF(trial_days, ''),
            NULLIF(rebill_price, ''),
            NULLIF(rebill_period, ''),
            NULLIF(status, ''),
            NULLIF(created_date, ''),
            NULLIF(updated_date, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #packages_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50133, 'Loaded row count does not match staged row count.', 1;

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
