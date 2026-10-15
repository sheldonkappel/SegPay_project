/* =====================================================================================
   Procedure : bronze.usp_load_risk_events
   Layer     : Bronze (raw ingestion)
   -------------------------------------------------------------------------------------
   Purpose
     Loads one fraud/risk engine event file into bronze.risk_events exactly as received.
     The risk engine scores each payment attempt for fraud. Each event records which
     transaction and purchase it relates to, the merchant, when it was scored, the
     engine version, the risk score, the decision (e.g. approve, review, decline),
     which rules fired, and the signals used (IP and card-issuing country, email age,
     recent attempt velocity, proxy detection, device ID).
     Events are later joined to transactions and chargebacks to measure how well the
     risk engine catches fraud.
     No business cleaning or type conversion is done here (no numeric, boolean or
     timestamp parsing); that happens in silver. Every value is stored as text,
     exactly as it appears in the JSON, and each original line is kept in raw_json.
     Lines that are not valid JSON are still stored (raw_json filled, other columns NULL)
     so nothing is lost; silver can find them with ISJSON(raw_json) = 0.

   File format
     JSON Lines (also called NDJSON): one complete JSON object per line, e.g.
       {"event_id":"...","txn_id":810000123,"score":87,"decision":"review",
        "rules_triggered":["velocity","geo_mismatch"],
        "signals":{"ip_country":"US","bin_country":"GB","proxy":true,...}}

   Parameters
     @file_path      Full path to the file, as seen by the SQL Server service
                     (BULK INSERT runs on the server, not the client). Required.
     @source_system  Label written to every row to record which system produced the
                     file. Defaults to 'risk_events_export'.

   Behavior
     1. Reads each line of the file into a one-column staging table.
     2. Removes Windows carriage returns and blank lines.
     3. Stops with an error if no lines remain.
     4. Extracts each JSON field as text (invalid JSON lines get NULL fields).
     5. In one transaction:
          - deletes any rows previously loaded from a file with the same name
            (so re-running a file replaces it instead of duplicating it)
          - inserts one row per line with load metadata
            (source system, file name, file path, batch ID)
          - checks the inserted row count equals the staged line count
     6. Any error rolls back the transaction, leaving bronze as it was.

   Metadata columns written
     source_system     from @source_system
     source_file_name  file name extracted from @file_path
     source_file_path  full @file_path
     batch_id          new GUID generated for each run; identifies all rows from this load
     raw_json          the original line, unchanged
     (ingested_at / ingested_by are not set here - they are expected to be filled
      by column defaults on bronze.risk_events)

   Errors raised
     50171  File was empty or could not be read
     50173  Loaded row count does not match staged row count
     plus any BULK INSERT error (e.g. file not found, access denied)
     (50172 - invalid JSON lines / invalid event_ts - was removed; invalid lines are
      now kept, and timestamp checks belong in silver)

   Requirements
     - SQL Server 2016+ (OPENJSON, ISJSON), database compatibility level 130 or higher
     - ADMINISTER BULK OPERATIONS permission (or bulkadmin role)
     - SQL Server service account must have read access to @file_path
     - bronze.risk_events parsed columns must be text columns (NVARCHAR)

   Usage
     EXEC bronze.usp_load_risk_events
          @file_path = N'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\risk\risk_events_202610.jsonl';
   ===================================================================================== */
