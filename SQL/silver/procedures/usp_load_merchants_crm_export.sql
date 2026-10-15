/* =====================================================================
   Procedure : silver.usp_load_merchants_crm_export
   Source    : bronze.merchants_crm_export   (raw text)
   Target    : silver.merchants_crm_export   (cleaned, one row per merchant)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   The CRM export holds each merchant's business details: legal and trading
   names, industry, country, onboarding date, account status, risk tier and
   the pricing the merchant was signed at.

   Key terms
   ---------
   DBA name       : "Doing Business As" - the trading name customers see.
   Risk tier      : SegPay's internal rating, Tier 1 (lowest) - Tier 5 (highest).
   Reserve        : share of each sale held back to cover future chargebacks.
   MCC            : Merchant Category Code - 4-digit card-network industry code.

   Transformations
   ---------------
     * merchant_id        : trimmed and uppercased. Rows without one are skipped.
     * legal_name, dba_name, account_manager : trimmed.
     * vertical           : spelling variants unified (Software/SaaS -> SaaS,
                            E Learning -> E-Learning, FITNESS -> Fitness, ...).
     * country            : 2-letter ISO code via ref.country_alias.
     * onboard_date       : any supported format (util.fn_parse_date).
     * status             : Act / A / ACTIVE -> Active; Term -> Terminated;
                            Pending / Pending_Review -> Pending Review.
                            'Closed by merchant' and 'Closed - terminated' are
                            kept as their own values - they record how the
                            account was closed.
     * risk_tier          : 1 / T1 / Tier 1 / Low ... -> 'Tier 1'-'Tier 5'
                            (Critical treated as Tier 5).
     * reserve_pct,
       processing_fee_pct : fraction with 4 decimals ('15%' or 15 -> 0.1500).
     * per_txn_fee,
       chargeback_fee     : 2 decimals (util.fn_parse_amount).
     * mcc                : padded to 4 digits.
     * contact_email, modified_by : trimmed and lowercased; the literal text
                            'N/A' sent as an email becomes NULL (util.fn_clean_text).
     * last_modified      : YYYY-MM-DD hh:mm:ss (ISO or US month/day with time).
     * Test data          : test merchants (ref.test_merchant) excluded.
     * Duplicates         : one row per merchant - latest last_modified, then
                            newest bronze load.
     * Missing values     : NULL.
     * Lineage            : bronze source columns, load_run_id, silver_loaded_at.

   PII
   ---
   contact_email is masked for users without UNMASK permission.

   Change history
   --------------
     2026-10-15  Typed columns and NULLs; shared date / country / amount
                 functions; test-merchant rule (MRC-99999 was loaded before);
                 audit logging.

   Usage
   -----
     EXEC silver.usp_load_merchants_crm_export;
   ===================================================================== */
