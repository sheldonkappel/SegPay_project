/* =====================================================================================
   Procedure : bronze.usp_load_helpdesk_tickets
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads the support helpdesk ticket export into bronze.helpdesk_tickets exactly as
     received.
     Each row is one customer support ticket: who raised it, the order it relates to,
     which brand/site it came from, its category, priority and status, when it was
     created and solved, how long the first reply took, the customer satisfaction
     (CSAT) score, the agent assigned, the contact channel, and any tags.
     Tickets are later linked to customers and transactions (e.g. to see which
     refunds or chargebacks were preceded by a support contact).
     This table contains personal data (requester_email); restrict access to it
     accordingly.
     No business cleaning or type conversion is done here (no date parsing, numeric
     checks, or code mapping); that happens in silver. The only change made to the
     data is that empty strings are stored as NULL.

   File format
     Unlike the other exports, this file is SEMICOLON-delimited (;) with values in
     double quotes. Semicolons are used so that commas inside values (for example in
     tags) do not split columns.

   Parameters
     @file_path      Full path to the file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Defaults to the
                     local support export.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'helpdesk_tickets_export'.

   Behavior
     1. Bulk loads the file into a temporary staging table (all columns as text).
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
     source_file_name  file name extracted from @file_path (e.g. helpdesk_tickets.csv)
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.helpdesk_tickets)

   Errors raised
     50181  CSV file was empty or could not be read
     50183  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50182 - non-numeric first_reply_minutes - was removed; that check now belongs in silver)

   Requirements
     - SQL Server 2017+ (BULK INSERT FORMAT = 'CSV')
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.helpdesk_tickets.first_reply_minutes must be a text column (VARCHAR)

   Usage
     EXEC bronze.usp_load_helpdesk_tickets;                                 -- default file
     EXEC bronze.usp_load_helpdesk_tickets @file_path = N'C:\Data\helpdesk_tickets.csv';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_helpdesk_tickets]
    @file_path     NVARCHAR(500) = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\support\helpdesk_tickets.csv',
    @source_system VARCHAR(50)   = 'helpdesk_tickets_export'
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
    -- e.g. 'C:\...\support\helpdesk_tickets.csv' -> 'helpdesk_tickets.csv'
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- rows read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Stage the raw file as text
    -- Temporary table (#) that exists only for this procedure call.
    -- Columns map by position, so they must match the file's column order exactly;
    -- the header text itself is ignored.
    -- Everything is VARCHAR(1000) so one bad value can't fail the whole bulk load.
    ------------------------------------------------------------
    CREATE TABLE #tickets_stage
    (
        ticket_id            VARCHAR(1000),   -- helpdesk ticket number
        requester_email      VARCHAR(1000),   -- email of the person who raised the ticket (personal data)
        order_ref            VARCHAR(1000),   -- order/transaction the ticket is about, if given
        brand_domain         VARCHAR(1000),   -- website/brand the customer bought from
        category             VARCHAR(1000),   -- ticket topic, e.g. billing, cancellation, access
        priority             VARCHAR(1000),   -- e.g. low, normal, high, urgent
        status               VARCHAR(1000),   -- e.g. open, pending, solved, closed
        created_at           VARCHAR(1000),   -- when the ticket was opened
        solved_at            VARCHAR(1000),   -- when the ticket was solved (empty if still open)
        first_reply_minutes  VARCHAR(1000),   -- minutes until the first agent reply
        csat                 VARCHAR(1000),   -- customer satisfaction rating, if the customer gave one
        assignee             VARCHAR(1000),   -- support agent assigned to the ticket
        channel              VARCHAR(1000),   -- how the customer made contact, e.g. email, chat, phone
        tags                 VARCHAR(1000)    -- free-form labels, possibly several in one value
    );

    ------------------------------------------------------------
    -- Build and run the BULK INSERT
    -- REPLACE doubles any single quote in the path (e.g. O'Brien) so the dynamic SQL stays valid.
    --   FORMAT = 'CSV'         : RFC 4180 parsing, so quoted values load correctly
    --   FIELDTERMINATOR = ';'  : this file separates columns with semicolons, not commas
    --   FIELDQUOTE = '"'       : character that wraps each value
    --   FIRSTROW = 2           : skip the header row
    --   CODEPAGE = '65001'     : read the file as UTF-8
    --   TABLOCK                : take a table lock for a faster bulk load
    ------------------------------------------------------------
    SET @sql = N'
        BULK INSERT #tickets_stage
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (
            FORMAT = ''CSV'',
            FIELDTERMINATOR = '';'',
            FIELDQUOTE = ''"'',
            FIRSTROW = 2,
            CODEPAGE = ''65001'',
            TABLOCK
        );';

    -- Run the dynamic statement. The temp table is visible to it because
    -- sp_executesql runs inside the same session and scope chain.
    EXEC sys.sp_executesql @sql;

    ------------------------------------------------------------
    -- Validate the file produced data
    ------------------------------------------------------------
    SELECT @staged_count = COUNT(*) FROM #tickets_stage;

    -- An empty result usually means a header-only file or a wrong path/format;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50181, 'CSV file was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 2. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.helpdesk_tickets
        WHERE source_file_name = @file_name;

        -- Insert the staged rows plus load metadata.
        -- NULLIF(x, '') turns empty fields into NULL so "missing" is stored one way.
        -- No other transformation: every value is stored as text, exactly as sent.
        INSERT INTO bronze.helpdesk_tickets
        (
            ticket_id, requester_email, order_ref, brand_domain, category,
            priority, status, created_at, solved_at, first_reply_minutes,
            csat, assignee, channel, tags,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            NULLIF(ticket_id, ''),
            NULLIF(requester_email, ''),
            NULLIF(order_ref, ''),
            NULLIF(brand_domain, ''),
            NULLIF(category, ''),
            NULLIF(priority, ''),
            NULLIF(status, ''),
            NULLIF(created_at, ''),
            NULLIF(solved_at, ''),
            NULLIF(first_reply_minutes, ''),
            NULLIF(csat, ''),
            NULLIF(assignee, ''),
            NULLIF(channel, ''),
            NULLIF(tags, ''),
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #tickets_stage;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged row must have been inserted.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50183, 'Loaded row count does not match staged row count.', 1;

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
