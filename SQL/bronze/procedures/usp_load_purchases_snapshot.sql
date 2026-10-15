/* =====================================================================================
   Procedure : bronze.usp_load_purchases_snapshot
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the billing system's purchase snapshot CSV into bronze.purchases_snapshot
     exactly as received.
     A purchase is a customer's order or subscription for one package on one site.
     Each row shows the purchase's state at the time the snapshot was exported:
     who bought it, from which merchant/site/package, when, its current status,
     cancellation details (date, reason, who initiated it), the next rebill date and
     number of rebills so far, the affiliate and traffic source that brought the
     customer, any promo code, whether it started as a trial, and when the record
     was last updated.
     Gateway transactions carry purchase_id, so this table gives the subscription-level
     context for each charge, rebill, refund and chargeback.
     No business cleaning or type conversion is done here (no numeric, date or flag
     parsing, no code mapping); that happens in silver. The only change made to the
     data is that empty strings are stored as NULL.

   Parameters
     @file_path      Full path to the CSV file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local billing export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'purchases_snapshot_export'.

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
     Note: because rows are replaced by file name, loading a newer snapshot with the
     same file name replaces the previous snapshot. Use dated file names (e.g.
     purchases_snapshot_20261014.csv) if snapshot history should be kept.

   Metadata columns written
     source_system     from @source_system
     source_file_name  file name extracted from @file_path (e.g. purchases_snapshot.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.purchases_snapshot)

   Errors raised
     50041  CSV file was empty or could not be read
     50043  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50042 - invalid purchase_id / site_id / package_id / last_updated - was removed;
      that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.purchases_snapshot purchase_id, site_id, package_id and last_updated
       must be text columns (VARCHAR)

   Usage
     EXEC bronze.usp_load_purchases_snapshot;                                -- default file
     EXEC bronze.usp_load_purchases_snapshot @file_path = N'C:\Data\purchases_snapshot.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_purchases_snapshot]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\billing\purchases_snapshot.csv',
    @source_system VARCHAR(50)   = 'purchases_snapshot_export'
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
    -- e.g. 'C:\...\billing\purchases_snapshot.csv' -> 'purchases_snapshot.csv'
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
    CREATE TABLE #purchases_stage
    (
        purchase_id          VARCHAR(1000),   -- purchase ID (matches purchase_id on gateway transactions)
        customer_id          VARCHAR(1000),   -- customer who made the purchase (joins to customers)
        merchant_id          VARCHAR(1000),   -- merchant that sold it (joins to merchants)
        site_id              VARCHAR(1000),   -- site it was bought on
        package_id           VARCHAR(1000),   -- package bought (joins to packages)
        purchase_date        VARCHAR(1000),   -- when the purchase was made
        purchase_status      VARCHAR(1000),   -- current state, e.g. active, cancelled, expired
        cancel_date          VARCHAR(1000),   -- when it was cancelled (empty if not cancelled)
        cancel_reason        VARCHAR(1000),   -- why it was cancelled
        cancel_initiated_by  VARCHAR(1000),   -- who cancelled it, e.g. customer, merchant, system
        next_rebill_date     VARCHAR(1000),   -- next scheduled recurring charge (empty if none)
        rebill_count         VARCHAR(1000),   -- number of rebills charged so far
        affiliate_id         VARCHAR(1000),   -- affiliate that referred the customer (e.g. AFF-0001)
        traffic_source       VARCHAR(1000),   -- marketing channel the customer came from
        promo_code           VARCHAR(1000),   -- discount/promotion code used, if any
        is_trial             VARCHAR(1000),   -- whether the purchase started with a trial, e.g. Y/N, true/false
        last_updated         VARCHAR(1000)    -- when the record was last changed at the source
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'    : RFC 4180 CSV parsing, so quoted fields containing commas load correctly
    --                       (cancel reasons may contain commas)
    --   FIRSTROW = 2      : skip the header row
    --   FIELDQUOTE = '"'  : character that wraps quoted fields
    --   CODEPAGE = '65001': read the file as UTF-8
    --   TABLOCK           : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #purchases_stage
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
    SELECT @staged_count = COUNT(*) FROM #purchases_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50041, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.purchases_snapshot
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty CSV fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.purchases_snapshot
        (
            purchase_id, customer_id, merchant_id, site_id, package_id,
            purchase_date, purchase_status, cancel_date, cancel_reason,
            cancel_initiated_by, next_rebill_date, rebill_count,
            affiliate_id, traffic_source, promo_code, is_trial, last_updated,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(purchase_id, ''),
            NULLIF(customer_id, ''),
            NULLIF(merchant_id, ''),
            NULLIF(site_id, ''),
            NULLIF(package_id, ''),
            NULLIF(purchase_date, ''),
            NULLIF(purchase_status, ''),
            NULLIF(cancel_date, ''),
            NULLIF(cancel_reason, ''),
            NULLIF(cancel_initiated_by, ''),
            NULLIF(next_rebill_date, ''),
            NULLIF(rebill_count, ''),
            NULLIF(affiliate_id, ''),
            NULLIF(traffic_source, ''),
            NULLIF(promo_code, ''),
            NULLIF(is_trial, ''),
            NULLIF(last_updated, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #purchases_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50043, 'Loaded row count does not match staged row count.', 1;

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
