/* =====================================================================================
   Procedure : bronze.usp_load_clearing_transactions
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads one acquirer clearing XML file into bronze.clearing_transactions exactly as
     received.
     Clearing is the step after authorization where the acquirer (the merchant's bank)
     confirms which card transactions are being settled, for how much, and the
     interchange fee charged on each. Each file holds one batch for one acquirer and
     one month:
         <ClearingBatch acquirer="..." period="YYYY-MM" itemCount="n">
             <Item> MID, AuthDate, ClearDate, BIN, Last4,
                    Amount (@ccy, @minor), Interchange, ARN </Item>
         </ClearingBatch>
     No business cleaning or type conversion is done here (no date/amount parsing,
     no flag mapping, no minor-unit conversion); that happens in silver. Every value
     is stored as text, exactly as it appears in the XML.

   Parameters
     @file_path  Full path to the XML file, as seen by the SQL Server service
                 (OPENROWSET BULK runs on the server, not the client). Required.

   Behavior
     1. Reads the whole XML file into a variable.
     2. Stops with an error if the file is empty or unreadable.
     3. Reads the batch header attributes: acquirer, period, itemCount.
     4. In one transaction:
          - deletes any rows previously loaded for the same acquirer + period
            (so re-loading a batch replaces it instead of duplicating it)
          - inserts one row per <Item>, with the batch header values repeated on
            each row, plus load metadata (source system, file name, file path, batch ID)
          - if itemCount is a number, checks the inserted row count matches it
     5. Any error rolls back the transaction, leaving bronze as it was.

   Columns written
     acquirer, batch_period, batch_item_count   from the <ClearingBatch> attributes
     mid, arn, auth_date, clear_date, bin, last4, amount, interchange
                                                text of the matching <Item> child elements
     currency_code                              Amount/@ccy attribute
     is_minor_unit                              Amount/@minor attribute, raw ('Y' / 'N')
                                                Y = amount is in minor units (e.g. 795 = 7.95)
     source_system                              always 'acquirer_clearing'
     source_file_name                           file name extracted from @file_path
     source_file_path                           full @file_path
     batch_id                                   new GUID generated for each run
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.clearing_transactions)

   Errors raised
     50001  XML file was empty or could not be read
     50002  Loaded row count does not match batch itemCount
     plus any OPENROWSET / XML parsing error (e.g. file not found, malformed XML)

   Requirements
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role) for OPENROWSET BULK
     - SQL Server service account must have read access to @file_path
     - bronze.clearing_transactions data columns must be text (NVARCHAR)

   Usage
     EXEC bronze.usp_load_clearing_transactions
          @file_path = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\acquirer_clearing\clearing_EUROSETTLE_202410.xml';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_clearing_transactions]
    @file_path NVARCHAR(500)
AS
BEGIN
    -- Suppress "(n rows affected)" messages so callers only see real results/errors
    SET NOCOUNT ON;

    -- Any run-time error aborts the batch and rolls back an open transaction
    SET XACT_ABORT ON;

    ------------------------------------------------------------
    -- Variables
    ------------------------------------------------------------
    DECLARE @xml_data XML;                    -- the whole file, parsed as XML
    DECLARE @sql NVARCHAR(MAX);               -- dynamic OPENROWSET statement (it cannot take a variable path directly)
    DECLARE @acquirer NVARCHAR(100);          -- <ClearingBatch acquirer="...">, raw text
    DECLARE @period NVARCHAR(50);             -- <ClearingBatch period="...">, raw text (e.g. '2024-10')
    DECLARE @item_count_raw NVARCHAR(50);     -- <ClearingBatch itemCount="...">, raw text as stored in bronze
    DECLARE @expected_count INT;              -- itemCount as a number, used only for the row-count check
    DECLARE @loaded_count INT;                -- rows inserted into bronze

    -- Unique ID for this run; stamped on every row so one load can be identified or removed later
    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();

    -- File name only, taken from the full path:
    -- REVERSE the path, find the first '\' (the last one in the original), take everything after it.
    -- The appended '\' makes it work even if @file_path contains no folder.
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    ------------------------------------------------------------
    -- 1. Read the file
    -- OPENROWSET(BULK ..., SINGLE_BLOB) returns the whole file as one value (BulkColumn).
    -- SINGLE_BLOB reads raw bytes, so SQL Server honors the encoding declared in the
    -- XML header (e.g. UTF-8) when converting to XML.
    -- The path must be written into the SQL text, so single quotes are doubled
    -- (e.g. O'Brien -> O''Brien) to keep the statement valid.
    -- The parsed XML is passed back out through the @xml OUTPUT parameter.
    ------------------------------------------------------------
    SET @sql = N'
        SELECT @xml = CONVERT(XML, BulkColumn)
        FROM OPENROWSET(
            BULK ''' + REPLACE(@file_path, '''', '''''') + ''',
            SINGLE_BLOB
        ) AS xml_file;';

    EXEC sys.sp_executesql
        @sql,
        N'@xml XML OUTPUT',
        @xml = @xml_data OUTPUT;

    -- Stop before touching bronze if nothing was read
    IF @xml_data IS NULL
        THROW 50001, 'XML file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- Batch header attributes
    -- XPath '(/ClearingBatch/@name)[1]' = the attribute on the root element.
    -- All read as text; itemCount is also converted (TRY_CAST) for the row-count check only.
    ------------------------------------------------------------
    SET @acquirer       = @xml_data.value('(/ClearingBatch/@acquirer)[1]',  'NVARCHAR(100)');
    SET @period         = @xml_data.value('(/ClearingBatch/@period)[1]',    'NVARCHAR(50)');
    SET @item_count_raw = @xml_data.value('(/ClearingBatch/@itemCount)[1]', 'NVARCHAR(50)');
    SET @expected_count = TRY_CAST(@item_count_raw AS INT);   -- NULL if missing or not a number

    ------------------------------------------------------------
    -- 2. Replace this batch's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- A batch is identified by acquirer + period (one file per acquirer per month).
        -- Remove any earlier load of the same batch so re-running replaces it.
        DELETE FROM bronze.clearing_transactions
        WHERE acquirer = @acquirer
          AND batch_period = @period;

        -- One row per <Item>. .nodes() splits the XML into a row set (one row per Item);
        -- .value() pulls each child element's text or attribute as NVARCHAR, unchanged.
        INSERT INTO bronze.clearing_transactions
        (
            acquirer, batch_period, batch_item_count,
            mid, arn, auth_date, clear_date,
            bin, last4, amount, currency_code, is_minor_unit, interchange,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            @acquirer,                                                      -- batch header, repeated per row
            @period,
            @item_count_raw,
            item.value('(MID/text())[1]',         'NVARCHAR(100)'),         -- merchant ID at the acquirer
            item.value('(ARN/text())[1]',         'NVARCHAR(100)'),         -- Acquirer Reference Number
            item.value('(AuthDate/text())[1]',    'NVARCHAR(100)'),         -- authorization date, as written
            item.value('(ClearDate/text())[1]',   'NVARCHAR(100)'),         -- clearing date, as written
            item.value('(BIN/text())[1]',         'NVARCHAR(100)'),         -- first 6/8 card digits
            item.value('(Last4/text())[1]',       'NVARCHAR(100)'),         -- last 4 card digits
            item.value('(Amount/text())[1]',      'NVARCHAR(100)'),         -- amount, as written (see is_minor_unit)
            item.value('(Amount/@ccy)[1]',        'NVARCHAR(100)'),         -- currency attribute on <Amount>
            item.value('(Amount/@minor)[1]',      'NVARCHAR(100)'),         -- raw 'Y'/'N' minor-units flag
            item.value('(Interchange/text())[1]', 'NVARCHAR(100)'),         -- interchange fee, as written
            'acquirer_clearing',                                            -- source system label
            @file_name,                                                     -- file name only
            @file_path,                                                     -- full path at load time
            @batch_id                                                       -- this run's ID
        FROM @xml_data.nodes('/ClearingBatch/Item') AS x(item);

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Integrity check: the file says how many items it contains (itemCount).
        -- If that number is present and doesn't match, the file is incomplete or corrupt,
        -- so THROW jumps to CATCH and the delete + insert are rolled back.
        -- If itemCount is missing or not a number, the check is skipped; silver can flag it.
        IF @expected_count IS NOT NULL AND @loaded_count <> @expected_count
            THROW 50002, 'Loaded row count does not match batch itemCount.', 1;

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
