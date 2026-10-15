/* =====================================================================================
   Procedure : bronze.usp_load_settlements_weekly
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the finance team's weekly merchant settlement CSV into
     bronze.settlements_weekly exactly as received.
     A settlement is the weekly statement of what a merchant is paid. Each row covers
     one merchant for one period and shows how the payout was calculated: gross sales,
     minus refunds, chargebacks and fees, minus reserve held back, plus reserve
     released, plus or minus adjustments, giving the net payout. It also records the
     payout date and status, the bank transfer reference, and a version number -
     a settlement can be reissued (restated), producing a newer version of the same
     settlement_id.
     Settlements are used in later layers to reconcile what merchants were paid
     against their transactions, refunds, chargebacks and fees.
     No business cleaning or type conversion is done here (no amount, date or
     version parsing); that happens in silver. The only change made to the data is
     that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local finance export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'settlements_weekly_export'.

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
     All versions of a settlement in the file are kept; choosing the latest version
     happens in silver.

   Metadata columns written
     source_system     from @source_system
     source_file_name  file name extracted from @file_path (e.g. settlements_weekly.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.settlements_weekly)

   Errors raised
     50121  CSV file was empty or could not be read
     50123  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50122 - invalid version / created_ts - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.settlements_weekly version and created_ts must be text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_settlements_weekly;                                -- default file
     EXEC bronze.usp_load_settlements_weekly @file_path = N'C:\Data\settlements_weekly.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_settlements_weekly]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\finance\settlements_weekly.csv',
    @source_system VARCHAR(50)   = 'settlements_weekly_export'
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
    -- e.g. 'C:\...\finance\settlements_weekly.csv' -> 'settlements_weekly.csv'
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
    -- Amounts stay text so formats such as '1,234.56', '(50.00)' or '$10' are kept as sent.
    ------------------------------------------------------------
    CREATE TABLE #settlements_stage
    (
        settlement_id     VARCHAR(1000),   -- settlement statement ID (one per merchant per period)
        merchant_id       VARCHAR(1000),   -- merchant being paid
        period_start      VARCHAR(1000),   -- first day covered by the settlement
        period_end        VARCHAR(1000),   -- last day covered by the settlement
        currency          VARCHAR(1000),   -- currency of all amounts on the row
        gross_sales       VARCHAR(1000),   -- total sales in the period
        refunds           VARCHAR(1000),   -- total refunds deducted
        chargebacks       VARCHAR(1000),   -- total chargebacks deducted
        fees_total        VARCHAR(1000),   -- processing and other fees deducted
        reserve_held      VARCHAR(1000),   -- amount held back as reserve this period
        reserve_released  VARCHAR(1000),   -- previously held reserve paid out this period
        adjustments       VARCHAR(1000),   -- manual corrections (positive or negative)
        adjustment_note   VARCHAR(1000),   -- explanation of the adjustment
        net_payout        VARCHAR(1000),   -- final amount paid to the merchant
        payout_date       VARCHAR(1000),   -- date the payout was (or will be) sent
        payout_status     VARCHAR(1000),   -- e.g. pending, paid, failed, held
        bank_ref          VARCHAR(1000),   -- bank transfer reference for the payout
        version           VARCHAR(1000),   -- revision number; higher = more recent restatement
        created_ts        VARCHAR(1000)    -- when this version of the settlement was created
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (adjustment notes and formatted amounts such as "1,234.56" contain commas)
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #settlements_stage
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
    SELECT @staged_count = COUNT(*) FROM #settlements_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50121, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.settlements_weekly
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.settlements_weekly
        (
            settlement_id, merchant_id, period_start, period_end, currency,
            gross_sales, refunds, chargebacks, fees_total,
            reserve_held, reserve_released, adjustments, adjustment_note,
            net_payout, payout_date, payout_status, bank_ref,
            version, created_ts,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(settlement_id, ''),
            NULLIF(merchant_id, ''),
            NULLIF(period_start, ''),
            NULLIF(period_end, ''),
            NULLIF(currency, ''),
            NULLIF(gross_sales, ''),
            NULLIF(refunds, ''),
            NULLIF(chargebacks, ''),
            NULLIF(fees_total, ''),
            NULLIF(reserve_held, ''),
            NULLIF(reserve_released, ''),
            NULLIF(adjustments, ''),
            NULLIF(adjustment_note, ''),
            NULLIF(net_payout, ''),
            NULLIF(payout_date, ''),
            NULLIF(payout_status, ''),
            NULLIF(bank_ref, ''),
            NULLIF(version, ''),
            NULLIF(created_ts, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #settlements_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50123, 'Loaded row count does not match staged row count.', 1;

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
