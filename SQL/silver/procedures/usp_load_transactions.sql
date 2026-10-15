/* =====================================================================
   Procedure : silver.usp_load_transactions
   Source    : bronze.txn_pre_migration   (old gateway, Sep 2024 - Feb 2026)
               bronze.txn_post_migration  (new gateway, Mar 2026 onward)
   Target    : silver.transactions        (cleaned, one row per txn_id, both gateways)
   Load type : Full refresh - silver is emptied and rebuilt from both bronze
               tables each run.

   Purpose
   -------
   Each row is one payment event: sale, rebill, auth, refund, void or
   chargeback. The payment gateway migrated in March 2026, so transactions
   arrive in two bronze tables with different layouts. This procedure
   appends them into one table with one set of cleaning rules.

   Layout differences handled
   --------------------------
       Old gateway (pre)    New gateway (post)    Silver column
       currency             ccy                   currency
       auth_timestamp       txn_ts_utc            txn_ts_utc (UTC for both)
         (US Eastern time)    (UTC)
       merchant_id 1005     merchant_id MRC-00002 merchant_id + legacy_merchant_id
       card_bin (6 digits)  card_bin (8 digits)   card_bin + card_bin6
       -                    network_txn_id        network_txn_id (NULL for pre)

   Key terms
   ---------
   Migration phase : which gateway sent the row (Pre-migration / Post-migration).
   Parent txn ID   : the transaction a refund / void / chargeback reverses.
   BIN             : first card digits; card_bin6 joins to silver.bin_reference.
   MID             : the merchant's account ID at the acquirer.
   3-D Secure      : extra cardholder authentication (three_ds = 1).

   Transformations
   ---------------
     * txn_id, purchase_id,
       parent_txn_id      : whole numbers; parent_txn_id 0 (old gateway's "none") -> NULL.
     * merchant_id        : new gateway: as sent. Old gateway: legacy number
                            mapped through silver.merchant_xref; where xref has
                            no mapping, the merchant the risk engine names for
                            that legacy number is used - only when every risk
                            event agrees (merchant_id_inferred = 1).
     * site_id            : as sent when it is a real site; otherwise the
                            package's site from silver.packages (site_id_inferred = 1).
                            For every transaction with a valid site and package,
                            the package's site matches.
     * txn_type           : 25 spellings -> Sale / Rebill / Auth / Zero Auth /
                            Refund / Void / Chargeback.
     * amount             : util.fn_parse_amount; sign follows the new gateway:
                            Refund / Void / Chargeback negative, others positive.
     * currency           : ISO code; numeric codes mapped (840 USD, 978 EUR,
                            826 GBP, 036 AUD, 124 CAD).
     * amount_usd         : most recent US Treasury rate on or before the UTC
                            transaction date; USD unchanged; no rate -> NULL.
     * card_brand         : via ref.card_brand_alias.
     * card_bin / card_bin6 : digits as sent / first 6 digits.
     * payment_method     : Card / Apple Pay / Google Pay / SEPA Direct Debit.
     * response_text      : one description per code from silver.response_codes;
                            gateway_response_text keeps the gateway's own wording
                            (title case, abbreviations kept: NSF, CVV, OK).
     * status             : Approved / Declined / Error.
     * txn_ts_utc         : old gateway (US Eastern, three formats) converted to
                            UTC with AT TIME ZONE (daylight saving handled); new
                            gateway (ISO 8601, '+00:00', epoch seconds) already UTC.
     * settle_date        : util.fn_parse_date.
     * acquirer           : via ref.acquirer_alias.
     * three_ds           : util.fn_parse_flag.
     * device_type        : Mobile / Desktop / Tablet.
     * ip_country         : 2-letter code; 'XX' (unknown) -> NULL.
     * affiliate_id       : AFF-0000; bare numbers padded (9 -> AFF-0009).
     * Test data          : excluded when is_test is set, the merchant is a test
                            merchant (ref.test_merchant, MRC- or legacy number),
                            or the site is a test site (ref.v_test_site).
     * Duplicates         : one row per txn_id - the new-gateway copy, then the
                            latest gateway export, then the newest bronze load
                            (39 Feb-2026 transactions were re-sent by the new gateway).
     * Missing values     : NULL.
     * Lineage            : migration_phase, bronze source columns, load_run_id,
                            silver_loaded_at.

   Dependencies (load first)
   -------------------------
     silver.merchant_xref, silver.risk_events, silver.response_codes,
     silver.sites, silver.packages, silver.fx_rates_daily

   PII
   ---
   ip_address is masked for users without UNMASK permission.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * ~10 transactions have a site_id that is not a real site and no usable package.
     * ~14,800 transactions have a card_bin6 not in silver.bin_reference.
     * The US Eastern assumption for old-gateway times is confirmed for
       February 2026 (the 39 re-sent transactions match exactly).

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; legacy merchants 1002 / 1229 / 1310
                 now mapped from risk events (merchant_id_inferred); inferred
                 sites flagged (site_id_inferred); shared lookups; audit logging.

   Usage
   -----
     EXEC silver.usp_load_transactions;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_transactions
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.transactions',
            @StartedAt DATETIME2(3) = SYSUTCDATETIME(),
            @Pre       INT,
            @Post      INT,
            @Bronze    INT,
            @Test      INT,
            @Loaded    INT,
            @Excluded  INT,
            @Dropped   INT,
            @Metrics   NVARCHAR(MAX),
            @Err       NVARCHAR(4000);

    BEGIN TRY
        IF OBJECT_ID(@Target, N'U') IS NULL
            THROW 50001, N'silver.transactions does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Pre  = COUNT(*) FROM bronze.txn_pre_migration;
        SELECT @Post = COUNT(*) FROM bronze.txn_post_migration;
        SET @Bronze = @Pre + @Post;

        /* -------------------------------------------------------------
           Lookups prepared once, indexed for the joins below
           ------------------------------------------------------------- */
        -- US Treasury rates
        SELECT currency, rate_date, usd_per_unit INTO #fx FROM silver.fx_rates_daily;
        CREATE CLUSTERED INDEX CX_fx ON #fx (currency, rate_date);

        -- Fallback merchant for legacy IDs missing from merchant_xref: the MRC- merchant
        -- the risk engine names on that legacy merchant's transactions (only if unanimous)
        SELECT x.legacy_merchant_id, MIN(r.merchant_id) AS merchant_id
        INTO #legacy_map
        FROM (SELECT TRY_CAST(TRIM(txn_id) AS BIGINT) AS txn_id,
                     TRY_CAST(TRIM(merchant_id) AS INT) AS legacy_merchant_id
              FROM bronze.txn_pre_migration) x
        JOIN silver.risk_events r ON r.txn_id = x.txn_id AND r.merchant_id IS NOT NULL
        WHERE x.legacy_merchant_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM silver.merchant_xref m WHERE m.legacy_merchant_id = x.legacy_merchant_id)
        GROUP BY x.legacy_merchant_id
        HAVING COUNT(DISTINCT r.merchant_id) = 1;

        /* -------------------------------------------------------------
           Step 1: clean both gateways into #s
           ------------------------------------------------------------- */
        WITH src AS (
            SELECT 'Pre-migration' AS migration_phase, 1 AS phase_rank,
                   txn_id, purchase_id, parent_txn_id, merchant_id, site_id, package_id, customer_id,
                   txn_type, amount, currency, card_brand, card_bin, card_last4, payment_method,
                   response_code, response_text, status, auth_timestamp AS raw_ts, settle_date,
                   acquirer, mid, three_ds, device_type, ip_address, ip_country, affiliate_id,
                   is_test, CAST(NULL AS VARCHAR(1000)) AS network_txn_id, batch_id_source, load_ts,
                   source_system, source_file_name, batch_id, ingested_at, ingested_by, bronze_id
            FROM bronze.txn_pre_migration
            UNION ALL
            SELECT 'Post-migration', 2,
                   txn_id, purchase_id, parent_txn_id, merchant_id, site_id, package_id, customer_id,
                   txn_type, amount, ccy, card_brand, card_bin, card_last4, payment_method,
                   response_code, response_text, status, txn_ts_utc, settle_date,
                   acquirer, mid, three_ds, device_type, ip_address, ip_country, affiliate_id,
                   is_test, network_txn_id, batch_id_source, load_ts,
                   source_system, source_file_name, batch_id, ingested_at, ingested_by, bronze_id
            FROM bronze.txn_post_migration
        )
        SELECT
            x.txn_id,
            b.migration_phase,
            b.phase_rank,
            TRY_CAST(TRIM(b.purchase_id) AS BIGINT)                 AS purchase_id,
            NULLIF(TRY_CAST(TRIM(b.parent_txn_id) AS BIGINT), 0)    AS parent_txn_id,

            -- Merchant: new gateway as sent; old gateway via merchant_xref, else the risk-event fallback
            CASE WHEN b.migration_phase = 'Post-migration' THEN NULLIF(x.merchant_key, '')
                 ELSE COALESCE(mx.merchant_id, lm.merchant_id) END  AS merchant_id,
            CAST(CASE WHEN b.migration_phase = 'Pre-migration' AND mx.merchant_id IS NULL AND lm.merchant_id IS NOT NULL
                      THEN 1 ELSE 0 END AS BIT)                     AS merchant_id_inferred,
            CASE WHEN b.migration_phase = 'Pre-migration' THEN x.legacy_merchant_id END AS legacy_merchant_id,

            -- Site: as sent when it is a real site, else the package's site
            CASE WHEN ks.site_id IS NULL AND pk.site_id IS NOT NULL THEN pk.site_id ELSE x.site_id END AS site_id,
            CAST(CASE WHEN ks.site_id IS NULL AND pk.site_id IS NOT NULL THEN 1 ELSE 0 END AS BIT)     AS site_id_inferred,

            x.package_id,
            NULLIF(UPPER(TRIM(b.customer_id)), '')                  AS customer_id,
            x.txn_type,

            CAST(CASE WHEN x.txn_type IN ('Refund', 'Void', 'Chargeback') THEN -ABS(am.amount)
                      ELSE ABS(am.amount) END AS DECIMAL(18,2))     AS amount,

            CASE x.ccy
                WHEN '840' THEN 'USD' WHEN '978' THEN 'EUR' WHEN '826' THEN 'GBP'
                WHEN '036' THEN 'AUD' WHEN '124' THEN 'CAD'
                ELSE CASE WHEN x.ccy LIKE '[A-Z][A-Z][A-Z]' THEN x.ccy END
            END                                                     AS currency,

            cb.card_brand,
            x.bin                                                   AS card_bin,
            LEFT(x.bin, 6)                                          AS card_bin6,
            CASE WHEN TRIM(b.card_last4) LIKE '[0-9][0-9][0-9][0-9]' THEN TRIM(b.card_last4) END AS card_last4,

            CASE x.pm_key
                WHEN 'CARD' THEN 'Card' WHEN 'CC' THEN 'Card' WHEN 'CREDITCARD' THEN 'Card'
                WHEN 'APPLEPAY' THEN 'Apple Pay' WHEN 'AP' THEN 'Apple Pay'
                WHEN 'GOOGLEPAY' THEN 'Google Pay' WHEN 'GPAY' THEN 'Google Pay'
                WHEN 'SEPA' THEN 'SEPA Direct Debit' WHEN 'SEPADD' THEN 'SEPA Direct Debit'
                WHEN 'SEPADIRECTDEBIT' THEN 'SEPA Direct Debit'
            END                                                     AS payment_method,

            NULLIF(UPPER(TRIM(b.response_code)), '')                AS response_code,
            COALESCE(rc.description, gt.gateway_response_text)     AS response_text,
            gt.gateway_response_text,

            CASE UPPER(TRIM(b.status))
                WHEN 'APPROVED' THEN 'Approved' WHEN 'APPR' THEN 'Approved' WHEN 'A' THEN 'Approved'
                WHEN 'DECLINED' THEN 'Declined' WHEN 'DECL' THEN 'Declined' WHEN 'D' THEN 'Declined'
                WHEN 'ERROR'    THEN 'Error'
            END                                                     AS status,

            -- UTC: old gateway is US Eastern (AT TIME ZONE applies EST / EDT per date)
            CASE WHEN b.migration_phase = 'Pre-migration'
                 THEN CAST((t.ts AT TIME ZONE 'Eastern Standard Time') AT TIME ZONE 'UTC' AS DATETIME2(0))
                 ELSE t.ts END                                      AS txn_ts_utc,

            sd.date_us_first                                        AS settle_date,
            aq.acquirer,
            NULLIF(TRIM(b.mid), '')                                 AS mid,
            td.flag                                                 AS three_ds,

            CASE UPPER(TRIM(b.device_type))
                WHEN 'MOBILE' THEN 'Mobile' WHEN 'M' THEN 'Mobile'
                WHEN 'DESKTOP' THEN 'Desktop' WHEN 'D' THEN 'Desktop' WHEN 'PC' THEN 'Desktop'
                WHEN 'TABLET' THEN 'Tablet' WHEN 'T' THEN 'Tablet'
            END                                                     AS device_type,

            NULLIF(LOWER(TRIM(b.ip_address)), '')                   AS ip_address,
            CASE WHEN x.ipc LIKE '[A-Z][A-Z]' AND x.ipc <> 'XX' THEN x.ipc END AS ip_country,

            CASE WHEN x.aff LIKE 'AFF-[0-9][0-9][0-9][0-9]' THEN x.aff
                 WHEN TRY_CAST(x.aff AS INT) IS NOT NULL
                     THEN 'AFF-' + RIGHT('0000' + CONVERT(VARCHAR(10), TRY_CAST(x.aff AS INT)), 4)
            END                                                     AS affiliate_id,

            NULLIF(TRIM(b.network_txn_id), '')                      AS network_txn_id,
            NULLIF(TRIM(b.batch_id_source), '')                     AS gateway_batch_id,
            TRY_CONVERT(DATETIME2(0), NULLIF(TRIM(b.load_ts), ''), 120) AS gateway_load_ts,

            b.source_system, b.source_file_name, b.batch_id,
            b.ingested_at                                           AS bronze_ingested_at,
            b.ingested_by,
            b.bronze_id
        INTO #s
        FROM src b
        CROSS APPLY (
            SELECT
                txn_id             = TRY_CAST(TRIM(b.txn_id) AS BIGINT),
                site_id            = TRY_CAST(TRIM(b.site_id) AS INT),
                package_id         = TRY_CAST(TRIM(b.package_id) AS INT),
                merchant_key       = UPPER(TRIM(b.merchant_id)),
                legacy_merchant_id = TRY_CAST(TRIM(b.merchant_id) AS INT),
                txn_type           = CASE UPPER(TRIM(b.txn_type))
                                         WHEN 'SALE' THEN 'Sale' WHEN 'S' THEN 'Sale'
                                         WHEN 'REBILL' THEN 'Rebill' WHEN 'RB' THEN 'Rebill' WHEN 'R' THEN 'Rebill'
                                         WHEN 'AUTH' THEN 'Auth'
                                         WHEN 'ZERO_AUTH' THEN 'Zero Auth'
                                         WHEN 'REFUND' THEN 'Refund' WHEN 'RFND' THEN 'Refund' WHEN 'RF' THEN 'Refund'
                                         WHEN 'VOID' THEN 'Void' WHEN 'VD' THEN 'Void'
                                         WHEN 'CHARGEBACK' THEN 'Chargeback' WHEN 'CB' THEN 'Chargeback'
                                     END,
                ccy                = UPPER(TRIM(b.currency)),
                bin                = CASE WHEN TRIM(b.card_bin) NOT LIKE '%[^0-9]%' AND LEN(TRIM(b.card_bin)) >= 6
                                          THEN TRIM(b.card_bin) END,
                pm_key             = UPPER(REPLACE(REPLACE(TRIM(b.payment_method), ' ', ''), '_', '')),
                ipc                = UPPER(TRIM(b.ip_country)),
                aff                = NULLIF(UPPER(TRIM(b.affiliate_id)), ''),
                ts                 = NULLIF(TRIM(b.raw_ts), '')
        ) x
        -- Timestamp as written (source time zone)
        CROSS APPLY (
            SELECT ts = CASE
                WHEN x.ts LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9][ T][0-2][0-9]:[0-5][0-9]:[0-5][0-9]%'
                    THEN TRY_CONVERT(DATETIME2(0), REPLACE(LEFT(x.ts, 19), 'T', ' '), 120)       -- ISO, '+00:00', '.123Z'
                WHEN x.ts LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9] [0-1][0-9]:[0-5][0-9]:[0-5][0-9] [AP]M'
                    THEN TRY_CONVERT(DATETIME2(0), x.ts, 101)                                     -- 10/01/2024 07:27:06 AM
                WHEN x.ts LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
                    THEN TRY_CONVERT(DATETIME2(0), REPLACE(x.ts, '-', ' '), 113)                 -- 03-OCT-2024 12:14:57
                WHEN x.ts NOT LIKE '%[^0-9]%' AND LEN(x.ts) = 10
                    THEN DATEADD(SECOND, CAST(x.ts AS INT), CAST('1970-01-01' AS DATETIME2(0)))  -- Unix epoch seconds
            END
        ) t
        CROSS APPLY util.fn_parse_amount(b.amount)    am
        CROSS APPLY util.fn_parse_date(b.settle_date) sd
        CROSS APPLY util.fn_parse_flag(b.three_ds)    td
        CROSS APPLY util.fn_parse_flag(b.is_test)     it
        -- Gateway's own response wording, title case (abbreviations kept uppercase)
        CROSS APPLY (
            SELECT gateway_response_text = CASE UPPER(TRIM(b.response_text))
                WHEN 'APPROVAL'                                THEN 'Approval'
                WHEN 'APPROVED'                                THEN 'Approved'
                WHEN 'OK'                                      THEN 'OK'
                WHEN 'REFUND PROCESSED'                        THEN 'Refund Processed'
                WHEN 'CHARGEBACK POSTED'                       THEN 'Chargeback Posted'
                WHEN 'VOIDED'                                  THEN 'Voided'
                WHEN 'DO NOT HONOR'                            THEN 'Do Not Honor'
                WHEN '05 - DO NOT HONOR'                       THEN '05 - Do Not Honor'
                WHEN 'INSUFFICIENT FUNDS'                      THEN 'Insufficient Funds'
                WHEN 'NSF'                                     THEN 'NSF'
                WHEN 'CARD EXPIRED'                            THEN 'Card Expired'
                WHEN 'EXPIRED CARD'                            THEN 'Expired Card'
                WHEN 'INVALID CARD'                            THEN 'Invalid Card'
                WHEN 'INVALID CARD NUMBER'                     THEN 'Invalid Card Number'
                WHEN 'ISSUER UNAVAILABLE'                      THEN 'Issuer Unavailable'
                WHEN 'ISSUER OR SWITCH INOPERATIVE'            THEN 'Issuer Or Switch Inoperative'
                WHEN 'SUSPECTED FRAUD'                         THEN 'Suspected Fraud'
                WHEN 'RISK_ENGINE_DECLINE'                     THEN 'Risk Engine Decline'
                WHEN 'EXCEEDS LIMIT'                           THEN 'Exceeds Limit'
                WHEN 'EXCEEDS WITHDRAWAL LIMIT'                THEN 'Exceeds Withdrawal Limit'
                WHEN 'TXN NOT PERMITTED'                       THEN 'Txn Not Permitted'
                WHEN 'TRANSACTION NOT PERMITTED TO CARDHOLDER' THEN 'Transaction Not Permitted To Cardholder'
                WHEN 'BLOCKED FIRST USE'                       THEN 'Blocked First Use'
                WHEN 'NO ACCOUNT'                              THEN 'No Account'
                WHEN 'RESTRICTED CARD'                         THEN 'Restricted Card'
                WHEN 'LOST CARD, PICK UP'                      THEN 'Lost Card, Pick Up'
                WHEN 'SYSTEM ERROR'                            THEN 'System Error'
                WHEN 'SYSTEM MALFUNCTION'                      THEN 'System Malfunction'
                WHEN 'CVV FAIL'                                THEN 'CVV Fail'
                WHEN 'CVV2 MISMATCH'                           THEN 'CVV2 Mismatch'
                ELSE NULLIF(UPPER(LEFT(TRIM(b.response_text), 1)) + LOWER(SUBSTRING(TRIM(b.response_text), 2, 100)), '')
            END
        ) gt
        LEFT JOIN silver.response_codes   rc ON rc.response_code = NULLIF(UPPER(TRIM(b.response_code)), '')
        LEFT JOIN ref.card_brand_alias    cb ON cb.alias = UPPER(TRIM(b.card_brand))
        LEFT JOIN ref.acquirer_alias      aq ON aq.alias = UPPER(REPLACE(TRIM(b.acquirer), ' ', ''))
        LEFT JOIN silver.merchant_xref    mx ON b.migration_phase = 'Pre-migration' AND mx.legacy_merchant_id = x.legacy_merchant_id
        LEFT JOIN #legacy_map             lm ON b.migration_phase = 'Pre-migration' AND lm.legacy_merchant_id = x.legacy_merchant_id
        LEFT JOIN silver.sites            ks ON ks.site_id = x.site_id
        LEFT JOIN silver.packages         pk ON pk.package_id = x.package_id
        -- Exclude test data: flagged by the gateway, a test merchant, or a test site
        WHERE ISNULL(it.flag, 0) = 0
          AND ISNULL(x.merchant_key, '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
          AND ISNULL(x.legacy_merchant_id, -1) NOT IN (SELECT ISNULL(tm.legacy_merchant_id, -1) FROM ref.test_merchant tm)
          AND NOT EXISTS (SELECT 1 FROM ref.v_test_site ts WHERE ts.site_id = x.site_id);

        SET @Test = @Bronze - (SELECT COUNT(*) FROM #s);

        /* -------------------------------------------------------------
           Step 2: one row per txn_id, USD conversion, write to silver
           ------------------------------------------------------------- */
        BEGIN TRAN;

        TRUNCATE TABLE silver.transactions;

        WITH dedup AS (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY txn_id
                                      ORDER BY phase_rank DESC,          -- new gateway first
                                               gateway_load_ts DESC,     -- then the latest gateway export
                                               bronze_ingested_at DESC,  -- then the newest bronze load
                                               bronze_id DESC) AS rn
            FROM #s
            WHERE txn_id IS NOT NULL
        )
        INSERT silver.transactions (
            txn_id, migration_phase, purchase_id, parent_txn_id, merchant_id, merchant_id_inferred,
            legacy_merchant_id, site_id, site_id_inferred, package_id, customer_id, txn_type, amount,
            currency, amount_usd, fx_rate, fx_rate_date, card_brand, card_bin, card_bin6, card_last4,
            payment_method, response_code, response_text, gateway_response_text, status, txn_ts_utc,
            settle_date, acquirer, mid, three_ds, device_type, ip_address, ip_country, affiliate_id,
            network_txn_id, gateway_batch_id, gateway_load_ts,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            d.txn_id, d.migration_phase, d.purchase_id, d.parent_txn_id, d.merchant_id, d.merchant_id_inferred,
            d.legacy_merchant_id, d.site_id, d.site_id_inferred, d.package_id, d.customer_id, d.txn_type, d.amount,
            d.currency,
            CASE WHEN d.currency = 'USD' THEN d.amount
                 ELSE CAST(ROUND(d.amount * r.usd_per_unit, 2) AS DECIMAL(18,2)) END,
            r.usd_per_unit, r.rate_date,
            d.card_brand, d.card_bin, d.card_bin6, d.card_last4,
            d.payment_method, d.response_code, d.response_text, d.gateway_response_text, d.status, d.txn_ts_utc,
            d.settle_date, d.acquirer, d.mid, d.three_ds, d.device_type, d.ip_address, d.ip_country, d.affiliate_id,
            d.network_txn_id, d.gateway_batch_id, d.gateway_load_ts,
            d.source_system, d.source_file_name, d.batch_id, d.bronze_ingested_at, d.ingested_by, @run_id
        FROM dedup d
        -- Most recent US Treasury rate on or before the UTC transaction date (not for USD)
        OUTER APPLY (
            SELECT TOP (1) f.usd_per_unit, f.rate_date
            FROM #fx f
            WHERE d.currency <> 'USD'
              AND f.currency  = d.currency
              AND f.rate_date <= CAST(d.txn_ts_utc AS DATE)
            ORDER BY f.rate_date DESC
        ) r
        WHERE d.rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT PreMigrationRows        = @Pre,
               PostMigrationRows       = @Post,
               TestRowsExcluded        = @Test,
               SilverRows              = @Loaded,
               SilverPreMigration      = (SELECT COUNT(*) FROM silver.transactions WHERE migration_phase = 'Pre-migration'),
               SilverPostMigration     = (SELECT COUNT(*) FROM silver.transactions WHERE migration_phase = 'Post-migration'),
               DuplicatesDropped       = @Bronze - @Test - @Loaded,
               MerchantInferred        = (SELECT COUNT(*) FROM silver.transactions WHERE merchant_id_inferred = 1),
               MerchantMissing         = (SELECT COUNT(*) FROM silver.transactions WHERE merchant_id IS NULL),
               SiteInferred            = (SELECT COUNT(*) FROM silver.transactions WHERE site_id_inferred = 1),
               SiteNotInSilverSites    = (SELECT COUNT(*) FROM silver.transactions t
                                          WHERE NOT EXISTS (SELECT 1 FROM silver.sites s WHERE s.site_id = t.site_id)),
               TimestampMissing        = (SELECT COUNT(*) FROM silver.transactions WHERE txn_ts_utc IS NULL),
               AmountMissing           = (SELECT COUNT(*) FROM silver.transactions WHERE amount IS NULL),
               AmountUsdMissing        = (SELECT COUNT(*) FROM silver.transactions WHERE amount IS NOT NULL AND amount_usd IS NULL)
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
