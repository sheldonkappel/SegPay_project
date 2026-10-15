/* =====================================================================
   Procedure : silver.usp_load_purchases_snapshot
   Source    : bronze.purchases_snapshot   (raw text, billing system export)
   Target    : silver.purchases_snapshot   (cleaned, one row per purchase)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A purchase is a customer's order or subscription for one package on one
   site. Each row is the purchase's state when the snapshot was exported:
   status, cancellation details, next rebill date, rebills so far, and how the
   customer arrived. Every transaction carries a purchase_id. Declined first
   attempts never become purchases, so not every purchase_id in
   silver.transactions / silver.risk_events is here.

   Transformations
   ---------------
     * purchase_id, site_id, package_id : whole numbers. Rows without a
                            purchase_id are skipped.
     * customer_id, merchant_id : trimmed and uppercased; merchant_id kept as
                            sent (it matches the purchase's transactions in every case).
     * purchase_status    : 26 spellings -> Active / Past Due / Cancelled /
                            Expired / Completed / Chargeback ('X' -> Cancelled,
                            'Closed' -> Completed).
     * cancel_reason      : ~40 spellings -> 12 reasons (Fraud and Fraud
                            Suspected kept apart); unknown reasons capitalized.
     * cancel_initiated_by, traffic_source : trimmed.
     * promo_code         : trimmed and uppercased.
     * dates              : util.fn_parse_date. A slash date valid both ways is
                            resolved against another date instead of guessed:
                              purchase_date    -> within 1 day of the purchase's
                                                  first transaction
                              cancel_date,
                              next_rebill_date -> equal to last_updated
                            otherwise US month/day.
     * rebill_count       : whole number.
     * affiliate_id       : AFF-0000 format.
     * is_trial           : util.fn_parse_flag; blanks filled from the package's
                            billing model (Trial -> 1) - the two agree in every
                            row where both are given.
     * Test data          : test merchants / test sites excluded.
     * Duplicates         : one row per purchase - latest last_updated, then the
                            later lifecycle state (ended > Past Due > Active),
                            then newest bronze load.
     * Missing values     : NULL.
     * Lineage            : bronze source columns, load_run_id, silver_loaded_at.

   Dependencies (load first)
   -------------------------
     silver.transactions, silver.packages

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * 1,951 purchases are on 12 sites that silver.sites assigns to merchants
       MRC-00201 - MRC-00205; the purchases and their transactions name another
       merchant. The purchase's merchant is kept.
     * 70 purchases have a cancel_date a few days before purchase_date (in the
       source; kept as sent).

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date / flag functions and
                 test tables; audit logging.

   Usage
   -----
     EXEC silver.usp_load_purchases_snapshot;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_purchases_snapshot
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.purchases_snapshot',
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
            THROW 50001, N'silver.purchases_snapshot does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.purchases_snapshot;

        -- First transaction date per purchase (UTC), to resolve ambiguous purchase dates
        SELECT purchase_id, MIN(CAST(txn_ts_utc AS DATE)) AS first_txn_date
        INTO #first_txn
        FROM silver.transactions
        WHERE txn_ts_utc IS NOT NULL AND purchase_id IS NOT NULL
        GROUP BY purchase_id;
        CREATE UNIQUE CLUSTERED INDEX CX_first_txn ON #first_txn (purchase_id);

        /* -------------------------------------------------------------
           Step 1: clean every column into #s
           ------------------------------------------------------------- */
        SELECT
            x.purchase_id,
            NULLIF(UPPER(TRIM(b.customer_id)), '')                     AS customer_id,
            NULLIF(UPPER(TRIM(b.merchant_id)), '')                     AS merchant_id,
            x.site_id,
            x.package_id,

            -- Purchase date: ambiguous slash date -> the reading within 1 day of the first transaction
            COALESCE(pd.fixed_date,
                CASE WHEN pd.us_date <> pd.dm_date
                          AND ABS(DATEDIFF(DAY, pd.dm_date, ft.first_txn_date)) <= 1
                          AND NOT ABS(DATEDIFF(DAY, pd.us_date, ft.first_txn_date)) <= 1
                     THEN pd.dm_date
                     ELSE COALESCE(pd.us_date, pd.dm_date) END)        AS purchase_date,

            CASE x.status_key
                WHEN 'ACTIVE' THEN 'Active' WHEN 'ACT' THEN 'Active'
                WHEN 'PAST DUE' THEN 'Past Due' WHEN 'PASTDUE' THEN 'Past Due' WHEN 'DELINQ' THEN 'Past Due'
                WHEN 'CANCELLED' THEN 'Cancelled' WHEN 'CANCELED' THEN 'Cancelled' WHEN 'X' THEN 'Cancelled'
                WHEN 'COMPLETED' THEN 'Completed' WHEN 'COMPLETE' THEN 'Completed' WHEN 'CLOSED' THEN 'Completed'
                WHEN 'EXPIRED' THEN 'Expired' WHEN 'NSF EXPIRED' THEN 'Expired' WHEN 'EXPIRED - PAYMENT' THEN 'Expired'
                WHEN 'CHARGEBACK' THEN 'Chargeback' WHEN 'CHARGED BACK' THEN 'Chargeback' WHEN 'CB' THEN 'Chargeback'
            END                                                        AS purchase_status,

            -- Cancel date: ambiguous slash date -> the reading equal to last_updated
            COALESCE(cd.fixed_date,
                CASE WHEN cd.us_date <> cd.dm_date AND cd.dm_date = x.last_updated AND cd.us_date <> x.last_updated
                     THEN cd.dm_date
                     ELSE COALESCE(cd.us_date, cd.dm_date) END)        AS cancel_date,

            -- Cancel reason: key with spaces, '_' and '-' removed
            CASE x.reason_key
                WHEN 'CUSTREQUEST' THEN 'Customer Request' WHEN 'CUSTOMERREQUEST' THEN 'Customer Request'
                WHEN 'CUSTOMERREQ' THEN 'Customer Request' WHEN 'CUSTREQUESTEDCANCEL' THEN 'Customer Request'
                WHEN 'PAYMENTFAILURE' THEN 'Payment Failure' WHEN 'PAYMENTFAIL' THEN 'Payment Failure'
                WHEN 'NSF' THEN 'Payment Failure'
                WHEN 'TOOEXPENSIVE' THEN 'Too Expensive' WHEN 'PRICE' THEN 'Too Expensive'
                WHEN 'REFUND' THEN 'Refund' WHEN 'REFUNDREQUESTED' THEN 'Refund'
                WHEN 'NOTSATISFIED' THEN 'Not Satisfied' WHEN 'UNSATISFIED' THEN 'Not Satisfied'
                WHEN 'SUPPORTCANCEL' THEN 'Support Cancel' WHEN 'CSCANCEL' THEN 'Support Cancel'
                WHEN 'MERCHANTCANCEL' THEN 'Merchant Cancel' WHEN 'MERCHCXL' THEN 'Merchant Cancel'
                WHEN 'MERCHANTCANCELLED' THEN 'Merchant Cancel'
                WHEN 'VOID' THEN 'Void' WHEN 'SAMEDAYVOID' THEN 'Void'
                WHEN 'DUPLICATEACCT' THEN 'Duplicate Account' WHEN 'DUPLICATEACCOUNT' THEN 'Duplicate Account'
                WHEN 'DUP' THEN 'Duplicate Account'
                WHEN 'FRAUD' THEN 'Fraud'
                WHEN 'FRAUDSUSPECTED' THEN 'Fraud Suspected'
                WHEN 'CHARGEBACK' THEN 'Chargeback' WHEN 'CB' THEN 'Chargeback'
                ELSE NULLIF(UPPER(LEFT(TRIM(b.cancel_reason), 1)) + LOWER(SUBSTRING(TRIM(b.cancel_reason), 2, 100)), '')
            END                                                        AS cancel_reason,

            NULLIF(TRIM(b.cancel_initiated_by), '')                    AS cancel_initiated_by,

            -- Next rebill date: ambiguous slash date -> the reading equal to last_updated
            COALESCE(nd.fixed_date,
                CASE WHEN nd.us_date <> nd.dm_date AND nd.dm_date = x.last_updated AND nd.us_date <> x.last_updated
                     THEN nd.dm_date
                     ELSE COALESCE(nd.us_date, nd.dm_date) END)        AS next_rebill_date,

            TRY_CAST(TRIM(b.rebill_count) AS INT)                      AS rebill_count,
            CASE WHEN UPPER(TRIM(b.affiliate_id)) LIKE 'AFF-[0-9][0-9][0-9][0-9]' THEN UPPER(TRIM(b.affiliate_id)) END AS affiliate_id,
            NULLIF(TRIM(b.traffic_source), '')                         AS traffic_source,
            NULLIF(UPPER(TRIM(b.promo_code)), '')                      AS promo_code,

            -- Trial flag; blank -> from the package's billing model
            COALESCE(tr.flag,
                     CASE WHEN pk.billing_model = 'Trial' THEN CAST(1 AS BIT)
                          WHEN pk.billing_model IN ('Recurring', 'One-Time') THEN CAST(0 AS BIT) END) AS is_trial,
            CASE WHEN tr.flag IS NULL AND pk.billing_model IN ('Trial', 'Recurring', 'One-Time') THEN 1 ELSE 0 END AS trial_filled,

            x.last_updated,

            -- For the summary: ambiguous slash dates resolved by the cross-check
            CASE WHEN pd.fixed_date IS NULL AND pd.us_date <> pd.dm_date THEN 1 ELSE 0 END
          + CASE WHEN cd.fixed_date IS NULL AND cd.us_date <> cd.dm_date THEN 1 ELSE 0 END
          + CASE WHEN nd.fixed_date IS NULL AND nd.us_date <> nd.dm_date THEN 1 ELSE 0 END AS ambiguous_dates,

            b.source_system, b.source_file_name, b.batch_id,
            b.ingested_at                                              AS bronze_ingested_at,
            b.ingested_by
        INTO #s
        FROM bronze.purchases_snapshot b
        CROSS APPLY (
            SELECT
                purchase_id  = TRY_CAST(TRIM(b.purchase_id) AS BIGINT),
                site_id      = TRY_CAST(TRIM(b.site_id) AS INT),
                package_id   = TRY_CAST(TRIM(b.package_id) AS INT),
                status_key   = UPPER(TRIM(b.purchase_status)),
                reason_key   = UPPER(REPLACE(REPLACE(REPLACE(TRIM(b.cancel_reason), ' ', ''), '_', ''), '-', '')),
                last_updated = TRY_CONVERT(DATE, LEFT(TRIM(b.last_updated), 10), 23)
        ) x
        CROSS APPLY util.fn_parse_date(b.purchase_date)    pd
        CROSS APPLY util.fn_parse_date(b.cancel_date)      cd
        CROSS APPLY util.fn_parse_date(b.next_rebill_date) nd
        CROSS APPLY util.fn_parse_flag(b.is_trial)         tr
        LEFT JOIN #first_txn ft     ON ft.purchase_id = x.purchase_id
        LEFT JOIN silver.packages pk ON pk.package_id = x.package_id
        WHERE ISNULL(UPPER(TRIM(b.merchant_id)), '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
          AND NOT EXISTS (SELECT 1 FROM ref.v_test_site ts WHERE ts.site_id = x.site_id);

        SET @Test = @Bronze - (SELECT COUNT(*) FROM #s);

        /* -------------------------------------------------------------
           Step 2: one row per purchase, write to silver
           ------------------------------------------------------------- */
        BEGIN TRAN;

        TRUNCATE TABLE silver.purchases_snapshot;

        WITH dedup AS (
            SELECT *,
                   ROW_NUMBER() OVER (
                       PARTITION BY purchase_id
                       ORDER BY last_updated DESC,
                                CASE purchase_status WHEN 'Active' THEN 1 WHEN 'Past Due' THEN 2 ELSE 3 END DESC,
                                bronze_ingested_at DESC) AS rn
            FROM #s
            WHERE purchase_id IS NOT NULL
        )
        INSERT silver.purchases_snapshot (
            purchase_id, customer_id, merchant_id, site_id, package_id, purchase_date, purchase_status,
            cancel_date, cancel_reason, cancel_initiated_by, next_rebill_date, rebill_count, affiliate_id,
            traffic_source, promo_code, is_trial, last_updated,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            purchase_id, customer_id, merchant_id, site_id, package_id, purchase_date, purchase_status,
            cancel_date, cancel_reason, cancel_initiated_by, next_rebill_date, rebill_count, affiliate_id,
            traffic_source, promo_code, is_trial, last_updated,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows               = @Bronze,
               TestRowsExcluded         = @Test,
               SilverRows               = @Loaded,
               DuplicatesDropped        = @Bronze - @Test - @Loaded,
               AmbiguousDatesResolved   = (SELECT SUM(ambiguous_dates) FROM #s),
               IsTrialFilledFromPackage = (SELECT SUM(trial_filled) FROM #s),
               StatusNotRecognized      = (SELECT COUNT(*) FROM silver.purchases_snapshot WHERE purchase_status IS NULL),
               PurchaseDateMissing      = (SELECT COUNT(*) FROM silver.purchases_snapshot WHERE purchase_date IS NULL)
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
