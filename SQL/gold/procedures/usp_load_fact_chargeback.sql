/* =====================================================================
   Procedure : gold.usp_load_fact_chargeback
   Source    : silver.chargebacks_acquirer_feed (+ gold.fact_transaction for
               the disputed transaction's site, package, customer, affiliate)
   Target    : gold.fact_chargeback   (one row per dispute case)
   Load type : Full rebuild - truncated and reloaded each run.

   Purpose
   -------
   Every chargeback case the acquirers report: why it was disputed, how
   much, how fast it arrived after the sale, and how it was resolved.

   Keys
   ----
     received_date_key / orig_txn_date_key / resolution_date_key
     merchant_key           merchant version in effect on the original sale date
     merchant_account_key   via mid
     chargeback_reason_key  via network + reason code
     card_bin_key           first 6 digits of the card
     site_key, package_key, customer_key, affiliate_key
                            from the disputed transaction (txn_ref) when it is
                            found in gold.fact_transaction; otherwise -1
   Missing references -> -1 (Unknown).

   Flags and measures
   ------------------
     is_open / is_won / is_lost  outcome NULL / Won / Lost or Accepted
     is_linked_to_txn            the disputed transaction was found
     days_sale_to_dispute        received_date - orig_txn_date
     days_to_respond             respond_by - received_date (deadline window)
     days_to_resolution          resolution_date - received_date

   Dependencies (load first)
   -------------------------
     gold dimensions, gold.fact_transaction

   Usage
   -----
     EXEC gold.usp_load_fact_chargeback;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_fact_chargeback
    @run_id UNIQUEIDENTIFIER = NULL     -- set by gold.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'gold.fact_chargeback',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Today     DATE         = CAST(SYSUTCDATETIME() AS DATE),
            @Source    INT,
            @Loaded    INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'gold.fact_chargeback does not exist - run SQL\gold\01_gold_tables.sql first.', 1;

        SELECT @Source = COUNT(*) FROM silver.chargebacks_acquirer_feed;

        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_chargeback;

        INSERT gold.fact_chargeback WITH (TABLOCK) (
            case_id, received_date_key, orig_txn_date_key, resolution_date_key, merchant_key, merchant_account_key,
            chargeback_reason_key, card_bin_key, site_key, package_key, customer_key, affiliate_key,
            txn_id, arn, network, reason_code, status, outcome, dispute_amount, dispute_ccy, dispute_amount_usd,
            is_open, is_won, is_lost, is_representment_sent, is_linked_to_txn,
            days_sale_to_dispute, days_to_respond, days_to_resolution, load_run_id)
        SELECT
            c.case_id,
            COALESCE(YEAR(c.received_date)   * 10000 + MONTH(c.received_date)   * 100 + DAY(c.received_date),   -1),
            COALESCE(YEAR(c.orig_txn_date)   * 10000 + MONTH(c.orig_txn_date)   * 100 + DAY(c.orig_txn_date),   -1),
            COALESCE(YEAR(c.resolution_date) * 10000 + MONTH(c.resolution_date) * 100 + DAY(c.resolution_date), -1),
            COALESCE(dm.merchant_key, -1),
            COALESCE(ma.merchant_account_key, -1),
            COALESCE(cr.chargeback_reason_key, -1),
            COALESCE(db.card_bin_key, -1),
            COALESCE(ft.site_key, -1),
            COALESCE(ft.package_key, -1),
            COALESCE(ft.customer_key, -1),
            COALESCE(ft.affiliate_key, -1),
            ft.txn_id,
            c.arn, c.network, c.reason_code, c.status, c.outcome,
            c.dispute_amount, c.dispute_ccy, c.dispute_amount_usd,
            CAST(CASE WHEN c.outcome IS NULL THEN 1 ELSE 0 END AS BIT),
            CAST(CASE WHEN c.outcome = 'Won' THEN 1 ELSE 0 END AS BIT),
            CAST(CASE WHEN c.outcome IN ('Lost', 'Accepted') THEN 1 ELSE 0 END AS BIT),
            c.is_representment_sent,
            CAST(CASE WHEN ft.txn_id IS NOT NULL THEN 1 ELSE 0 END AS BIT),
            DATEDIFF(DAY, c.orig_txn_date, c.received_date),
            DATEDIFF(DAY, c.received_date, c.respond_by),
            DATEDIFF(DAY, c.received_date, c.resolution_date),
            @run_id
        FROM silver.chargebacks_acquirer_feed c
        LEFT JOIN gold.fact_transaction ft ON ft.txn_id = c.txn_ref
        -- Merchant version in effect on the original sale date
        LEFT JOIN gold.dim_merchant dm
               ON dm.merchant_id = c.merchant_id
              AND COALESCE(c.orig_txn_date, @Today) BETWEEN dm.valid_from AND dm.valid_to
        LEFT JOIN gold.dim_merchant_account  ma ON ma.mid = c.mid
        LEFT JOIN gold.dim_chargeback_reason cr ON cr.network = c.network AND cr.reason_code = c.reason_code
        LEFT JOIN gold.dim_card_bin          db ON db.bin = LEFT(c.card_bin, 6);

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT SourceRows        = @Source,
               FactRows          = @Loaded,
               LinkedToTxn       = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE is_linked_to_txn = 1),
               UnknownReason     = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE chargeback_reason_key = -1),
               UnknownMerchant   = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE merchant_key = -1),
               OpenCases         = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE is_open = 1),
               WonCases          = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE is_won = 1),
               LostCases         = (SELECT COUNT(*) FROM gold.fact_chargeback WHERE is_lost = 1),
               DisputedUsd       = (SELECT SUM(dispute_amount_usd) FROM gold.fact_chargeback)
        INTO #summary;

        SET @Dropped = @Source - @Loaded;
        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC audit.usp_log_load @run_id = @run_id, @proc_name = @ProcName, @target_table = @Target,
             @started_at = @StartedAt, @status = 'Succeeded', @rows_read = @Source, @rows_loaded = @Loaded,
             @rows_dropped = @Dropped, @metrics = @Metrics;

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
