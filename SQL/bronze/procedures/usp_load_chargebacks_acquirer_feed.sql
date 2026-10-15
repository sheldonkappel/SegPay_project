/* =====================================================================================
   Procedure : bronze.usp_load_chargebacks_acquirer_feed
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the acquirer's chargeback (dispute) feed CSV into
     bronze.chargebacks_acquirer_feed exactly as received.
     A chargeback happens when a cardholder disputes a charge with their bank. The
     acquirer (the merchant's bank) reports each dispute case: which transaction it
     relates to, the network reason code, the amount, the response deadline, and the
     final outcome. This feed is later matched to gateway transactions and to the
     chargeback reason code reference.
     No business cleaning or type conversion is done here (no trimming, date/amount
     parsing, numeric checks, or code mapping); that happens in silver. The only change
     made to the data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local disputes export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'chargebacks_acquirer_feed'.

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
     source_file_name  file name extracted from @file_path (e.g. chargebacks_acquirer_feed.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.chargebacks_acquirer_feed)

   Errors raised
     50101  CSV file was empty or could not be read
     50103  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50102 - non-numeric txn_ref - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.chargebacks_acquirer_feed.txn_ref must be a text column (VARCHAR)

   Usage
     EXEC bronze.usp_load_chargebacks_acquirer_feed;                       -- default file
     EXEC bronze.usp_load_chargebacks_acquirer_feed @file_path = N'C:\Data\chargebacks_acquirer_feed.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_chargebacks_acquirer_feed]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\disputes\chargebacks_acquirer_feed.csv',
    @source_system VARCHAR(50)   = 'chargebacks_acquirer_feed'
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
    -- e.g. 'C:\...\disputes\chargebacks_acquirer_feed.csv' -> 'chargebacks_acquirer_feed.csv'
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
    -- Everything is VARCHAR(1000) so no value is rejected for type or length.
    -- Identifiers such as arn, mid, txn_ref, card_bin and card_last4 stay text so their
    -- exact digits (including any leading zeros) are preserved.
    ------------------------------------------------------------
    CREATE TABLE #chargebacks_stage
    (
        case_id              VARCHAR(1000),   -- acquirer's dispute case number
        network              VARCHAR(1000),   -- card network, e.g. Visa, Mastercard
        reason_code          VARCHAR(1000),   -- network chargeback reason code
        reason_desc          VARCHAR(1000),   -- reason code description as sent by the acquirer
        arn                  VARCHAR(1000),   -- Acquirer Reference Number (23 digits); identifies the original card transaction
        mid                  VARCHAR(1000),   -- Merchant ID at the acquirer
        merchant_descriptor  VARCHAR(1000),   -- merchant name shown on the cardholder's statement
        txn_ref              VARCHAR(1000),   -- reference to the gateway transaction (kept as raw text)
        card_bin             VARCHAR(1000),   -- first 6/8 digits of the card number
        card_last4           VARCHAR(1000),   -- last 4 digits of the card number
        orig_txn_date        VARCHAR(1000),   -- date of the original disputed transaction
        dispute_amount       VARCHAR(1000),   -- amount being disputed
        dispute_ccy          VARCHAR(1000),   -- currency of the disputed amount
        received_date        VARCHAR(1000),   -- date the acquirer received the chargeback
        respond_by           VARCHAR(1000),   -- deadline for the merchant to respond
        status               VARCHAR(1000),   -- current case status, e.g. open, closed
        resolution_date      VARCHAR(1000),   -- date the case was resolved
        outcome              VARCHAR(1000),   -- final result, e.g. won, lost
        representment_sent   VARCHAR(1000)    -- whether the merchant contested the chargeback with evidence
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (merchant descriptors and reason descriptions may contain commas)
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #chargebacks_stage
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
    SELECT @staged_count = COUNT(*) FROM #chargebacks_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50101, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.chargebacks_acquirer_feed
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.chargebacks_acquirer_feed
        (
            case_id, network, reason_code, reason_desc, arn, mid,
            merchant_descriptor, txn_ref, card_bin, card_last4,
            orig_txn_date, dispute_amount, dispute_ccy, received_date,
            respond_by, status, resolution_date, outcome, representment_sent,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(case_id, ''),
            NULLIF(network, ''),
            NULLIF(reason_code, ''),
            NULLIF(reason_desc, ''),
            NULLIF(arn, ''),
            NULLIF(mid, ''),
            NULLIF(merchant_descriptor, ''),
            NULLIF(txn_ref, ''),
            NULLIF(card_bin, ''),
            NULLIF(card_last4, ''),
            NULLIF(orig_txn_date, ''),
            NULLIF(dispute_amount, ''),
            NULLIF(dispute_ccy, ''),
            NULLIF(received_date, ''),
            NULLIF(respond_by, ''),
            NULLIF(status, ''),
            NULLIF(resolution_date, ''),
            NULLIF(outcome, ''),
            NULLIF(representment_sent, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #chargebacks_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50103, 'Loaded row count does not match staged row count.', 1;

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
