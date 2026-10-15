/* =====================================================================================
   Procedure : bronze.usp_load_customers
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the billing system's customer export CSV into bronze.customers exactly as
     received.
     Each row is one customer: their ID (which matches customer_id on gateway
     transactions), email, country, postal code, sign-up date, marketing consent,
     and when the record was last updated at the source.
     This table contains personal data (email, postal code); restrict access to it
     accordingly.
     No business cleaning or type conversion is done here (no date parsing, flag
     mapping, or email/country standardization); that happens in silver. The only
     change made to the data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local billing export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'customers_export'.

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
     source_file_name  file name extracted from @file_path (e.g. customers.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.customers)

   Errors raised
     50031  CSV file was empty or could not be read
     50033  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50032 - invalid dates in last_updated - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.customers.last_updated must be a text column (VARCHAR)

   Usage
     EXEC bronze.usp_load_customers;                                    -- default file
     EXEC bronze.usp_load_customers @file_path = N'C:\Data\customers.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_customers]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\billing\customers.csv',
    @source_system VARCHAR(50)   = 'customers_export'
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
    -- e.g. 'C:\...\billing\customers.csv' -> 'customers.csv'
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
    -- postal_code must stay text: codes can have leading zeros (e.g. 02134) or letters (e.g. SW1A 1AA).
    ------------------------------------------------------------
    CREATE TABLE #customers_stage
    (
        customer_id       VARCHAR(1000),   -- customer ID (matches customer_id on gateway transactions)
        email             VARCHAR(1000),   -- customer email address (personal data)
        country           VARCHAR(1000),   -- customer country, as written by the source
        postal_code       VARCHAR(1000),   -- postal/ZIP code (personal data)
        created_at        VARCHAR(1000),   -- when the customer account was created
        marketing_opt_in  VARCHAR(1000),   -- whether the customer agreed to marketing, e.g. Y/N, true/false
        last_updated      VARCHAR(1000)    -- when the record was last changed at the source
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8 (emails and names may contain accented characters)
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #customers_stage
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
    SELECT @staged_count = COUNT(*) FROM #customers_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50031, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.customers
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.customers
        (
            customer_id, email, country, postal_code,
            created_at, marketing_opt_in, last_updated,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(customer_id, ''),
            NULLIF(email, ''),
            NULLIF(country, ''),
            NULLIF(postal_code, ''),
            NULLIF(created_at, ''),
            NULLIF(marketing_opt_in, ''),
            NULLIF(last_updated, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #customers_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50033, 'Loaded row count does not match staged row count.', 1;

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
