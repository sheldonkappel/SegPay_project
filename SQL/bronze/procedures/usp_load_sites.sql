/* =====================================================================================
   Procedure : bronze.usp_load_sites
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the CRM's site export CSV into bronze.sites exactly as received.
     A site is a website a merchant sells through. Each row gives the site ID (which
     matches site_id on gateway transactions, packages and purchases), the merchant
     that owns it, its name and URL, content category, launch date, status, the
     billing descriptor (the text that appears on the cardholder's bank statement),
     and the site's support email.
     The billing descriptor matters for disputes: customers who don't recognize it on
     their statement are more likely to file a chargeback.
     No business cleaning or type conversion is done here (no numeric or date
     parsing, no URL/email standardization); that happens in silver. The only change
     made to the data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local CRM export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'sites_export'.

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
     source_file_name  file name extracted from @file_path (e.g. sites.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.sites)

   Errors raised
     50091  CSV file was empty or could not be read
     50093  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50092 - non-numeric site_id - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.sites.site_id must be a text column (VARCHAR)

   Usage
     EXEC bronze.usp_load_sites;                                  -- default file
     EXEC bronze.usp_load_sites @file_path = N'C:\Data\sites.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_sites]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\crm\sites.csv',
    @source_system VARCHAR(50)   = 'sites_export'
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
    -- e.g. 'C:\...\crm\sites.csv' -> 'sites.csv'
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
    CREATE TABLE #sites_stage
    (
        site_id             VARCHAR(1000),   -- site ID (matches site_id on transactions, packages and purchases)
        merchant_id         VARCHAR(1000),   -- merchant that owns the site
        site_name           VARCHAR(1000),   -- display name of the site
        site_url            VARCHAR(1000),   -- web address of the site
        category            VARCHAR(1000),   -- content/business category of the site
        launch_date         VARCHAR(1000),   -- date the site went live
        status              VARCHAR(1000),   -- e.g. active, paused, closed
        billing_descriptor  VARCHAR(1000),   -- text shown on the cardholder's bank statement
        support_email       VARCHAR(1000)    -- customer support contact for the site
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8 (site names may contain accented characters)
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #sites_stage
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
    SELECT @staged_count = COUNT(*) FROM #sites_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50091, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.sites
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.sites
        (
            site_id, merchant_id, site_name, site_url, category,
            launch_date, status, billing_descriptor, support_email,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(site_id, ''),
            NULLIF(merchant_id, ''),
            NULLIF(site_name, ''),
            NULLIF(site_url, ''),
            NULLIF(category, ''),
            NULLIF(launch_date, ''),
            NULLIF(status, ''),
            NULLIF(billing_descriptor, ''),
            NULLIF(support_email, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #sites_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50093, 'Loaded row count does not match staged row count.', 1;

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
