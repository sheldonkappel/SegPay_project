/* =====================================================================================
   Procedure : bronze.usp_load_txn_post_migration
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads one NEW-gateway (post-migration) transaction file into
     bronze.txn_post_migration exactly as received.
     The payment gateway migrated in March 2026. Files from transactions_202603.csv
     onward use the new 30-column layout:
       - currency was renamed ccy
       - auth_timestamp was renamed txn_ts_utc
       - network_txn_id was added
     Old-gateway files (29 columns) are loaded by bronze.usp_load_txn_pre_migration.
     Each row is one payment event: sale, rebill, auth, refund, void or chargeback.
     No business cleaning or type conversion is done here (no trimming, amount or
     timestamp parsing, code mapping, or duplicate removal); that happens in silver,
     where pre- and post-migration transactions are combined. The only changes made
     to the data are:
       - empty strings are stored as NULL
       - the trailing carriage return left by Windows line endings is removed from
         the last column (load_ts)

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Required.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'gateway_v2_transactions'.

   Behavior
     1. Reads the header row and stops with an error unless it exactly matches the
        post-migration layout (protects against loading a file into the wrong table,
        since columns are mapped by position).
     2. Bulk loads the file into a temporary staging table (all columns as text).
     3. Stops with an error if the file produced no rows.
     4. In one transaction:
          - deletes any rows previously loaded from a file with the same name
            (so re-running a file replaces it instead of duplicating it)
          - inserts the staged rows with load metadata
            (source system, file name, file path, batch ID)
          - checks the inserted row count equals the staged row count
     5. Any error rolls back the transaction, leaving bronze as it was.
     Duplicate txn_ids (within or across files) are all kept; silver resolves them.

   Metadata columns written
     source_system     from @source_system
     source_file_name  file name extracted from @file_path (e.g. transactions_202603.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     batch_id_source   the file's own batch_id column (gateway batch reference)
     ingested_at / ingested_by  filled by column defaults on bronze.txn_post_migration

   Errors raised
     50201  File was empty or could not be read
     50202  File header does not match the post-migration layout
     50203  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV', TRIM)
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path

   Usage
     EXEC bronze.usp_load_txn_post_migration
          @file_path = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\txn\transactions_202603.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_txn_post_migration]
    @file_path     NVARCHAR(500),
    @source_system VARCHAR(50) = 'gateway_v2_transactions'
AS
BEGIN
    -- Suppress "(n rows affected)" messages so callers only see real results/errors
    SET NOCOUNT ON;

    -- Any run-time error aborts the batch and rolls back an open transaction
    SET XACT_ABORT ON;

    ------------------------------------------------------------
    -- Variables
    ------------------------------------------------------------
    -- Holds the dynamic BULK INSERT statements (BULK INSERT cannot take a variable file path directly)
    DECLARE @sql NVARCHAR(MAX);

    -- Unique ID for this run; stamped on every row so one load can be identified or removed later
    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();

    -- File name only, taken from the full path:
    -- REVERSE the path, find the first '\' (the last one in the original), take everything after it.
    -- The appended '\' makes it work even if @file_path contains no folder.
    -- e.g. 'C:\...\txn\transactions_202603.csv' -> 'transactions_202603.csv'
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- The path written into dynamic SQL, with single quotes doubled (e.g. O'Brien -> O''Brien)
    DECLARE @path_lit NVARCHAR(1000) = REPLACE(@file_path, '''', '''''');

    -- Header row read from the file, and the exact header expected for this layout
    DECLARE @header NVARCHAR(MAX);
    DECLARE @expected NVARCHAR(MAX) = N'txn_id,purchase_id,parent_txn_id,merchant_id,site_id,package_id,customer_id,txn_type,amount,ccy,card_brand,card_bin,card_last4,payment_method,response_code,response_text,status,txn_ts_utc,settle_date,acquirer,mid,three_ds,device_type,ip_address,ip_country,affiliate_id,is_test,network_txn_id,batch_id,load_ts';

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- rows read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Check the header is the post-migration layout
    -- Loads only the first line (FIRSTROW = 1, LASTROW = 1) into a one-column table.
    --   FIELDTERMINATOR 0x1f : unit separator - never appears in the data, so the whole
    --                          line lands in one column instead of being split on commas
    --   ROWTERMINATOR 0x0a   : line feed
    -- Then removes the carriage return (CHAR(13)), any UTF-8 byte order mark (NCHAR(65279))
    -- and spaces, so harmless formatting differences don't cause a mismatch.
    ------------------------------------------------------------
    CREATE TABLE #hdr (line NVARCHAR(MAX));

    SET @sql = N'
        BULK INSERT #hdr
        FROM ''' + @path_lit + N'''
        WITH (
            FIRSTROW = 1,
            LASTROW = 1,
            FIELDTERMINATOR = ''0x1f'',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001''
        );';

    EXEC sys.sp_executesql @sql;

    SELECT @header = REPLACE(REPLACE(REPLACE(line, CHAR(13), N''), NCHAR(65279), N''), N' ', N'')
    FROM #hdr;

    -- Columns are mapped by position, so a different layout would load values into the
    -- wrong columns. Stop with a clear message showing the header that was found.
    IF ISNULL(@header, N'') <> @expected
    BEGIN
        DECLARE @msg NVARCHAR(2048) =
            @file_name + N' is not a post-migration file. Header: ' + LEFT(ISNULL(@header, N'<empty>'), 1500);
        THROW 50202, @msg, 1;
    END

    ------------------------------------------------------------
    -- 2. Stage the raw file as text
    -- Temporary table (#) that exists only for this procedure call.
    -- Columns must match the file's column order exactly (verified by the header check).
    -- Everything is VARCHAR(1000) so no value is rejected for type or length.
    --   FORMAT = 'CSV'       : RFC 4180 parsing, so quoted values such as "9,99" load correctly
    --   FIELDQUOTE = '"'     : character that wraps quoted values
    --   FIRSTROW = 2         : skip the header row
    --   ROWTERMINATOR 0x0a   : line feed; the leftover carriage return is removed from load_ts below
    --   CODEPAGE = '65001'   : read the file as UTF-8
    --   TABLOCK              : take a table lock for a faster bulk load
    ------------------------------------------------------------
    CREATE TABLE #txn_stage
    (
        txn_id          VARCHAR(1000),   -- gateway transaction ID
        purchase_id     VARCHAR(1000),   -- purchase/subscription the transaction belongs to
        parent_txn_id   VARCHAR(1000),   -- original transaction for refunds/voids/chargebacks ('' or '0' = none)
        merchant_id     VARCHAR(1000),   -- merchant ID (new format MRC-nnnnn; some legacy numeric IDs remain)
        site_id         VARCHAR(1000),   -- site the sale happened on
        package_id      VARCHAR(1000),   -- package/price point purchased
        customer_id     VARCHAR(1000),   -- customer making the payment
        txn_type        VARCHAR(1000),   -- SALE, REBILL, AUTH, REFUND, VOID, CHARGEBACK (many spellings)
        amount          VARCHAR(1000),   -- amount as written (e.g. 9.99, "9,99", $9.99, (9.99))
        ccy             VARCHAR(1000),   -- currency (renamed from currency; alpha or numeric codes)
        card_brand      VARCHAR(1000),   -- card network (e.g. VISA, VI, Mastercard)
        card_bin        VARCHAR(1000),   -- first 6 or 8 digits of the card number
        card_last4      VARCHAR(1000),   -- last 4 digits of the card number
        payment_method  VARCHAR(1000),   -- e.g. CARD, APPLEPAY, GOOGLEPAY, SEPA
        response_code   VARCHAR(1000),   -- issuer response code (e.g. 00, 05, 51)
        response_text   VARCHAR(1000),   -- response description as sent (wording varies)
        status          VARCHAR(1000),   -- APPROVED / DECLINED / ERROR (many spellings)
        txn_ts_utc      VARCHAR(1000),   -- transaction time (renamed from auth_timestamp; several formats)
        settle_date     VARCHAR(1000),   -- settlement date (YYYYMMDD or MM/DD/YYYY)
        acquirer        VARCHAR(1000),   -- acquiring bank (several spellings)
        mid             VARCHAR(1000),   -- Merchant ID at the acquirer
        three_ds        VARCHAR(1000),   -- whether 3-D Secure was used (Y/N/TRUE/0/1...)
        device_type     VARCHAR(1000),   -- mobile / desktop / tablet (several spellings)
        ip_address      VARCHAR(1000),   -- customer IP (IPv4 or IPv6)
        ip_country      VARCHAR(1000),   -- country of the IP ('XX' = unknown)
        affiliate_id    VARCHAR(1000),   -- referring affiliate, e.g. AFF-0001
        is_test         VARCHAR(1000),   -- test transaction flag (Y/N/TRUE/0/1...)
        network_txn_id  VARCHAR(1000),   -- card network's transaction ID (new column)
        batch_id        VARCHAR(1000),   -- gateway's batch reference (stored as batch_id_source)
        load_ts         VARCHAR(1000)    -- when the gateway produced the row
    );

    SET @sql = N'
        BULK INSERT #txn_stage
        FROM ''' + @path_lit + N'''
        WITH (
            FORMAT = ''CSV'',
            FIELDQUOTE = ''"'',
            FIRSTROW = 2,
            FIELDTERMINATOR = '','',
            ROWTERMINATOR = ''0x0a'',
            CODEPAGE = ''65001'',
            TABLOCK
        );';

    EXEC sys.sp_executesql @sql;

    ------------------------------------------------------------
    -- 3. Validate the file produced data
    ------------------------------------------------------------
    SELECT @staged_count = COUNT(*) FROM #txn_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50201, 'File was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 4. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.txn_post_migration
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty fields into NULL so "missing" is stored one way.
        -- No other transformation, except removing the trailing CR from load_ts.
        INSERT INTO bronze.txn_post_migration
        (
            txn_id, purchase_id, parent_txn_id, merchant_id, site_id, package_id, customer_id,
            txn_type, amount, ccy, card_brand, card_bin, card_last4, payment_method,
            response_code, response_text, status, txn_ts_utc, settle_date, acquirer, mid,
            three_ds, device_type, ip_address, ip_country, affiliate_id, is_test,
            network_txn_id, batch_id_source, load_ts,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(txn_id, ''),
            NULLIF(purchase_id, ''),
            NULLIF(parent_txn_id, ''),
            NULLIF(merchant_id, ''),
            NULLIF(site_id, ''),
            NULLIF(package_id, ''),
            NULLIF(customer_id, ''),
            NULLIF(txn_type, ''),
            NULLIF(amount, ''),
            NULLIF(ccy, ''),
            NULLIF(card_brand, ''),
            NULLIF(card_bin, ''),
            NULLIF(card_last4, ''),
            NULLIF(payment_method, ''),
            NULLIF(response_code, ''),
            NULLIF(response_text, ''),
            NULLIF(status, ''),
            NULLIF(txn_ts_utc, ''),
            NULLIF(settle_date, ''),
            NULLIF(acquirer, ''),
            NULLIF(mid, ''),
            NULLIF(three_ds, ''),
            NULLIF(device_type, ''),
            NULLIF(ip_address, ''),
            NULLIF(ip_country, ''),
            NULLIF(affiliate_id, ''),
            NULLIF(is_test, ''),
            NULLIF(network_txn_id, ''),
            NULLIF(batch_id, ''),                          -- file's batch_id -> batch_id_source
            NULLIF(REPLACE(load_ts, CHAR(13), ''), ''),    -- last column: strip the Windows CR
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #txn_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50203, 'Loaded row count does not match staged row count.', 1;

        -- Make the delete + insert permanent
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- Undo any partial work so bronze keeps its previous contents
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;

        -- Re-raise the original error so the caller (SSMS, PowerShell, a job) sees it
        THROW;
    END CATCH;

    ------------------------------------------------------------
    -- Return a one-row summary of the load
    ------------------------------------------------------------
    SELECT FileName    = @file_name,
           TargetTable = 'bronze.txn_post_migration',
           RowsLoaded  = @loaded_count;
END;
GO
