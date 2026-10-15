/* =====================================================================================
   Procedure : bronze.usp_load_merchants_crm_export
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the CRM's merchant master export CSV into bronze.merchants_crm_export
     exactly as received.
     Each row is one merchant: its legal and trading names, business vertical,
     country, onboarding date, status, risk tier, commercial terms (reserve
     percentage, processing fee percentage, per-transaction fee, chargeback fee),
     Merchant Category Code, account manager, contact email, and who last changed
     the record and when.
     This is the main merchant reference used to describe and price transactions in
     later layers. It contains personal data (contact_email); restrict access to it
     accordingly.
     No business cleaning or type conversion is done here (no numeric, percentage or
     date parsing, no code mapping); that happens in silver. The only change made to
     the data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local CRM export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'merchants_crm_export'.

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
     source_file_name  file name extracted from @file_path (e.g. merchants_crm_export.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.merchants_crm_export)

   Errors raised
     50081  CSV file was empty or could not be read
     50083  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50082 - invalid per_txn_fee / chargeback_fee / mcc - was removed;
      that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.merchants_crm_export per_txn_fee, chargeback_fee and mcc must be
       text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_merchants_crm_export;                                -- default file
     EXEC bronze.usp_load_merchants_crm_export @file_path = N'C:\Data\merchants_crm_export.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_merchants_crm_export]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\crm\merchants_crm_export.csv',
    @source_system VARCHAR(50)   = 'merchants_crm_export'
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
    -- e.g. 'C:\...\crm\merchants_crm_export.csv' -> 'merchants_crm_export.csv'
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
    -- mcc stays text so leading zeros are kept (e.g. 0742); fees stay text so
    -- values like '25.50' or '$0.30' are kept exactly as sent.
    ------------------------------------------------------------
    CREATE TABLE #merchants_crm_stage
    (
        merchant_id         VARCHAR(1000),   -- merchant's ID in the CRM (new-gateway format, e.g. MRC-00027)
        legal_name          VARCHAR(1000),   -- registered company name
        dba_name            VARCHAR(1000),   -- "doing business as" name - the brand customers see
        vertical            VARCHAR(1000),   -- industry/business segment
        country             VARCHAR(1000),   -- merchant's country, as written by the source
        onboard_date        VARCHAR(1000),   -- date the merchant was onboarded
        status              VARCHAR(1000),   -- e.g. active, suspended, terminated
        risk_tier           VARCHAR(1000),   -- risk classification, e.g. low, medium, high
        reserve_pct         VARCHAR(1000),   -- share of volume held back as a reserve against chargebacks
        processing_fee_pct  VARCHAR(1000),   -- percentage fee charged on each transaction's amount
        per_txn_fee         VARCHAR(1000),   -- fixed fee charged per transaction
        chargeback_fee      VARCHAR(1000),   -- fixed fee charged per chargeback
        mcc                 VARCHAR(1000),   -- Merchant Category Code (4-digit business type code)
        account_manager     VARCHAR(1000),   -- staff member who manages the merchant
        contact_email       VARCHAR(1000),   -- merchant contact email (personal data)
        last_modified       VARCHAR(1000),   -- when the CRM record was last changed
        modified_by         VARCHAR(1000)    -- who last changed the CRM record
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (legal names such as "Acme Media, LLC" contain commas)
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8 (names may contain accented characters)
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #merchants_crm_stage
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
    SELECT @staged_count = COUNT(*) FROM #merchants_crm_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50081, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.merchants_crm_export
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.merchants_crm_export
        (
            merchant_id, legal_name, dba_name, vertical, country,
            onboard_date, status, risk_tier, reserve_pct, processing_fee_pct,
            per_txn_fee, chargeback_fee, mcc, account_manager,
            contact_email, last_modified, modified_by,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(merchant_id, ''),
            NULLIF(legal_name, ''),
            NULLIF(dba_name, ''),
            NULLIF(vertical, ''),
            NULLIF(country, ''),
            NULLIF(onboard_date, ''),
            NULLIF(status, ''),
            NULLIF(risk_tier, ''),
            NULLIF(reserve_pct, ''),
            NULLIF(processing_fee_pct, ''),
            NULLIF(per_txn_fee, ''),
            NULLIF(chargeback_fee, ''),
            NULLIF(mcc, ''),
            NULLIF(account_manager, ''),
            NULLIF(contact_email, ''),
            NULLIF(last_modified, ''),
            NULLIF(modified_by, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #merchants_crm_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50083, 'Loaded row count does not match staged row count.', 1;

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
