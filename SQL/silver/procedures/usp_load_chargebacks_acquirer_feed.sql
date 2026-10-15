/* =====================================================================
   Procedure : silver.usp_load_chargebacks_acquirer_feed
   Source    : bronze.chargebacks_acquirer_feed   (raw text, acquirer dispute feed)
   Target    : silver.chargebacks_acquirer_feed   (cleaned, one row per case)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A chargeback is a cardholder disputing a charge through their bank. Each
   case records the network reason code, the disputed transaction and
   amount, deadlines, and how the dispute was resolved.

   Key terms
   ---------
   ARN            : Acquirer Reference Number - links the case to the cleared sale.
   MID            : the merchant's account ID at the acquirer.
   Representment  : the merchant's evidence sent to fight the dispute.

   Transformations
   ---------------
     * case_id            : trimmed. Rows without one are skipped.
     * network            : one name per network via ref.card_brand_alias.
     * reason_code        : hidden characters removed, network prefix removed
                            ('VI-13.2' -> '13.2'), uppercased.
     * reason_category,
       reason_desc        : from silver.chargeback_reason_codes - matched on
                            network + code, else on the description text.
     * mid                : trimmed.
     * merchant_id        : from silver.merchant_accounts via mid.
     * merchant_descriptor: uppercased, spaces around '*' removed; the part
                            after '*' in merchant_descriptor_name.
     * txn_ref            : whole number (= silver.transactions.txn_id).
     * dispute_amount     : util.fn_parse_amount; 2 decimals; always positive
                            (45 cases arrive in accounting notation, '(67.95)').
     * dispute_amount_usd : converted with the most recent US Treasury rate on
                            or before orig_txn_date; USD unchanged; no rate -> NULL.
     * fx_rate, fx_rate_date : the rate used.
     * dates              : any supported format (util.fn_parse_date).
     * status, outcome    : capitalized ('LOST' -> 'Lost').
     * is_representment_sent : 1 when a representment date is present.
     * Test data          : cases on test merchants' accounts excluded.
     * Duplicates         : one row per case - newest bronze load, then latest
                            resolution date.
     * Missing values     : NULL.
     * Lineage            : bronze source columns, load_run_id, silver_loaded_at.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; merchant_id added (every MID is in
                 merchant_accounts); shared date / amount / network lookups;
                 test-merchant rule; audit logging.

   Usage
   -----
     EXEC silver.usp_load_chargebacks_acquirer_feed;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_chargebacks_acquirer_feed
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.chargebacks_acquirer_feed',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Bronze    INT,
            @Test      INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.chargebacks_acquirer_feed does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.chargebacks_acquirer_feed;

        SELECT @Test = COUNT(*)
        FROM bronze.chargebacks_acquirer_feed b
        JOIN silver.merchant_accounts ma ON ma.mid = TRIM(b.mid)
        WHERE ma.merchant_id IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        -- US Treasury rates, indexed for the per-case lookup
        SELECT currency, rate_date, usd_per_unit
        INTO #fx
        FROM silver.fx_rates_daily;
        CREATE CLUSTERED INDEX CX_fx ON #fx (currency, rate_date);

        BEGIN TRAN;

        TRUNCATE TABLE silver.chargebacks_acquirer_feed;

        WITH c AS (
            SELECT
                b.*,
                cb.card_brand                                          AS network_clean,
                CASE WHEN x.rc LIKE '[A-Z][A-Z]-%' THEN SUBSTRING(x.rc, 4, 50) ELSE x.rc END AS reason_code_clean,
                -- Disputed amount is always positive; '(67.95)' is accounting notation for a debit
                CAST(ABS(am.amount) AS DECIMAL(18,2))                  AS dispute_amount_clean,
                UPPER(TRIM(b.dispute_ccy))                             AS dispute_ccy_clean,
                od.date_us_first                                       AS orig_txn_date_clean
            FROM bronze.chargebacks_acquirer_feed b
            -- Reason code with tabs, non-breaking spaces, CR and LF removed
            CROSS APPLY (SELECT rc = UPPER(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
                             b.reason_code, CHAR(9), ''), CHAR(160), ''), CHAR(13), ''), CHAR(10), '')))) x
            CROSS APPLY util.fn_parse_amount(b.dispute_amount) am
            CROSS APPLY util.fn_parse_date(b.orig_txn_date) od
            LEFT JOIN ref.card_brand_alias cb ON cb.alias = UPPER(TRIM(b.network))
        ),
        s AS (
            SELECT
                NULLIF(TRIM(c.case_id), '')                            AS case_id,
                c.network_clean                                        AS network,
                NULLIF(c.reason_code_clean, '')                        AS reason_code,
                COALESCE(rc.category,    rcd.category)                 AS reason_category,
                COALESCE(rc.description, rcd.description, NULLIF(TRIM(c.reason_desc), '')) AS reason_desc,
                NULLIF(TRIM(c.arn), '')                                AS arn,
                NULLIF(TRIM(c.mid), '')                                AS mid,
                ma.merchant_id,
                NULLIF(REPLACE(REPLACE(UPPER(TRIM(c.merchant_descriptor)), ' *', '*'), '* ', '*'), '') AS merchant_descriptor,
                CASE WHEN CHARINDEX('*', c.merchant_descriptor) > 0
                     THEN NULLIF(TRIM(SUBSTRING(UPPER(c.merchant_descriptor), CHARINDEX('*', c.merchant_descriptor) + 1, 200)), '')
                END                                                    AS merchant_descriptor_name,
                TRY_CAST(TRIM(c.txn_ref) AS BIGINT)                    AS txn_ref,
                NULLIF(TRIM(c.card_bin), '')                           AS card_bin,
                NULLIF(TRIM(c.card_last4), '')                         AS card_last4,
                c.orig_txn_date_clean                                  AS orig_txn_date,
                c.dispute_amount_clean                                 AS dispute_amount,
                CASE WHEN c.dispute_ccy_clean LIKE '[A-Z][A-Z][A-Z]' THEN c.dispute_ccy_clean END AS dispute_ccy,
                CASE WHEN c.dispute_ccy_clean = 'USD' THEN c.dispute_amount_clean
                     ELSE CAST(ROUND(c.dispute_amount_clean * r.usd_per_unit, 2) AS DECIMAL(18,2)) END AS dispute_amount_usd,
                r.usd_per_unit                                         AS fx_rate,
                r.rate_date                                            AS fx_rate_date,
                rd.date_us_first                                       AS received_date,
                rb.date_us_first                                       AS respond_by,
                NULLIF(UPPER(LEFT(TRIM(c.status), 1))  + LOWER(SUBSTRING(TRIM(c.status), 2, 50)), '')  AS status,
                rs.date_us_first                                       AS resolution_date,
                NULLIF(UPPER(LEFT(TRIM(c.outcome), 1)) + LOWER(SUBSTRING(TRIM(c.outcome), 2, 50)), '') AS outcome,
                rp.date_us_first                                       AS representment_sent_date,
                CAST(CASE WHEN NULLIF(TRIM(c.representment_sent), '') IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS is_representment_sent,
                c.source_system, c.source_file_name, c.batch_id,
                c.ingested_at                                          AS bronze_ingested_at,
                c.ingested_by
            FROM c
            CROSS APPLY util.fn_parse_date(c.received_date)      rd
            CROSS APPLY util.fn_parse_date(c.respond_by)         rb
            CROSS APPLY util.fn_parse_date(c.resolution_date)    rs
            CROSS APPLY util.fn_parse_date(c.representment_sent) rp
            LEFT JOIN silver.merchant_accounts ma ON ma.mid = NULLIF(TRIM(c.mid), '')
            -- 1st choice: reason matched on the cleaned network + code
            LEFT JOIN silver.chargeback_reason_codes rc
                   ON rc.network = c.network_clean AND rc.reason_code = c.reason_code_clean
            -- 2nd choice: matched on the description text (same network preferred)
            OUTER APPLY (
                SELECT TOP (1) xr.description, xr.category
                FROM silver.chargeback_reason_codes xr
                WHERE UPPER(xr.description) = UPPER(TRIM(c.reason_desc))
                ORDER BY CASE WHEN xr.network = c.network_clean THEN 0 ELSE 1 END
            ) rcd
            -- Most recent US Treasury rate on or before the transaction date (not for USD)
            OUTER APPLY (
                SELECT TOP (1) f.usd_per_unit, f.rate_date
                FROM #fx f
                WHERE c.dispute_ccy_clean <> 'USD'
                  AND f.currency  = c.dispute_ccy_clean
                  AND f.rate_date <= c.orig_txn_date_clean
                ORDER BY f.rate_date DESC
            ) r
            WHERE ISNULL(ma.merchant_id, '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY case_id ORDER BY bronze_ingested_at DESC, resolution_date DESC) AS rn
            FROM s
            WHERE case_id IS NOT NULL
        )
        INSERT silver.chargebacks_acquirer_feed (
            case_id, network, reason_code, reason_category, reason_desc, arn, mid, merchant_id,
            merchant_descriptor, merchant_descriptor_name, txn_ref, card_bin, card_last4,
            orig_txn_date, dispute_amount, dispute_ccy, dispute_amount_usd, fx_rate, fx_rate_date,
            received_date, respond_by, status, resolution_date, outcome,
            representment_sent_date, is_representment_sent,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            case_id, network, reason_code, reason_category, reason_desc, arn, mid, merchant_id,
            merchant_descriptor, merchant_descriptor_name, txn_ref, card_bin, card_last4,
            orig_txn_date, dispute_amount, dispute_ccy, dispute_amount_usd, fx_rate, fx_rate_date,
            received_date, respond_by, status, resolution_date, outcome,
            representment_sent_date, is_representment_sent,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows          = @Bronze,
               TestRowsExcluded    = @Test,
               SilverRows          = @Loaded,
               DuplicatesDropped   = @Bronze - @Test - @Loaded,
               UsdNotAvailable     = (SELECT COUNT(*) FROM silver.chargebacks_acquirer_feed WHERE dispute_amount IS NOT NULL AND dispute_amount_usd IS NULL),
               MerchantNotFound    = (SELECT COUNT(*) FROM silver.chargebacks_acquirer_feed WHERE merchant_id IS NULL),
               ReasonNotRecognized = (SELECT COUNT(*) FROM silver.chargebacks_acquirer_feed WHERE reason_category IS NULL),
               TxnNotInSilver      = (SELECT COUNT(*) FROM silver.chargebacks_acquirer_feed c
                                      WHERE c.txn_ref IS NOT NULL AND NOT EXISTS (SELECT 1 FROM silver.transactions t WHERE t.txn_id = c.txn_ref))
        INTO #summary;

        SET @Metrics  = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        SET @Excluded = @Test;
        SET @Dropped  = @Bronze - @Test - @Loaded;

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
