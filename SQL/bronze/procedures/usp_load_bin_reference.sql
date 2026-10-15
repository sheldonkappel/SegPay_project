/* =====================================================================================
   Procedure : bronze.usp_load_bin_reference
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the BIN reference CSV into bronze.bin_reference exactly as received.
     A BIN (Bank Identification Number) is the first 6 or 8 digits of a card number.
     It identifies the card brand, card type, issuing bank, and issuing country, and is
     used to enrich transactions (which carry card_bin) in later layers.
     No business cleaning is done here (no trimming, type conversion, or code mapping);
     that happens in silver. The only change made to the data is that empty strings
     are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local reference export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'bin_reference_export'.

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
     source_file_name  file name extracted from @file_path (e.g. bin_reference.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.bin_reference)

   Errors raised
     50141  CSV file was empty or could not be read
     50143  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path

   Usage
     EXEC bronze.usp_load_bin_reference;                                    -- default file
     EXEC bronze.usp_load_bin_reference @file_path = N'C:\Data\bin_reference.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_bin_reference]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\reference\bin_reference.csv',
    @source_system VARCHAR(50)   = 'bin_reference_export'
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
    -- e.g. 'C:\...\reference\bin_reference.csv' -> 'bin_reference.csv'
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
    -- Keeping bin as text also preserves its exact digits and length (6 vs 8 digits).
    ------------------------------------------------------------
    CREATE TABLE #bin_stage
    (
        bin             VARCHAR(1000),   -- first 6 or 8 digits of the card number
        card_brand      VARCHAR(1000),   -- e.g. Visa, Mastercard
        card_type       VARCHAR(1000),   -- e.g. credit, debit, prepaid
        card_category   VARCHAR(1000),   -- e.g. classic, gold, business
        issuer_name     VARCHAR(1000),   -- issuing bank
        issuer_country  VARCHAR(1000),   -- country of the issuing bank
        last_updated    VARCHAR(1000)    -- when the BIN record was last updated at the source
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (useful for issuer names such as "Bank of America, N.A.")
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8 (issuer names may contain accented characters)
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #bin_stage
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
    SELECT @staged_count = COUNT(*) FROM #bin_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50141, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.bin_reference
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        INSERT INTO bronze.bin_reference
        (
            bin, card_brand, card_type, card_category,
            issuer_name, issuer_country, last_updated,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(bin, ''),
            NULLIF(card_brand, ''),
            NULLIF(card_type, ''),
            NULLIF(card_category, ''),
            NULLIF(issuer_name, ''),
            NULLIF(issuer_country, ''),
            NULLIF(last_updated, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #bin_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50143, 'Loaded row count does not match staged row count.', 1;

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
