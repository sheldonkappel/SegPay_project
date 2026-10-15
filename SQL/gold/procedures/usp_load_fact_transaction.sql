/* =====================================================================
   Procedure : gold.usp_load_fact_transaction
   Source    : silver.transactions (+ silver.risk_events for the fraud score)
   Target    : gold.fact_transaction   (one row per payment event)
   Load type : Full rebuild - truncated and reloaded from silver each run.

   Purpose
   -------
   The central fact: every sale, rebill, auth, refund, void and chargeback
   from both gateways, keyed to the gold dimensions, in USD.

   Keys
   ----
     date_key              transaction date (UTC)
     merchant_key          the merchant VERSION in effect on that date
                           (gold.dim_merchant keeps history), so e.g. the
                           risk tier shown is the one the merchant had then
     merchant_account_key  via mid
     site_key, package_key, customer_key, affiliate_key, card_bin_key
                           (card_bin6), response_code_key
   Any reference not found in its dimension -> -1 (Unknown), so no
   transaction drops out of a report.

   Measures and flags
   ------------------
     amount / amount_usd   signed: refunds, voids, chargebacks negative
     is_approved           status = Approved
     is_revenue            approved Sale or Rebill
     revenue_usd           amount_usd for revenue rows, else 0
     risk_score / risk_decision  from the fraud engine (one event per
                           transaction; NULL when not scored)

   Dependencies (load first)
   -------------------------
     all gold dimensions; silver.transactions; silver.risk_events

   Usage
   -----
     EXEC gold.usp_load_fact_transaction;
   ===================================================================== */
CREATE OR ALTER PROCEDURE gold.usp_load_fact_transaction
    @run_id UNIQUEIDENTIFIER = NULL     -- set by gold.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'gold.fact_transaction',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Today     DATE         = CAST(SYSUTCDATETIME() AS DATE),
            @Source    INT,
            @Loaded    INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'gold.fact_transaction does not exist - run SQL\gold\01_gold_tables.sql first.', 1;

        SELECT @Source = COUNT(*) FROM silver.transactions;

        BEGIN TRAN;

        TRUNCATE TABLE gold.fact_transaction;

        -- TABLOCK lets the columnstore index compress the rows as they load
        INSERT gold.fact_transaction WITH (TABLOCK) (
            txn_id, date_key, merchant_key, merchant_account_key, site_key, package_key, customer_key,
            affiliate_key, card_bin_key, response_code_key, txn_ts_utc, purchase_id, parent_txn_id,
            txn_type, status, payment_method, card_brand, currency, migration_phase, device_type, ip_country,
            three_ds, risk_score, risk_decision, amount, amount_usd, is_approved, is_revenue, revenue_usd,
            merchant_id_inferred, site_id_inferred, load_run_id)
        SELECT
            t.txn_id,
            COALESCE(YEAR(x.txn_date) * 10000 + MONTH(x.txn_date) * 100 + DAY(x.txn_date), -1),
            COALESCE(dm.merchant_key, -1),
            COALESCE(ma.merchant_account_key, -1),
            COALESCE(ds.site_key, -1),
            COALESCE(dp.package_key, -1),
            COALESCE(dc.customer_key, -1),
            COALESCE(da.affiliate_key, -1),
            COALESCE(db.card_bin_key, -1),
            COALESCE(dr.response_code_key, -1),
            t.txn_ts_utc, t.purchase_id, t.parent_txn_id,
            t.txn_type, t.status, t.payment_method, t.card_brand, t.currency, t.migration_phase, t.device_type, t.ip_country,
            t.three_ds, re.risk_score, re.decision,
            t.amount, t.amount_usd,
            x.is_approved,
            x.is_revenue,
            CASE WHEN x.is_revenue = 1 THEN t.amount_usd ELSE 0 END,
            t.merchant_id_inferred, t.site_id_inferred,
            @run_id
        FROM silver.transactions t
        CROSS APPLY (
            SELECT txn_date    = CAST(t.txn_ts_utc AS DATE),
                   is_approved = CAST(CASE WHEN t.status = 'Approved' THEN 1 ELSE 0 END AS BIT),
                   is_revenue  = CAST(CASE WHEN t.status = 'Approved' AND t.txn_type IN ('Sale', 'Rebill') THEN 1 ELSE 0 END AS BIT)
        ) x
        -- Merchant version in effect on the transaction date (current version if the date is unknown)
        LEFT JOIN gold.dim_merchant dm
               ON dm.merchant_id = t.merchant_id
              AND COALESCE(x.txn_date, @Today) BETWEEN dm.valid_from AND dm.valid_to
        LEFT JOIN gold.dim_merchant_account ma ON ma.mid          = t.mid
        LEFT JOIN gold.dim_site             ds ON ds.site_id      = t.site_id
        LEFT JOIN gold.dim_package          dp ON dp.package_id   = t.package_id
        LEFT JOIN gold.dim_customer         dc ON dc.customer_id  = t.customer_id
        LEFT JOIN gold.dim_affiliate        da ON da.affiliate_id = t.affiliate_id
        LEFT JOIN gold.dim_card_bin         db ON db.bin          = t.card_bin6
        LEFT JOIN gold.dim_response_code    dr ON dr.response_code = t.response_code
        -- Fraud engine score: one event per transaction (latest if ever more than one)
        OUTER APPLY (
            SELECT TOP (1) r.risk_score, r.decision
            FROM silver.risk_events r
            WHERE r.txn_id = t.txn_id
            ORDER BY r.event_ts_utc DESC
        ) re;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT SourceRows          = @Source,
               FactRows            = @Loaded,
               UnknownMerchant     = (SELECT COUNT(*) FROM gold.fact_transaction WHERE merchant_key = -1),
               UnknownSite         = (SELECT COUNT(*) FROM gold.fact_transaction WHERE site_key = -1),
               UnknownPackage      = (SELECT COUNT(*) FROM gold.fact_transaction WHERE package_key = -1),
               UnknownCustomer     = (SELECT COUNT(*) FROM gold.fact_transaction WHERE customer_key = -1),
               UnknownCardBin      = (SELECT COUNT(*) FROM gold.fact_transaction WHERE card_bin_key = -1),
               UnknownDate         = (SELECT COUNT(*) FROM gold.fact_transaction WHERE date_key = -1),
               RiskScored          = (SELECT COUNT(*) FROM gold.fact_transaction WHERE risk_score IS NOT NULL),
               RevenueUsd          = (SELECT SUM(revenue_usd) FROM gold.fact_transaction)
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