CREATE OR ALTER PROCEDURE [bronze].[usp_load_risk_events]
    @file_path     NVARCHAR(500),
    @source_system VARCHAR(50) = 'risk_events_export'
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
    DECLARE @file_name NVARCHAR(260) =
        RIGHT(@file_path, CHARINDEX('\', REVERSE(@file_path) + '\') - 1);

    -- Row counts used for validation
    DECLARE @staged_count INT;   -- non-blank lines read from the file
    DECLARE @loaded_count INT;   -- rows inserted into bronze

    ------------------------------------------------------------
    -- 1. Read each line of the file into one text column
    -- The whole line goes into a single NVARCHAR(MAX) column.
    --   DATAFILETYPE = 'char' : plain text file
    --   CODEPAGE = '65001'    : read as UTF-8
    --   FIELDTERMINATOR 0x0b  : vertical tab - a character that never appears in the
    --                           data, so BULK INSERT never splits a line into columns
    --                           (JSON contains commas, so ',' can't be used)
    --   ROWTERMINATOR 0x0a    : line feed - each line of the file is one row
    --   TABLOCK               : take a table lock for a faster bulk load
    ------------------------------------------------------------
    CREATE TABLE #risk_lines (line NVARCHAR(MAX));

    SET @sql = N'
        BULK INSERT #risk_lines
        FROM ''' + REPLACE(@file_path, '''', '''''') + N'''
        WITH (
            DATAFILETYPE = ''char'',
            CODEPAGE = ''65001'',
            FIELDTERMINATOR = ''0x0b'',
            ROWTERMINATOR = ''0x0a'',
            TABLOCK
        );';

    -- Run the dynamic statement. The temp table is visible to it because
    -- sp_executesql runs inside the same session and scope chain.
    EXEC sys.sp_executesql @sql;

    ------------------------------------------------------------
    -- 2. Tidy the lines
    -- Windows files end each line with CR+LF; splitting on LF leaves a CR (CHAR(13))
    -- at the end of every line, so remove it. Blank lines (e.g. a trailing empty line
    -- at the end of the file) are not events, so delete them.
    ------------------------------------------------------------
    UPDATE #risk_lines SET line = REPLACE(line, CHAR(13), N'');
    DELETE FROM #risk_lines WHERE NULLIF(LTRIM(RTRIM(line)), N'') IS NULL;

    ------------------------------------------------------------
    -- 3. Validate the file produced data
    ------------------------------------------------------------
    SELECT @staged_count = COUNT(*) FROM #risk_lines;

    -- No lines usually means an empty file or a wrong path;
    -- stop before touching bronze so existing data is not deleted
    IF @staged_count = 0
        THROW 50171, 'File was empty or could not be read.', 1;

    ------------------------------------------------------------
    -- 4. Extract each JSON field as text
    -- OPENJSON ... WITH reads named properties from each line's JSON object.
    -- Every field is read as NVARCHAR, so values are kept exactly as written:
    --   numbers   -> '810000123', '87'
    --   booleans  -> 'true' / 'false'
    --   timestamp -> '2026-10-01T12:34:56Z'
    -- '$.signals.ip_country' reads a property inside the nested "signals" object.
    -- rules_triggered is an array, so AS JSON keeps it as JSON text, e.g. '["velocity","geo"]'.
    --
    -- OUTER APPLY keeps every line, even when nothing can be extracted.
    -- OPENJSON raises an error on invalid JSON, so it is only given lines that pass
    -- ISJSON; for other lines it receives NULL, returns no row, and the fields are NULL.
    ------------------------------------------------------------
    SELECT
        j.event_id,
        j.txn_id,
        j.purchase_id,
        j.merchant,
        j.event_ts,
        j.engine_version,
        j.score,
        j.decision,
        j.rules_triggered,
        j.signal_ip_country,
        j.signal_bin_country,
        j.signal_email_age_days,
        j.signal_velocity_1h,
        j.signal_proxy,
        j.signal_device_id,
        l.line AS raw_json                                   -- original line, unchanged
    INTO #risk_parsed
    FROM #risk_lines AS l
    OUTER APPLY OPENJSON(CASE WHEN ISJSON(l.line) = 1 THEN l.line END)
    WITH
    (
        event_id               NVARCHAR(400) '$.event_id',               -- unique ID of the risk event
        txn_id                 NVARCHAR(400) '$.txn_id',                 -- gateway transaction scored
        purchase_id            NVARCHAR(400) '$.purchase_id',            -- purchase the transaction belongs to
        merchant               NVARCHAR(400) '$.merchant',               -- merchant ID/name as sent by the engine
        event_ts               NVARCHAR(400) '$.event_ts',               -- when the event was scored
        engine_version         NVARCHAR(400) '$.engine_version',         -- risk engine/model version
        score                  NVARCHAR(400) '$.score',                  -- risk score (higher = riskier)
        decision               NVARCHAR(400) '$.decision',               -- e.g. approve, review, decline
        rules_triggered        NVARCHAR(MAX) '$.rules_triggered' AS JSON,-- array of rule names that fired
        signal_ip_country      NVARCHAR(400) '$.signals.ip_country',     -- country of the customer's IP
        signal_bin_country     NVARCHAR(400) '$.signals.bin_country',    -- country that issued the card
        signal_email_age_days  NVARCHAR(400) '$.signals.email_age_days', -- age of the email address in days
        signal_velocity_1h     NVARCHAR(400) '$.signals.velocity_1h',    -- attempts from this customer/card in the last hour
        signal_proxy           NVARCHAR(400) '$.signals.proxy',          -- whether a proxy/VPN was detected
        signal_device_id       NVARCHAR(400) '$.signals.device_id'       -- device fingerprint ID
    ) AS j;

    ------------------------------------------------------------
    -- 5. Replace this file's rows in bronze (all-or-nothing)
    ------------------------------------------------------------
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Remove rows from any earlier load of the same file name.
        -- Makes the procedure safe to re-run: the file's data is replaced, not duplicated.
        DELETE FROM bronze.risk_events
        WHERE source_file_name = @file_name;

        -- Insert one row per line plus load metadata.
        -- No transformation: every value is stored as text, exactly as extracted.
        INSERT INTO bronze.risk_events
        (
            event_id, txn_id, purchase_id, merchant, event_ts,
            engine_version, score, decision, rules_triggered,
            signal_ip_country, signal_bin_country, signal_email_age_days,
            signal_velocity_1h, signal_proxy, signal_device_id, raw_json,
            source_system, source_file_name, source_file_path, batch_id
        )
        SELECT
            event_id, txn_id, purchase_id, merchant, event_ts,
            engine_version, score, decision, rules_triggered,
            signal_ip_country, signal_bin_country, signal_email_age_days,
            signal_velocity_1h, signal_proxy, signal_device_id, raw_json,
            @source_system,    -- which system produced the file
            @file_name,        -- file name only
            @file_path,        -- full path at load time
            @batch_id          -- this run's ID
        FROM #risk_parsed;

        -- Rows inserted by the statement above (read immediately, before it is reset)
        SET @loaded_count = @@ROWCOUNT;

        -- Safety check: every staged line must have produced exactly one row.
        -- If not, THROW jumps to CATCH and the delete + insert are rolled back.
        IF @loaded_count <> @staged_count
            THROW 50173, 'Loaded row count does not match staged row count.', 1;

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
