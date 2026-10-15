/* =====================================================================
   Procedure : silver.usp_load_helpdesk_tickets
   Source    : bronze.helpdesk_tickets   (raw text, support desk export)
   Target    : silver.helpdesk_tickets   (cleaned, one row per ticket)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Customer support tickets: what the customer contacted support about
   (cancellations, refunds, unrecognized charges, ...), how quickly it was
   answered and solved, and satisfaction. order_id links to the purchase.

   Transformations
   ---------------
     * ticket_id           : trimmed and uppercased. Rows without one are skipped.
     * requester_email     : trimmed and lowercased.
     * order_ref           : as written, uppercased (SP-4140960).
     * order_id            : the number after 'SP-' (= purchase_id; verified
                             2026-10-15: all 8,650 exist in purchases and
                             transactions).
     * brand_domain        : lowercase, without http(s):// or www.
     * category            : trimmed.
     * priority, status,
       csat                : capitalized ('urgent' -> 'Urgent').
     * created_at,
       solved_at           : DD/MM/YYYY hh:mm (day first, as the helpdesk
                             exports it) -> YYYY-MM-DD hh:mm:ss.
     * first_reply_minutes : whole number.
     * resolution_minutes  : minutes from created_at to solved_at (NULL if
                             missing or negative).
     * assignee            : lowercase username; agent_unassigned -> Unassigned.
     * channel             : Email / Phone / Chat / Web Form.
     * tags                : lowercase, '|'-separated, no spaces around '|'.
     * Duplicates          : one row per ticket - the newest bronze load wins.
     * Missing values      : NULL.
     * Lineage             : bronze source columns, load_run_id, silver_loaded_at.

   PII
   ---
   requester_email is masked for users without UNMASK permission.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; order_id mapping verified (was
                 marked as an assumption); audit logging.

   Usage
   -----
     EXEC silver.usp_load_helpdesk_tickets;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_helpdesk_tickets
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.helpdesk_tickets',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT = 0,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.helpdesk_tickets does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.helpdesk_tickets;

        BEGIN TRAN;

        TRUNCATE TABLE silver.helpdesk_tickets;

        WITH s AS (
            SELECT
                NULLIF(UPPER(TRIM(b.ticket_id)), '')                   AS ticket_id,
                NULLIF(LOWER(TRIM(b.requester_email)), '')             AS requester_email,
                NULLIF(x.oref, '')                                     AS order_ref,
                CASE WHEN x.oref LIKE 'SP-%' THEN TRY_CAST(SUBSTRING(x.oref, 4, 30) AS BIGINT) END AS order_id,
                NULLIF(REPLACE(REPLACE(REPLACE(LOWER(TRIM(b.brand_domain)), 'https://', ''), 'http://', ''), 'www.', ''), '') AS brand_domain,
                NULLIF(TRIM(b.category), '')                           AS category,
                NULLIF(UPPER(LEFT(TRIM(b.priority), 1)) + LOWER(SUBSTRING(TRIM(b.priority), 2, 50)), '') AS priority,
                NULLIF(UPPER(LEFT(TRIM(b.status), 1))   + LOWER(SUBSTRING(TRIM(b.status), 2, 50)), '')   AS status,
                x.created_dt                                           AS created_at,
                x.solved_dt                                            AS solved_at,
                TRY_CAST(TRIM(b.first_reply_minutes) AS INT)           AS first_reply_minutes,
                CASE WHEN x.solved_dt >= x.created_dt THEN DATEDIFF(MINUTE, x.created_dt, x.solved_dt) END AS resolution_minutes,
                NULLIF(UPPER(LEFT(TRIM(b.csat), 1)) + LOWER(SUBSTRING(TRIM(b.csat), 2, 50)), '') AS csat,
                CASE WHEN LOWER(TRIM(b.assignee)) = 'agent_unassigned' THEN 'Unassigned'
                     ELSE NULLIF(LOWER(TRIM(b.assignee)), '') END      AS assignee,
                CASE LOWER(TRIM(b.channel))
                    WHEN 'email'    THEN 'Email'
                    WHEN 'phone'    THEN 'Phone'
                    WHEN 'chat'     THEN 'Chat'
                    WHEN 'web_form' THEN 'Web Form'
                    ELSE NULLIF(UPPER(LEFT(TRIM(b.channel), 1)) + LOWER(SUBSTRING(TRIM(b.channel), 2, 50)), '')
                END                                                    AS channel,
                NULLIF(REPLACE(REPLACE(LOWER(TRIM(b.tags)), ' |', '|'), '| ', '|'), '') AS tags,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.helpdesk_tickets b
            CROSS APPLY (
                SELECT
                    oref       = UPPER(TRIM(b.order_ref)),
                    -- DD/MM/YYYY hh:mm (day first) -> style 103
                    created_dt = CASE WHEN TRIM(b.created_at) LIKE '[0-3][0-9]/[01][0-9]/[12][0-9][0-9][0-9]%'
                                      THEN TRY_CONVERT(DATETIME2(0), TRIM(b.created_at), 103) END,
                    solved_dt  = CASE WHEN TRIM(b.solved_at)  LIKE '[0-3][0-9]/[01][0-9]/[12][0-9][0-9][0-9]%'
                                      THEN TRY_CONVERT(DATETIME2(0), TRIM(b.solved_at), 103) END
            ) x
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE ticket_id IS NOT NULL
        )
        INSERT silver.helpdesk_tickets (
            ticket_id, requester_email, order_ref, order_id, brand_domain, category, priority, status,
            created_at, solved_at, first_reply_minutes, resolution_minutes, csat, assignee, channel, tags,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT ticket_id, requester_email, order_ref, order_id, brand_domain, category, priority, status,
               created_at, solved_at, first_reply_minutes, resolution_minutes, csat, assignee, channel, tags,
               source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded,
               OrderIdMissing    = (SELECT COUNT(*) FROM silver.helpdesk_tickets WHERE order_id IS NULL),
               CreatedAtMissing  = (SELECT COUNT(*) FROM silver.helpdesk_tickets WHERE created_at IS NULL)
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Dropped = @Bronze - @Loaded;

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Bronze, @rows_loaded = @Loaded,
             @rows_excluded = @Excluded, @rows_dropped = @Dropped, @metrics = @Metrics;

        SELECT * FROM #summary;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @Err = ERROR_MESSAGE();
        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Failed', @error_message = @Err;
        THROW;
    END CATCH
END
GO
