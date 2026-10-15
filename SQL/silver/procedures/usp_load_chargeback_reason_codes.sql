/* =====================================================================
   Procedure : silver.usp_load_chargeback_reason_codes
   Source    : bronze.chargeback_reason_codes   (raw text)
   Target    : silver.chargeback_reason_codes   (cleaned, one row per network + code)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Reference list of card-network chargeback reason codes (e.g. Visa 10.4
   "Other Fraud - Card Absent Environment"). silver.chargebacks_acquirer_feed
   takes its reason category and description from here. A code is only
   unique within its network, so the key is network + reason_code.

   Transformations
   ---------------
     * network     : one name per network via ref.card_brand_alias (same names
                     as silver.bin_reference.card_brand).
     * reason_code : trimmed and uppercased, kept as text ('10.40' stays as is).
     * description : trimmed.
     * category    : Fraud / Authorization / Processing Error / Consumer Dispute.
     * Duplicates  : one row per network + code - the newest bronze load wins.
                     Rows with an unmapped network or no code are skipped.
     * Missing / unrecognized values : NULL.
     * Lineage     : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared network lookup; audit logging.

   Usage
   -----
     EXEC silver.usp_load_chargeback_reason_codes;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_chargeback_reason_codes
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.chargeback_reason_codes',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.chargeback_reason_codes does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.chargeback_reason_codes;

        BEGIN TRAN;

        TRUNCATE TABLE silver.chargeback_reason_codes;

        WITH s AS (
            SELECT
                cb.card_brand                                       AS network,
                NULLIF(UPPER(TRIM(b.reason_code)), '')              AS reason_code,
                NULLIF(TRIM(b.description), '')                     AS description,
                CASE UPPER(TRIM(b.category))
                    WHEN 'FRAUD'            THEN 'Fraud'
                    WHEN 'AUTHORIZATION'    THEN 'Authorization'
                    WHEN 'PROCESSING ERROR' THEN 'Processing Error'
                    WHEN 'CONSUMER DISPUTE' THEN 'Consumer Dispute'
                END                                                 AS category,
                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                       AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.chargeback_reason_codes b
            LEFT JOIN ref.card_brand_alias cb ON cb.alias = UPPER(TRIM(b.network))
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY network, reason_code ORDER BY bronze_ingested_at DESC) AS rn
            FROM s
            WHERE network IS NOT NULL AND reason_code IS NOT NULL
        )
        INSERT silver.chargeback_reason_codes (
            network, reason_code, description, category,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            network, reason_code, description, category,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows        = @Bronze,
               SilverRows        = @Loaded,
               DuplicatesDropped = @Bronze - @Loaded,
               CategoryMissing   = (SELECT COUNT(*) FROM silver.chargeback_reason_codes WHERE category IS NULL)
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        SET @Excluded = 0;
        SET @Dropped  = @Bronze - @Loaded;

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