CREATE OR ALTER PROCEDURE silver.usp_load_merchants_crm_export
    @run_id UNIQUEIDENTIFIER = NULL     -- set by silver.usp_load_all; NULL when run on its own
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcName  SYSNAME      = OBJECT_SCHEMA_NAME(@@PROCID) + N'.' + OBJECT_NAME(@@PROCID),
            @Target    SYSNAME      = N'silver.merchants_crm_export',
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
            THROW 50001, N'silver.merchants_crm_export does not exist - run SQL\silver\01_silver_tables.sql first.', 1;

        SELECT @Bronze = COUNT(*) FROM bronze.merchants_crm_export;

        SELECT @Test = COUNT(*)
        FROM bronze.merchants_crm_export
        WHERE UPPER(TRIM(merchant_id)) IN (SELECT tm.merchant_id FROM ref.test_merchant tm);

        BEGIN TRAN;

        TRUNCATE TABLE silver.merchants_crm_export;

        WITH s AS (
            SELECT
                x.merchant_id,
                NULLIF(TRIM(b.legal_name), '')                         AS legal_name,
                NULLIF(TRIM(b.dba_name), '')                           AS dba_name,

                -- Vertical: compare on a key with spaces, '-', '/' and '&' removed
                CASE x.vertical_key
                    WHEN 'softwaresaas'          THEN 'SaaS'
                    WHEN 'saassoftware'          THEN 'SaaS'
                    WHEN 'saas'                  THEN 'SaaS'
                    WHEN 'elearning'             THEN 'E-Learning'
                    WHEN 'fitness'               THEN 'Fitness'
                    WHEN 'wellness'              THEN 'Wellness'
                    WHEN 'fitnesswellness'       THEN 'Fitness & Wellness'
                    WHEN 'adultentertainment'    THEN 'Adult Entertainment'
                    WHEN 'dating'                THEN 'Dating'
                    WHEN 'streaming'             THEN 'Streaming'
                    WHEN 'streamingdigitalmedia' THEN 'Streaming / Digital Media'
                    WHEN 'nutraceuticals'        THEN 'Nutraceuticals'
                    ELSE NULLIF(TRIM(b.vertical), '')                   -- unknown: keep as written
                END                                                    AS vertical,

                COALESCE(ca.country_code,
                         CASE WHEN x.country_key LIKE '[A-Z][A-Z]' THEN x.country_key END) AS country,

                od.date_us_first                                       AS onboard_date,

                CASE x.status_key
                    WHEN 'act'                 THEN 'Active'
                    WHEN 'a'                   THEN 'Active'           -- gateway shows all as Active
                    WHEN 'active'              THEN 'Active'
                    WHEN 'pending review'      THEN 'Pending Review'
                    WHEN 'pending_review'      THEN 'Pending Review'
                    WHEN 'pending'             THEN 'Pending Review'
                    WHEN 'suspended'           THEN 'Suspended'
                    WHEN 'closed'              THEN 'Closed'
                    WHEN 'terminated'          THEN 'Terminated'
                    WHEN 'term'                THEN 'Terminated'       -- gateway shows all as Terminated
                    WHEN 'closed - terminated' THEN 'Closed - terminated'  -- kept: how it was closed
                    WHEN 'closed by merchant'  THEN 'Closed by merchant'   -- kept: merchant chose to leave
                    ELSE UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50)
                END                                                    AS status,

                -- Risk tier (risk_key has spaces removed: 'Very High' -> 'veryhigh')
                CASE
                    WHEN x.risk_key LIKE 'tier[1-5]' THEN 'Tier ' + RIGHT(x.risk_key, 1)
                    WHEN x.risk_key LIKE 't[1-5]'    THEN 'Tier ' + RIGHT(x.risk_key, 1)
                    WHEN x.risk_key LIKE '[1-5]'     THEN 'Tier ' + x.risk_key
                    WHEN x.risk_key = 'low'                                                       THEN 'Tier 1'
                    WHEN x.risk_key IN ('low-med','lowmed','low/med','low-medium','lowmedium')    THEN 'Tier 2'
                    WHEN x.risk_key IN ('med','medium')                                          THEN 'Tier 3'
                    WHEN x.risk_key IN ('hi','high')                                             THEN 'Tier 4'
                    WHEN x.risk_key IN ('veryhigh','very-high','crit','critical')                THEN 'Tier 5'
                END                                                    AS risk_tier,

                -- Percentages -> fraction: '%' or a number >= 1 means "percent"
                CAST(CASE WHEN x.reserve_has_pct = 1 OR n.reserve >= 1 THEN n.reserve / 100 ELSE n.reserve END AS DECIMAL(6,4)) AS reserve_pct,
                CAST(CASE WHEN x.fee_has_pct = 1 OR n.fee >= 1         THEN n.fee / 100     ELSE n.fee     END AS DECIMAL(6,4)) AS processing_fee_pct,

                CAST(ptf.amount AS DECIMAL(10,2))                      AS per_txn_fee,
                CAST(cbf.amount AS DECIMAL(10,2))                      AS chargeback_fee,

                CASE WHEN n.mcc BETWEEN 0 AND 9999 THEN RIGHT('0000' + CONVERT(VARCHAR(4), n.mcc), 4) END AS mcc,

                NULLIF(TRIM(b.account_manager), '')                    AS account_manager,
                LOWER(em.txt)                                          AS contact_email,   -- 'N/A' placeholder -> NULL

                CASE WHEN x.lm LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%' THEN TRY_CONVERT(DATETIME2(0), x.lm, 120)  -- 2026-06-15 15:00:52
                     WHEN x.lm LIKE '%/%/[12][0-9][0-9][0-9]%'                  THEN TRY_CONVERT(DATETIME2(0), x.lm, 101)  -- 01/10/2026 02:24
                END                                                    AS last_modified,

                NULLIF(LOWER(TRIM(b.modified_by)), '')                 AS modified_by,

                b.source_system, b.source_file_name, b.batch_id,
                b.ingested_at                                          AS bronze_ingested_at,
                b.ingested_by
            FROM bronze.merchants_crm_export b
            CROSS APPLY (
                SELECT
                    merchant_id     = NULLIF(UPPER(TRIM(b.merchant_id)), ''),
                    vertical_key    = LOWER(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.vertical), ' ', ''), '-', ''), '/', ''), '&', '')),
                    country_key     = UPPER(REPLACE(TRIM(b.country), '.', '')),
                    status_key      = NULLIF(LOWER(TRIM(b.status)), ''),
                    risk_key        = LOWER(REPLACE(TRIM(b.risk_tier), ' ', '')),
                    reserve_has_pct = CASE WHEN b.reserve_pct LIKE '%[%]%' THEN 1 ELSE 0 END,
                    fee_has_pct     = CASE WHEN b.processing_fee_pct LIKE '%[%]%' THEN 1 ELSE 0 END,
                    lm              = NULLIF(TRIM(b.last_modified), '')
            ) x
            CROSS APPLY (
                SELECT
                    reserve = TRY_CAST(NULLIF(REPLACE(REPLACE(TRIM(b.reserve_pct), '%', ''), ' ', ''), '') AS DECIMAL(12,6)),
                    fee     = TRY_CAST(NULLIF(REPLACE(REPLACE(TRIM(b.processing_fee_pct), '%', ''), ' ', ''), '') AS DECIMAL(12,6)),
                    mcc     = TRY_CAST(TRIM(b.mcc) AS INT)
            ) n
            CROSS APPLY util.fn_parse_date(b.onboard_date) od
            CROSS APPLY util.fn_parse_amount(b.per_txn_fee) ptf
            CROSS APPLY util.fn_parse_amount(b.chargeback_fee) cbf
            CROSS APPLY util.fn_clean_text(b.contact_email) em
            LEFT JOIN ref.country_alias ca ON ca.alias = x.country_key
            WHERE ISNULL(x.merchant_id, '') NOT IN (SELECT tm.merchant_id FROM ref.test_merchant tm)
        ),
        dedup AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY merchant_id ORDER BY last_modified DESC, bronze_ingested_at DESC) AS rn
            FROM s
            WHERE merchant_id IS NOT NULL
        )
        INSERT silver.merchants_crm_export (
            merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier,
            reserve_pct, processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
            contact_email, last_modified, modified_by,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, load_run_id)
        SELECT
            merchant_id, legal_name, dba_name, vertical, country, onboard_date, status, risk_tier,
            reserve_pct, processing_fee_pct, per_txn_fee, chargeback_fee, mcc, account_manager,
            contact_email, last_modified, modified_by,
            source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by, @run_id
        FROM dedup
        WHERE rn = 1;

        SET @Loaded = @@ROWCOUNT;

        COMMIT;

        SELECT BronzeRows              = @Bronze,
               TestRowsExcluded        = @Test,
               SilverRows              = @Loaded,
               DuplicatesDropped       = @Bronze - @Test - @Loaded,
               OnboardDateMissing      = (SELECT COUNT(*) FROM silver.merchants_crm_export WHERE onboard_date IS NULL),
               CountryNotMapped        = (SELECT COUNT(*) FROM silver.merchants_crm_export WHERE country IS NULL),
               RiskTierNotRecognized   = (SELECT COUNT(*) FROM silver.merchants_crm_export WHERE risk_tier IS NULL),
               ContactEmailMissing     = (SELECT COUNT(*) FROM silver.merchants_crm_export WHERE contact_email IS NULL)
        INTO #summary;

        SET @Metrics = (SELECT * FROM #summary FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

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
