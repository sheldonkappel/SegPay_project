/* =====================================================================================
   Procedure : bronze.usp_load_merchant_accounts
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the CRM's merchant account export CSV into bronze.merchant_accounts exactly
     as received.
     Each row links a merchant to one of its processing accounts at an acquirer: the
     acquirer's name, the Merchant ID (MID) that acquirer issued, the currency group
     the account processes, the Merchant Category Code (MCC), the date the account
     setup took effect, and its status. A merchant can have several accounts (e.g. one
     per acquirer or currency), and an account can change over time (effective_from).
     This table is the bridge between merchant_id (business identity) and mid (the
     identifier on transactions, clearing files and chargebacks).
     No business cleaning or type conversion is done here (no numeric or date checks,
     no code mapping); that happens in silver. The only change made to the data is
     that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local CRM export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'merchant_accounts_export'.

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
     source_file_name  file name extracted from @file_path (e.g. merchant_accounts.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.merchant_accounts)

   Errors raised
     50061  CSV file was empty or could not be read
     50063  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50062 - invalid mid / mcc / effective_from - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.merchant_accounts mid, mcc and effective_from must be text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_merchant_accounts;                                    -- default file
     EXEC bronze.usp_load_merchant_accounts @file_path = N'C:\Data\merchant_accounts.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_merchant_accounts]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\crm\merchant_accounts.csv',
    @source_system VARCHAR(50)   = 'merchant_accounts_export'
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
    -- e.g. 'C:\...\crm\merchant_accounts.csv' -> 'merchant_accounts.csv'
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
    -- mid and mcc are identifiers, not quantities: keeping them as text preserves
    -- leading zeros (MCCs such as 0742 are valid 4-digit codes).
    ------------------------------------------------------------
    CREATE TABLE #merchant_accounts_stage
    (
        merchant_id     VARCHAR(1000),   -- merchant's business ID in the CRM
        acquirer_name   VARCHAR(1000),   -- acquiring bank that holds this account
        mid             VARCHAR(1000),   -- Merchant ID issued by the acquirer (appears on transactions/clearing/chargebacks)
        currency_group  VARCHAR(1000),   -- currency or group of currencies the account processes
        mcc             VARCHAR(1000),   -- Merchant Category Code: 4-digit code for the merchant's type of business
        effective_from  VARCHAR(1000),   -- date this account setup took effect
        status          VARCHAR(1000)    -- account status, e.g. active, suspended, closed
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
        BULK INSERT #merchant_accounts_stage
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
    SELECT @staged_count = COUNT(*) FROM #merchant_accounts_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50061, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.merchant_accounts
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.merchant_accounts
        (
            merchant_id, acquirer_name, mid, currency_group, mcc,
            effective_from, status,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(merchant_id, ''),
            NULLIF(acquirer_name, ''),
            NULLIF(mid, ''),
            NULLIF(currency_group, ''),
            NULLIF(mcc, ''),
            NULLIF(effective_from, ''),
            NULLIF(status, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #merchant_accounts_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50063, 'Loaded row count does not match staged row count.', 1;

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
