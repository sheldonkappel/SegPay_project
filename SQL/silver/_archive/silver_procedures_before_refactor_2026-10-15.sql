-- ===== usp_load_affiliates


-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE [silver].[usp_load_affiliates]
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.affiliates', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.affiliates (
            affiliate_id        VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_affiliates PRIMARY KEY,
            affiliate_name      NVARCHAR(100)  NULL,
            affiliate_type      VARCHAR(30)    NULL,
            commission_pct      DECIMAL(5,4)   NULL,      -- 0.3500 = 35%
            status              VARCHAR(20)    NULL,      -- Active / Inactive / Suspended
            join_date           DATE           NULL,
            country             CHAR(2)        NULL,      -- ISO 2-letter code
            payout_method       VARCHAR(20)    NOT NULL,  -- 'N/A' when missing
            source_system       VARCHAR(50)    NULL,
            source_file_name    NVARCHAR(260)  NULL,
            batch_id            NVARCHAR(100)  NULL,
            bronze_ingested_at  DATETIME2(3)   NULL,
            ingested_by         NVARCHAR(128)  NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_affiliates_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT;     -- number of rows written to silver (output)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[affiliates];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.affiliates;

    /* -----------------------------------------------------------------
       CTE 1: src - clean and standardize every bronze column
       (a CTE is a named temporary result set used by the next query)
       ----------------------------------------------------------------- */
    WITH src AS (
        SELECT
            -- TRIM removes leading/trailing spaces so ' AFF-0001 ' becomes 'AFF-0001'
            TRIM(affiliate_id) AS affiliate_id,
            TRIM(affiliate_name) AS affiliate_name,
            TRIM(affiliate_type) AS affiliate_type,

            -- commission_pct arrives in three styles; convert all to a fraction (0.35 = 35%)
            CAST(
                CASE
                    -- Style 1: has a % sign, e.g. '35%'
                    -- remove the %, convert to a number, divide by 100 -> 0.35
                    WHEN commission_pct LIKE '%[%]%'
                        THEN TRY_CAST(REPLACE(commission_pct, '%', '') AS DECIMAL(10,4)) / 100.0

                    -- Style 2: bare whole number above 1, e.g. '15'
                    -- assumed to mean 15%, so divide by 100 -> 0.15
                    WHEN TRY_CAST(commission_pct AS DECIMAL(10,4)) > 1
                        THEN TRY_CAST(commission_pct AS DECIMAL(10,4)) / 100.0

                    -- Style 3: already a fraction, e.g. '0.15' - use as is
                    -- (TRY_CAST returns NULL instead of an error for non-numeric text)
                    ELSE TRY_CAST(commission_pct AS DECIMAL(10,4))
                END
                -- Final type: 2 decimal places (note: a rate like 0.125 rounds to 0.13)
                AS DECIMAL(10,2)
            ) AS commission_pct,

            -- Standardize status to title case: 'ACTIVE', 'active', ' Active ' -> 'Active'.
            -- UPPER(TRIM()) first so any casing or stray spaces match.
            -- Anything not listed becomes NULL so it shows up in data-quality checks.
            CASE UPPER(TRIM(status))
                WHEN 'ACTIVE'    THEN 'Active'
                WHEN 'INACTIVE'  THEN 'Inactive'
                WHEN 'SUSPENDED' THEN 'Suspended'
            END AS status,

            -- join_date arrives in several formats. COALESCE returns the first
            -- non-NULL result, so each TRY_CONVERT is tried in order until one works.
            -- TRY_CONVERT returns NULL (not an error) when the format doesn't match.
            -- The number after join_date is the SQL Server date style code.
            COALESCE(
                TRY_CONVERT(DATE, join_date, 23),  -- YYYY-MM-DD   e.g. 2023-05-09
                TRY_CONVERT(DATE, join_date, 106), -- DD Mon YYYY  e.g. 27 Nov 2024 (also reads 'Nov 27, 2024')
                                                   -- note: also reads 04/12/2024 day-first -> 4 Dec
                TRY_CONVERT(DATE, join_date, 105), -- DD-MM-YYYY   e.g. 27-11-2024
                TRY_CONVERT(DATE, join_date, 101)  -- MM/DD/YYYY   e.g. 11/15/2025
            ) AS join_date,

            -- Convert country names and 3-letter codes to 2-letter ISO codes.
            -- UPPER(TRIM()) first so ' usa ', 'Usa' and 'USA' are all matched.
            CASE UPPER(TRIM(country))
                WHEN 'BRAZIL' THEN 'BR'
                WHEN 'IND' THEN 'IN'   WHEN 'INDIA' THEN 'IN'
                WHEN 'MEX' THEN 'MX'
                WHEN 'NETHERLANDS' THEN 'NL'
                WHEN 'NORWAY' THEN 'NO'
                WHEN 'USA' THEN 'US'   WHEN 'UNITED STATES' THEN 'US'   WHEN 'UNITED STATES OF AMERICA' THEN 'US'
                -- Anything not listed above: if it is already 2 letters (e.g. 'gb'),
                -- keep it uppercased; otherwise return NULL so it shows up as unmapped
                ELSE CASE WHEN LEN(TRIM(country)) = 2 THEN UPPER(TRIM(country)) END 
            END AS country,

            -- Replace missing payout methods with 'N/A'
            COALESCE(payout_method, 'N/A') AS payout_method,

            -- Lineage columns: carried over so each silver row can be traced
            -- back to the bronze load and file it came from
            [source_system],                       -- which system produced the file
            [source_file_name],                    -- which file the row came from
            [batch_id],                            -- ID of the bronze load run
            [ingested_at] AS bronze_ingested_at,   -- when bronze loaded it (renamed for clarity)
            [ingested_by]                          -- who/what ran the bronze load
        FROM [SegPay].[bronze].[affiliates]
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - keep only one row per affiliate
       If the same affiliate_id was loaded more than once (e.g. from two
       file loads), number its rows newest-first and keep only number 1.
       This also prevents a primary-key violation on silver.affiliates.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY affiliate_id           -- restart numbering for each affiliate
                   ORDER BY bronze_ingested_at DESC    -- newest load gets rn = 1
               ) AS rn
        FROM src
        -- Skip rows with no affiliate_id: they can't be identified or keyed
        WHERE affiliate_id IS NOT NULL AND affiliate_id <> ''
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.affiliates (
        affiliate_id, affiliate_name, affiliate_type, commission_pct, status, join_date,
        country, payout_method, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        affiliate_id, affiliate_name, affiliate_type, commission_pct, status, join_date,
        country, payout_method, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by
    FROM dedup
    WHERE rn = 1;          -- only the newest row per affiliate

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded;  -- repeats removed (plus any blank IDs)
END

-- ===== usp_load_all
/* =====================================================================
   Procedure : silver.usp_load_all
   Purpose   : Rebuilds the whole silver layer by running every silver load
               procedure in dependency order.
   Load type : Full refresh - each step empties and rebuilds its own table(s).

   Why the order matters
   ---------------------
   Some silver procedures read other silver tables, so those must be loaded
   first:
       silver.usp_load_sites                    <- silver.merchant_accounts
       silver.usp_load_transactions             <- silver.fx_rates_daily,
                                                   silver.merchant_xref,
                                                   silver.packages,
                                                   silver.response_codes,
                                                   silver.sites
       silver.usp_load_purchases_snapshot       <- silver.transactions,
                                                   silver.packages
       silver.usp_load_chargebacks_acquirer_feed <- silver.chargeback_reason_codes,
                                                   silver.fx_rates_daily
       silver.usp_load_clearing_transactions    <- silver.fx_rates_daily
   Every other procedure reads bronze only.

   Run order
   ---------
     Stage 1 - reference and master data (bronze only)
         1  merchant_accounts         8  chargeback_reason_codes
         2  merchants_crm_export      9  fx_rates_daily
         3  merchant_xref            10  packages
         4  affiliates               11  risk_events
         5  customers                12  settlements_weekly
         6  bin_reference            13  clicks
         7  response_codes           14  conversions
                                     15  helpdesk_tickets
     Stage 2 - depend on stage 1
        16  sites                    (merchant_accounts)
        17  chargebacks_acquirer_feed (chargeback_reason_codes, fx_rates_daily)
        18  clearing_transactions    (fx_rates_daily)
     Stage 3
        19  transactions             (fx_rates_daily, merchant_xref, packages,
                                      response_codes, sites)
     Stage 4
        20  purchases_snapshot       (transactions, packages)

   Behavior
   --------
   * Each step runs in turn; each procedure returns its own one-row summary.
   * If a step fails, the run stops there (later steps may depend on it) and
     the error is raised again so the caller sees it. Steps that already
     finished keep their new data - each procedure commits on its own.
   * At the end (or on failure) a run log is returned: one row per step with
     its status and duration.

   Usage
   -----
     EXEC silver.usp_load_all;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_all
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    /* -----------------------------------------------------------------
       The steps, in the order they must run.
       ----------------------------------------------------------------- */
    DECLARE @Steps TABLE (
        step_no    INT          NOT NULL PRIMARY KEY,
        stage      INT          NOT NULL,
        proc_name  SYSNAME      NOT NULL
    );

    INSERT @Steps (step_no, stage, proc_name) VALUES
        -- Stage 1: reference and master data (read bronze only)
        ( 1, 1, N'silver.usp_load_merchant_accounts'),
        ( 2, 1, N'silver.usp_load_merchants_crm_export'),
        ( 3, 1, N'silver.usp_load_merchant_xref'),
        ( 4, 1, N'silver.usp_load_affiliates'),
        ( 5, 1, N'silver.usp_load_customers'),
        ( 6, 1, N'silver.usp_load_bin_reference'),
        ( 7, 1, N'silver.usp_load_response_codes'),
        ( 8, 1, N'silver.usp_load_chargeback_reason_codes'),
        ( 9, 1, N'silver.usp_load_fx_rates_daily'),
        (10, 1, N'silver.usp_load_packages'),
        (11, 1, N'silver.usp_load_risk_events'),
        (12, 1, N'silver.usp_load_settlements_weekly'),
        (13, 1, N'silver.usp_load_clicks'),
        (14, 1, N'silver.usp_load_conversions'),
        (15, 1, N'silver.usp_load_helpdesk_tickets'),
        -- Stage 2: depend on stage 1
        (16, 2, N'silver.usp_load_sites'),
        (17, 2, N'silver.usp_load_chargebacks_acquirer_feed'),
        (18, 2, N'silver.usp_load_clearing_transactions'),
        -- Stage 3: transactions (needs fx rates, merchant mapping, packages, response codes, sites)
        (19, 3, N'silver.usp_load_transactions'),
        -- Stage 4: purchases (needs transactions and packages)
        (20, 4, N'silver.usp_load_purchases_snapshot');

    -- Run log: one row per step, returned at the end
    DECLARE @Log TABLE (
        step_no      INT           NOT NULL,
        stage        INT           NOT NULL,
        proc_name    SYSNAME       NOT NULL,
        status       VARCHAR(10)   NOT NULL,   -- Succeeded / Failed / Skipped
        started_at   DATETIME2(0)  NULL,       -- UTC
        seconds      INT           NULL,
        error_text   NVARCHAR(4000) NULL
    );

    DECLARE @StepNo    INT = 1,
            @MaxStep   INT,
            @Stage     INT,
            @Proc      SYSNAME,
            @Start     DATETIME2(3),
            @RunStart  DATETIME2(3) = SYSUTCDATETIME(),
            @Failed    BIT = 0,
            @ErrMsg    NVARCHAR(4000);

    SELECT @MaxStep = MAX(step_no) FROM @Steps;

    /* -----------------------------------------------------------------
       Run each step. TRY / CATCH records a failure in the log, then the
       loop stops so no later step runs on missing or stale input.
       ----------------------------------------------------------------- */
    WHILE @StepNo <= @MaxStep AND @Failed = 0
    BEGIN
        SELECT @Stage = stage, @Proc = proc_name FROM @Steps WHERE step_no = @StepNo;
        SET @Start = SYSUTCDATETIME();

        -- Progress message (shown in the SSMS Messages tab)
        RAISERROR(N'Step %d of %d: %s ...', 0, 1, @StepNo, @MaxStep, @Proc) WITH NOWAIT;

        BEGIN TRY
            EXEC @Proc;    -- runs the procedure whose name is in @Proc

            INSERT @Log (step_no, stage, proc_name, status, started_at, seconds)
            VALUES (@StepNo, @Stage, @Proc, 'Succeeded', @Start, DATEDIFF(SECOND, @Start, SYSUTCDATETIME()));
        END TRY
        BEGIN CATCH
            -- Undo the failed step's open transaction, if any
            IF @@TRANCOUNT > 0 ROLLBACK;

            SET @ErrMsg = ERROR_MESSAGE();
            SET @Failed = 1;

            INSERT @Log (step_no, stage, proc_name, status, started_at, seconds, error_text)
            VALUES (@StepNo, @Stage, @Proc, 'Failed', @Start, DATEDIFF(SECOND, @Start, SYSUTCDATETIME()), @ErrMsg);
        END CATCH

        SET @StepNo += 1;
    END

    -- Steps that never ran because an earlier one failed
    INSERT @Log (step_no, stage, proc_name, status)
    SELECT s.step_no, s.stage, s.proc_name, 'Skipped'
    FROM @Steps s
    WHERE NOT EXISTS (SELECT 1 FROM @Log l WHERE l.step_no = s.step_no);

    -- Run log, plus a total line at the bottom
    SELECT step_no, stage, proc_name, status, started_at, seconds, error_text
    FROM (
        SELECT step_no, stage, proc_name, status, started_at, seconds, error_text, 0 AS is_total
        FROM @Log
        UNION ALL
        SELECT NULL, NULL, N'TOTAL', CASE WHEN @Failed = 1 THEN 'Failed' ELSE 'Succeeded' END,
               @RunStart, DATEDIFF(SECOND, @RunStart, SYSUTCDATETIME()), NULL, 1
    ) r
    ORDER BY is_total, step_no;

    -- Re-raise so a caller (SSMS, SQL Agent job, script) sees the run failed
    IF @Failed = 1
    BEGIN
        SET @ErrMsg = N'silver.usp_load_all stopped at ' + @Proc + N': ' + @ErrMsg;
        THROW 50999, @ErrMsg, 1;
    END
END

-- ===== usp_load_bin_reference

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_bin_reference
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.bin_reference', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.bin_reference (
            bin                 VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_bin_reference PRIMARY KEY,
            card_brand          VARCHAR(20)    NULL,      -- Visa / Mastercard / American Express / UnionPay / JCB
            card_type           VARCHAR(10)    NULL,      -- Credit / Debit / Prepaid / 'N/A' when missing
            card_category       VARCHAR(20)    NULL,      -- Standard / Classic / Gold / Platinum / Business / 'N/A'
            issuer_name         NVARCHAR(200)  NULL,      -- issuing bank, country suffix removed
            issuer_country      VARCHAR(3)     NULL,      -- ISO 2-letter code, or 'N/A' when missing
            last_updated        DATE           NULL,      -- when the BIN record changed at the source
            source_system       VARCHAR(50)    NULL,
            source_file_name    NVARCHAR(260)  NULL,
            batch_id            NVARCHAR(100)  NULL,
            bronze_ingested_at  DATETIME2(3)   NULL,
            ingested_by         NVARCHAR(128)  NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_bin_reference_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT;     -- number of rows written to silver (output)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[bin_reference];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.bin_reference;

    /* -----------------------------------------------------------------
       CTE 1: src - clean and standardize every bronze column
       (a CTE is a named temporary result set used by the next query)
       ----------------------------------------------------------------- */
    WITH src AS (
        SELECT 
            -- TRIM removes leading/trailing spaces so ' 424242 ' becomes '424242'
            TRIM(bin) AS bin,

            -- Standardize card brand: 'VI', 'visa', ' VISA ' -> 'Visa', etc.
            -- UPPER(TRIM()) first so any casing or stray spaces match.
            -- Anything not listed becomes NULL so it shows up in data-quality checks.
            CASE UPPER(TRIM(card_brand))
                WHEN 'VISA'             THEN 'Visa'
                WHEN 'VI'               THEN 'Visa'
                WHEN 'MASTERCARD'       THEN 'Mastercard'
                WHEN 'MC'               THEN 'Mastercard'
                WHEN 'AMEX'             THEN 'American Express'
                WHEN 'AX'               THEN 'American Express'
                WHEN 'AMERICAN EXPRESS' THEN 'American Express'
                WHEN 'UNIONPAY'         THEN 'UnionPay'
                WHEN 'UP'               THEN 'UnionPay'
                WHEN 'JCB'              THEN 'JCB'
            END AS card_brand,

            -- Standardize card type to title case: 'C', 'credit', ' CREDIT ' -> 'Credit', etc.
            -- Single-letter codes: C = Credit, D = Debit, P = Prepaid.
            -- Missing (NULL or blank) -> 'N/A'; unrecognized values -> NULL for data-quality checks.
            CASE
                WHEN NULLIF(TRIM(card_type), '') IS NULL THEN 'N/A'
                ELSE CASE UPPER(TRIM(card_type))
                         WHEN 'CREDIT'  THEN 'Credit'
                         WHEN 'C'       THEN 'Credit'
                         WHEN 'DEBIT'   THEN 'Debit'
                         WHEN 'D'       THEN 'Debit'
                         WHEN 'PREPAID' THEN 'Prepaid'
                         WHEN 'P'       THEN 'Prepaid'
                     END
            END AS card_type,

            -- Standardize card category to title case: 'GOLD', 'gold', ' Gold ' -> 'Gold'.
            -- Missing (NULL or blank) -> 'N/A', matching how payout_method handles missing values.
            -- Unrecognized values -> NULL, so they stay distinct from 'N/A' and show up in checks.
            CASE
                WHEN NULLIF(TRIM(card_category), '') IS NULL THEN 'N/A'
                ELSE CASE UPPER(TRIM(card_category))
                         WHEN 'STANDARD' THEN 'Standard'
                         WHEN 'CLASSIC'  THEN 'Classic'
                         WHEN 'GOLD'     THEN 'Gold'
                         WHEN 'PLATINUM' THEN 'Platinum'
                         WHEN 'BUSINESS' THEN 'Business'
                     END
            END AS card_category,

            -- Remove the trailing country code: 'Capital Credit Union DE' -> 'Capital Credit Union'.
            -- The length check stops LEFT from erroring on names of 3 characters or fewer.
            CASE WHEN LEN(TRIM(issuer_name)) > 3 THEN LEFT(TRIM(issuer_name), LEN(TRIM(issuer_name)) - 3)
            END AS issuer_name,

            -- Standardize issuer country to 2-letter ISO codes.
            -- UPPER + TRIM so any casing/spacing matches; periods removed so 'U.S.A.' = 'USA'.
            -- 3-letter codes and full names are mapped; existing 2-letter codes pass through uppercased.
            -- Missing -> 'N/A'; anything unrecognized -> NULL so it shows up in checks.
            CASE
                WHEN NULLIF(TRIM(issuer_country), '') IS NULL THEN 'N/A'
                ELSE CASE REPLACE(UPPER(TRIM(issuer_country)), '.', '')
                    WHEN 'AUS'                      THEN 'AU'
                    WHEN 'AUSTRALIA'                THEN 'AU'
                    WHEN 'BRA'                      THEN 'BR'
                    WHEN 'BRAZIL'                   THEN 'BR'
                    WHEN 'CAN'                      THEN 'CA'
                    WHEN 'CANADA'                   THEN 'CA'
                    WHEN 'DEU'                      THEN 'DE'
                    WHEN 'GERMANY'                  THEN 'DE'
                    WHEN 'DEUTSCHLAND'              THEN 'DE'
                    WHEN 'ESP'                      THEN 'ES'
                    WHEN 'SPAIN'                    THEN 'ES'
                    WHEN 'FRA'                      THEN 'FR'
                    WHEN 'FRANCE'                   THEN 'FR'
                    WHEN 'GBR'                      THEN 'GB'
                    WHEN 'UK'                       THEN 'GB'
                    WHEN 'UNITED KINGDOM'           THEN 'GB'
                    WHEN 'IRL'                      THEN 'IE'
                    WHEN 'IRELAND'                  THEN 'IE'
                    WHEN 'IND'                      THEN 'IN'
                    WHEN 'INDIA'                    THEN 'IN'
                    WHEN 'ITA'                      THEN 'IT'
                    WHEN 'ITALY'                    THEN 'IT'
                    WHEN 'JPN'                      THEN 'JP'
                    WHEN 'JAPAN'                    THEN 'JP'
                    WHEN 'MEX'                      THEN 'MX'
                    WHEN 'MEXICO'                   THEN 'MX'
                    WHEN 'NLD'                      THEN 'NL'
                    WHEN 'NETHERLANDS'              THEN 'NL'
                    WHEN 'HOLLAND'                  THEN 'NL'
                    WHEN 'NOR'                      THEN 'NO'
                    WHEN 'NORWAY'                   THEN 'NO'
                    WHEN 'POL'                      THEN 'PL'
                    WHEN 'POLAND'                   THEN 'PL'
                    WHEN 'SWE'                      THEN 'SE'
                    WHEN 'SWEDEN'                   THEN 'SE'
                    WHEN 'ZAF'                      THEN 'ZA'
                    WHEN 'SOUTH AFRICA'             THEN 'ZA'
                    WHEN 'USA'                      THEN 'US'
                    WHEN 'UNITED STATES'            THEN 'US'
                    WHEN 'UNITED STATES OF AMERICA' THEN 'US'
                    ELSE CASE WHEN LEN(TRIM(issuer_country)) = 2
                              THEN UPPER(TRIM(issuer_country)) END
                END
            END AS issuer_country,

            -- When the BIN record was last changed at the source.
            -- Each format is converted with its own style code; unknown formats -> NULL.
            CASE
                WHEN TRIM(last_updated) LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'
                    THEN TRY_CONVERT(DATE, LEFT(TRIM(last_updated), 10), 23)   -- 2024-10-08 (time part ignored)
                WHEN TRIM(last_updated) LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'
                    THEN TRY_CONVERT(DATE, TRIM(last_updated), 101)            -- 10/08/2024 (MM/DD/YYYY)
                WHEN TRIM(last_updated) LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'
                    THEN TRY_CONVERT(DATE, TRIM(last_updated), 112)            -- 20241008
            END AS last_updated,

            -- Lineage: trace each silver row back to the bronze load and file it came from
            [source_system],                       -- which system produced the file
            [source_file_name],                    -- which file the row came from
            [batch_id],                            -- ID of the bronze load run
            [ingested_at] AS bronze_ingested_at,   -- when bronze loaded it (renamed for clarity)
            [ingested_by]                          -- who/what ran the bronze load
            -- source_file_path deliberately not carried over
            -- silver_loaded_at is filled by the DEFAULT on the silver table

        FROM [SegPay].[bronze].[bin_reference]
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - keep only one row per BIN
       If the same BIN appears more than once (e.g. updated records or
       several file loads), number its rows and keep only number 1:
       the most recently updated record, then the latest bronze load.
       This also prevents a primary-key violation on silver.bin_reference.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY bin                                  -- restart numbering for each BIN
                   ORDER BY last_updated DESC,                       -- newest source update first
                            bronze_ingested_at DESC                  -- then newest bronze load
               ) AS rn
        FROM src
        -- Skip rows with no BIN: they can't be identified or keyed
        WHERE bin IS NOT NULL AND bin <> ''
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.bin_reference (
        bin, card_brand, card_type, card_category, issuer_name, issuer_country,
        last_updated, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        bin, card_brand, card_type, card_category, issuer_name, issuer_country,
        last_updated, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by
    FROM dedup
    WHERE rn = 1;          -- only the newest row per BIN

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded;  -- repeats removed (plus any blank BINs)
END

-- ===== usp_load_chargeback_reason_codes

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_chargeback_reason_codes
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       A reason code is only unique within its network (e.g. two networks
       could reuse the same code), so the key is network + reason_code.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.chargeback_reason_codes', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.chargeback_reason_codes (
            network             VARCHAR(20)    NOT NULL,  -- Visa / Mastercard / American Express / Discover
            reason_code         VARCHAR(10)    NOT NULL,  -- network's code, e.g. 10.4, 4837, F29, UA02
            description         NVARCHAR(200)  NULL,      -- what the code means
            category            VARCHAR(30)    NULL,      -- Fraud / Authorization / Processing Error / Consumer Dispute / 'N/A'
            source_system       VARCHAR(50)    NULL,
            source_file_name    NVARCHAR(260)  NULL,
            batch_id            NVARCHAR(100)  NULL,
            bronze_ingested_at  DATETIME2(3)   NULL,
            ingested_by         NVARCHAR(128)  NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_cb_reason_codes_loaded DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_silver_chargeback_reason_codes PRIMARY KEY (network, reason_code)
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT;     -- number of rows written to silver (output)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[chargeback_reason_codes];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.chargeback_reason_codes;

    /* -----------------------------------------------------------------
       CTE 1: src - clean and standardize every bronze column
       (a CTE is a named temporary result set used by the next query)
       ----------------------------------------------------------------- */
    WITH src AS (
        SELECT
            -- Standardize network to the same names used for card_brand in
            -- silver.bin_reference, so the two tables can be joined/compared.
            -- Abbreviations are included for future files ('MC', 'AX', 'VI', 'DISC').
            -- Anything not listed becomes NULL so it shows up in data-quality checks.
            CASE UPPER(TRIM(network))
                WHEN 'VISA'             THEN 'Visa'
                WHEN 'VI'               THEN 'Visa'
                WHEN 'MASTERCARD'       THEN 'Mastercard'
                WHEN 'MC'               THEN 'Mastercard'
                WHEN 'AMEX'             THEN 'American Express'
                WHEN 'AX'               THEN 'American Express'
                WHEN 'AMERICAN EXPRESS' THEN 'American Express'
                WHEN 'DISCOVER'         THEN 'Discover'
                WHEN 'DISC'             THEN 'Discover'
                WHEN 'UNIONPAY'         THEN 'UnionPay'
                WHEN 'UP'               THEN 'UnionPay'
                WHEN 'JCB'              THEN 'JCB'
            END AS network,

            -- Reason codes are identifiers, not numbers: keep as text so '10.40'
            -- isn't turned into 10.4 and letter codes (F29, UA02, RG) still work.
            -- TRIM removes stray spaces; UPPER makes 'f29' and 'F29' the same code.
            UPPER(TRIM(reason_code)) AS reason_code,

            -- Description is kept as written, just trimmed
            NULLIF(TRIM(description), '') AS description,

            -- Standardize category to title case: 'FRAUD', 'fraud', ' Fraud ' -> 'Fraud'.
            -- Missing (NULL or blank) -> 'N/A', matching the other silver tables.
            -- Unrecognized values -> NULL, so they stay distinct from 'N/A' and show up in checks.
            CASE
                WHEN NULLIF(TRIM(category), '') IS NULL THEN 'N/A'
                ELSE CASE UPPER(TRIM(category))
                         WHEN 'FRAUD'            THEN 'Fraud'
                         WHEN 'AUTHORIZATION'    THEN 'Authorization'
                         WHEN 'PROCESSING ERROR' THEN 'Processing Error'
                         WHEN 'CONSUMER DISPUTE' THEN 'Consumer Dispute'
                     END
            END AS category,

            -- Lineage: trace each silver row back to the bronze load and file it came from
            [source_system],                       -- which system produced the file
            [source_file_name],                    -- which file the row came from
            [batch_id],                            -- ID of the bronze load run
            [ingested_at] AS bronze_ingested_at,   -- when bronze loaded it (renamed for clarity)
            [ingested_by]                          -- who/what ran the bronze load
            -- source_file_path deliberately not carried over
            -- silver_loaded_at is filled by the DEFAULT on the silver table

        FROM [SegPay].[bronze].[chargeback_reason_codes]
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - keep only one row per network + reason code
       If the same code was loaded more than once (e.g. from two file
       loads), number its rows newest-first and keep only number 1.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY network, reason_code     -- restart numbering for each code
                   ORDER BY bronze_ingested_at DESC      -- newest load gets rn = 1
               ) AS rn
        FROM src
        -- Skip rows missing either key part: they can't be identified or keyed
        WHERE network IS NOT NULL
          AND reason_code IS NOT NULL AND reason_code <> ''
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.chargeback_reason_codes (
        network, reason_code, description, category,
        source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        network, reason_code, description, category,
        source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by
    FROM dedup
    WHERE rn = 1;          -- only the newest row per network + reason code

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded;  -- repeats removed (plus rows with an unmapped network or no code)
END

-- ===== usp_load_chargebacks_acquirer_feed

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_chargebacks_acquirer_feed
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.chargebacks_acquirer_feed', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.chargebacks_acquirer_feed (
            case_id                   VARCHAR(50)    NOT NULL CONSTRAINT PK_silver_chargebacks_acquirer_feed PRIMARY KEY,
            network                   VARCHAR(20)    NOT NULL,  -- Visa / Mastercard / American Express / Discover / ...
            reason_code               VARCHAR(20)    NOT NULL,  -- e.g. 10.4, 4837 (network prefix removed)
            reason_category           VARCHAR(30)    NOT NULL,  -- Fraud / Authorization / Processing Error / Consumer Dispute
            reason_desc               NVARCHAR(200)  NOT NULL,  -- from the reference table, normal casing
            arn                       VARCHAR(30)    NOT NULL,  -- Acquirer Reference Number: 23-digit ID the acquirer gives each
                                                                -- card transaction; links the chargeback to the original sale
            mid                       VARCHAR(20)    NOT NULL,  -- Merchant ID: the acquirer's ID for the merchant's processing
                                                                -- account (maps to a merchant via merchant_accounts)
            merchant_descriptor       NVARCHAR(200)  NOT NULL,  -- standardized: SEGPAY*NAME
            merchant_descriptor_name  NVARCHAR(200)  NOT NULL,  -- right side of '*'
            txn_ref                   VARCHAR(20)    NOT NULL,  -- gateway transaction ID
            card_bin                  VARCHAR(10)    NOT NULL,
            card_last4                VARCHAR(10)    NOT NULL,
            orig_txn_date             VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            dispute_amount            VARCHAR(20)    NOT NULL,  -- original currency, 2 decimals
            dispute_ccy               VARCHAR(10)    NOT NULL,
            dispute_amount_usd        VARCHAR(20)    NOT NULL,  -- converted to USD with the US Treasury rate
                                                                -- (most recent on or before orig_txn_date); 'N/A' if none
            fx_rate                   VARCHAR(30)    NOT NULL,  -- US Treasury rate used: USD per 1 unit of dispute_ccy (audit)
            fx_rate_date              VARCHAR(10)    NOT NULL,  -- date of the US Treasury rate used (audit)
            received_date             VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            respond_by                VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            status                    VARCHAR(30)    NOT NULL,  -- e.g. Lost / Won / Accepted
            resolution_date           VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            outcome                   VARCHAR(30)    NOT NULL,  -- e.g. Lost / Won / Accepted
            representment_sent_date   VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            is_representment_sent     VARCHAR(3)     NOT NULL,  -- '1' / '0'
            source_system             VARCHAR(50)    NOT NULL,
            source_file_name          NVARCHAR(260)  NOT NULL,
            batch_id                  VARCHAR(36)    NOT NULL,
            bronze_ingested_at        VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by               NVARCHAR(128)  NOT NULL,
            silver_loaded_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_chargebacks_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT,     -- number of rows written to silver (output)
            @UsdNA  INT;     -- rows whose USD amount could not be calculated

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[chargebacks_acquirer_feed];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.chargebacks_acquirer_feed;

    /* -----------------------------------------------------------------
       CTE 1: fx - US Treasury exchange rates from silver.fx_rates_daily
       Silver already holds only US Treasury rates, one per currency per
       day, all as USD per 1 unit of the currency. The text columns are
       converted back to a date and a number for the lookup.
       ----------------------------------------------------------------- */
    WITH fx AS (
        SELECT
            currency,
            TRY_CAST(rate_date    AS DATE)           AS rate_date,
            TRY_CAST(usd_per_unit AS DECIMAL(18,8))  AS usd_per_unit
        FROM [SegPay].[silver].[fx_rates_daily]
    ),

    /* -----------------------------------------------------------------
       CTE 2: c - values that other steps depend on, cleaned once
       (network and reason_code for the reference-table join;
        amount, currency and date for the USD conversion)
       ----------------------------------------------------------------- */
    c AS (
        SELECT
            b.*,

            -- Network: one name per card network ('VISA' / 'Visa' -> 'Visa')
            CASE UPPER(TRIM(b.network))
                WHEN 'VISA'             THEN 'Visa'
                WHEN 'VI'               THEN 'Visa'
                WHEN 'MASTERCARD'       THEN 'Mastercard'
                WHEN 'MC'               THEN 'Mastercard'
                WHEN 'AMEX'             THEN 'American Express'
                WHEN 'AX'               THEN 'American Express'
                WHEN 'AMERICAN EXPRESS' THEN 'American Express'
                WHEN 'DISCOVER'         THEN 'Discover'
                WHEN 'DISC'             THEN 'Discover'
                WHEN 'UNIONPAY'         THEN 'UnionPay'
                WHEN 'UP'               THEN 'UnionPay'
                WHEN 'JCB'              THEN 'JCB'
            END AS network_clean,

            -- Reason code: hidden characters removed (see x below), then a two-letter
            -- network prefix removed so 'VI-13.2' and ' 13.2' both become '13.2'
            CASE WHEN x.rc LIKE '[A-Z][A-Z]-%' THEN SUBSTRING(x.rc, 4, 50) ELSE x.rc END AS reason_code_clean,

            -- Amount without '$' or thousands commas, as a 2-decimal number
            TRY_CAST(REPLACE(REPLACE(TRIM(b.dispute_amount), '$', ''), ',', '') AS DECIMAL(18,2)) AS dispute_amount_clean,

            -- Currency code, uppercase
            UPPER(TRIM(b.dispute_ccy))                       AS dispute_ccy_clean,

            -- Original transaction date (MM/DD/YYYY in the file)
            TRY_CONVERT(DATE, TRIM(b.orig_txn_date), 101)    AS orig_txn_date_clean
        FROM [SegPay].[bronze].[chargebacks_acquirer_feed] b
        -- Reason code with tabs (9), non-breaking spaces (160), carriage returns (13)
        -- and line feeds (10) removed, then trimmed and uppercased
        CROSS APPLY (SELECT rc = UPPER(TRIM(REPLACE(REPLACE(REPLACE(REPLACE(
                         b.reason_code, CHAR(9), ''), CHAR(160), ''), CHAR(13), ''), CHAR(10), '')))) x
    ),

    /* -----------------------------------------------------------------
       CTE 3: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(TRIM(c.case_id), '')                   AS case_id,
            c.network_clean                               AS network,
            NULLIF(c.reason_code_clean, '')               AS reason_code,

            -- Reference-table category and description (normal casing):
            --   1st choice: match on network + reason code   (rc)
            --   2nd choice: match on the description text     (rcd)
            --   otherwise : raw description / NULL category
            COALESCE(rc.category,    rcd.category)                                     AS reason_category,
            COALESCE(rc.description, rcd.description, NULLIF(TRIM(c.reason_desc), '')) AS reason_desc,

            NULLIF(TRIM(c.arn), '')                       AS arn,   -- Acquirer Reference Number
            NULLIF(TRIM(c.mid), '')                       AS mid,   -- Merchant ID

            -- Descriptor: standardized, plus the name after the '*'
            NULLIF(REPLACE(REPLACE(UPPER(TRIM(c.merchant_descriptor)), ' *', '*'), '* ', '*'), '')
                                                          AS merchant_descriptor,
            CASE WHEN CHARINDEX('*', c.merchant_descriptor) > 0
                 THEN NULLIF(TRIM(SUBSTRING(UPPER(c.merchant_descriptor),
                                            CHARINDEX('*', c.merchant_descriptor) + 1, 200)), '')
            END                                           AS merchant_descriptor_name,

            TRY_CAST(TRIM(c.txn_ref) AS BIGINT)           AS txn_ref,
            NULLIF(TRIM(c.card_bin), '')                  AS card_bin,
            NULLIF(TRIM(c.card_last4), '')                AS card_last4,
            c.orig_txn_date_clean                         AS orig_txn_date,
            c.dispute_amount_clean                        AS dispute_amount,
            NULLIF(c.dispute_ccy_clean, '')               AS dispute_ccy,

            -- USD amount using the US Treasury rate (USD per 1 unit):
            --   USD           -> unchanged
            --   other         -> amount * usd_per_unit
            --   no rate found -> NULL (becomes 'N/A')
            CASE
                WHEN c.dispute_ccy_clean = 'USD' THEN c.dispute_amount_clean
                ELSE CAST(ROUND(c.dispute_amount_clean * r.usd_per_unit, 2) AS DECIMAL(18,2))
            END                                           AS dispute_amount_usd,
            r.usd_per_unit                                AS fx_rate,        -- US Treasury rate used
            r.rate_date                                   AS fx_rate_date,   -- date of that rate

            TRY_CONVERT(DATE, TRIM(c.received_date), 101) AS received_date,
            TRY_CONVERT(DATE, TRIM(c.respond_by), 101)    AS respond_by,

            -- Capitalize: 'LOST' -> 'Lost'
            NULLIF(UPPER(LEFT(TRIM(c.status), 1)) + LOWER(SUBSTRING(TRIM(c.status), 2, 50)), '')   AS status,
            TRY_CONVERT(DATE, TRIM(c.resolution_date), 101) AS resolution_date,
            NULLIF(UPPER(LEFT(TRIM(c.outcome), 1)) + LOWER(SUBSTRING(TRIM(c.outcome), 2, 50)), '') AS outcome,

            -- Representment: the bronze value is the date evidence was sent
            TRY_CONVERT(DATE, TRIM(c.representment_sent), 101) AS representment_sent_date,
            CASE WHEN NULLIF(TRIM(c.representment_sent), '') IS NOT NULL THEN 1 ELSE 0 END
                                                          AS is_representment_sent,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                 AS bronze_ingested_at,
            c.ingested_by
        FROM c
        -- 1st choice: reason description/category matched on the cleaned network + code
        LEFT JOIN [SegPay].[silver].[chargeback_reason_codes] rc
               ON rc.network     = c.network_clean
              AND rc.reason_code = c.reason_code_clean
        -- 2nd choice: match on the description text, ignoring case.
        -- Prefers a row from the same network if the description exists for several networks.
        OUTER APPLY (
            SELECT TOP (1) xr.description, xr.category
            FROM [SegPay].[silver].[chargeback_reason_codes] xr
            WHERE UPPER(xr.description) = UPPER(TRIM(c.reason_desc))
            ORDER BY CASE WHEN xr.network = c.network_clean THEN 0 ELSE 1 END
        ) rcd
        -- Most recent US Treasury rate for the dispute currency on or before the
        -- transaction date; skipped for USD disputes.
        -- OUTER APPLY keeps the dispute even when no rate is found.
        OUTER APPLY (
            SELECT TOP (1) f.usd_per_unit, f.rate_date
            FROM fx f
            WHERE c.dispute_ccy_clean <> 'USD'
              AND f.currency = c.dispute_ccy_clean
              AND f.rate_date <= c.orig_txn_date_clean
              AND f.usd_per_unit > 0
            ORDER BY f.rate_date DESC
        ) r
    ),

    /* -----------------------------------------------------------------
       CTE 4: dedup - keep only one row per case_id
       If a case appears more than once (e.g. resent with an updated
       status), keep the copy from the latest bronze load, then the one
       with the latest resolution date.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY case_id                       -- restart numbering for each case
                   ORDER BY bronze_ingested_at DESC,          -- newest bronze load first
                            resolution_date DESC              -- then most recently resolved
               ) AS rn
        FROM s
        -- Skip rows with no case_id: they can't be identified or keyed
        WHERE case_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.chargebacks_acquirer_feed (
        case_id, network, reason_code, reason_category, reason_desc,
        arn, mid, merchant_descriptor, merchant_descriptor_name,
        txn_ref, card_bin, card_last4, orig_txn_date, dispute_amount, dispute_ccy,
        dispute_amount_usd, fx_rate, fx_rate_date,
        received_date, respond_by, status, resolution_date, outcome,
        representment_sent_date, is_representment_sent,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        case_id,                                                        -- never NULL (filtered above)
        COALESCE(network, 'N/A'),
        COALESCE(reason_code, 'N/A'),
        COALESCE(reason_category, 'N/A'),
        COALESCE(reason_desc, 'N/A'),
        COALESCE(arn, 'N/A'),
        COALESCE(mid, 'N/A'),
        COALESCE(merchant_descriptor, 'N/A'),
        COALESCE(merchant_descriptor_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), txn_ref), 'N/A'),
        COALESCE(card_bin, 'N/A'),
        COALESCE(card_last4, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), orig_txn_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), dispute_amount), 'N/A'),
        COALESCE(dispute_ccy, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), dispute_amount_usd), 'N/A'),
        COALESCE(CONVERT(VARCHAR(30), fx_rate), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), fx_rate_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), received_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), respond_by, 23), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), resolution_date, 23), 'N/A'),
        COALESCE(outcome, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), representment_sent_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(1), is_representment_sent), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per case

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- How many loaded rows have no USD amount (no US Treasury rate found)
    SELECT @UsdNA = COUNT(*) FROM silver.chargebacks_acquirer_feed WHERE dispute_amount_usd = 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated cases removed (plus any rows without a case_id)
           UsdNotAvailable   = @UsdNA;             -- rows with no US Treasury rate (dispute_amount_usd = 'N/A')
END

-- ===== usp_load_clearing_transactions

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_clearing_transactions
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.clearing_transactions', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.clearing_transactions (
            arn                  VARCHAR(30)    NOT NULL CONSTRAINT PK_silver_clearing_transactions PRIMARY KEY,
                                                           -- Acquirer Reference Number: 23-digit ID the acquirer gives each
                                                           -- card transaction; links clearing items to chargebacks
            acquirer             VARCHAR(50)    NOT NULL,  -- Northgate Acquiring / Pacific Merchant Bank / EuroSettle Payments
            batch_period         VARCHAR(7)     NOT NULL,  -- clearing month, YYYY-MM
            batch_item_count     VARCHAR(10)    NOT NULL,  -- items declared in the clearing file
            mid                  VARCHAR(20)    NOT NULL,  -- Merchant ID: the acquirer's ID for the merchant's processing
                                                           -- account (maps to a merchant via merchant_accounts)
            auth_date            VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            clear_date           VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            bin                  VARCHAR(10)    NOT NULL,  -- first 6/8 card digits
            last4                VARCHAR(10)    NOT NULL,  -- last 4 card digits
            currency_code        VARCHAR(10)    NOT NULL,
            amount               VARCHAR(20)    NOT NULL,  -- MAJOR units (e.g. 29.95), 2 decimals
            interchange          VARCHAR(20)    NOT NULL,  -- MAJOR units, 4 decimals
            amount_usd           VARCHAR(20)    NOT NULL,  -- amount in USD with the US Treasury rate
                                                           -- (most recent on or before auth_date); 'N/A' if none
            interchange_usd      VARCHAR(20)    NOT NULL,  -- interchange in USD with the same US Treasury rate
            fx_rate              VARCHAR(30)    NOT NULL,  -- US Treasury rate used: USD per 1 unit of currency_code (audit)
            fx_rate_date         VARCHAR(10)    NOT NULL,  -- date of the US Treasury rate used (audit)
            source_system        VARCHAR(50)    NOT NULL,
            source_file_name     NVARCHAR(260)  NOT NULL,
            batch_id             VARCHAR(36)    NOT NULL,
            bronze_ingested_at   VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by          NVARCHAR(128)  NOT NULL,
            silver_loaded_at     DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_clearing_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze    INT,     -- number of rows in bronze (input)
            @Loaded    INT,     -- number of rows written to silver (output)
            @UnitNA    INT,     -- rows whose minor/major unit flag was missing or invalid
            @UsdNA     INT;     -- rows whose USD amount could not be calculated

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[clearing_transactions];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.clearing_transactions;

    /* -----------------------------------------------------------------
       CTE 1: fx - US Treasury exchange rates from silver.fx_rates_daily
       Silver already holds only US Treasury rates, one per currency per
       day, all as USD per 1 unit of the currency. The text columns are
       converted back to a date and a number for the lookup.
       ----------------------------------------------------------------- */
    WITH fx AS (
        SELECT
            currency,
            TRY_CAST(rate_date    AS DATE)           AS rate_date,
            TRY_CAST(usd_per_unit AS DECIMAL(18,8))  AS usd_per_unit
        FROM [SegPay].[silver].[fx_rates_daily]
    ),

    /* -----------------------------------------------------------------
       CTE 2: c - values that other steps depend on, cleaned once
       (currency + exponent and the minor-unit flag for the amount
        conversion; auth_date for the US Treasury rate lookup)
       ----------------------------------------------------------------- */
    c AS (
        SELECT
            b.*,
            cc.ccy                                         AS currency_clean,
            e.exponent,                                    -- decimal places for the currency
            UPPER(TRIM(b.is_minor_unit))                   AS minor_flag,

            -- Auth date: YYYY-MM-DD (as in the XML) or MM/DD/YYYY
            CASE WHEN TRIM(b.auth_date) LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'
                     THEN TRY_CONVERT(DATE, LEFT(TRIM(b.auth_date), 10), 23)
                 WHEN TRIM(b.auth_date) LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'
                     THEN TRY_CONVERT(DATE, TRIM(b.auth_date), 101)
            END                                            AS auth_date_clean,

            -- Raw numbers before unit conversion
            TRY_CAST(TRIM(b.amount)      AS DECIMAL(18,4)) AS amount_num,
            TRY_CAST(TRIM(b.interchange) AS DECIMAL(18,4)) AS interchange_num
        FROM [SegPay].[bronze].[clearing_transactions] b
        -- Currency code, uppercase
        CROSS APPLY (SELECT ccy = UPPER(TRIM(b.currency_code))) cc
        -- Number of decimal places for the currency (ISO 4217 minor-unit exponent)
        CROSS APPLY (SELECT exponent = CASE cc.ccy
                                           WHEN 'JPY' THEN 0
                                           WHEN 'KRW' THEN 0
                                           WHEN 'KWD' THEN 3
                                           WHEN 'BHD' THEN 3
                                           ELSE 2              -- USD, EUR, GBP, AUD, CAD, ...
                                       END) e
    ),

    /* -----------------------------------------------------------------
       CTE 3: m - amounts converted to MAJOR units
         'Y' -> minor units: divide by 10^exponent   (2995 -> 29.95)
         'N' -> already major: use as is            (29.95 -> 29.95)
         anything else -> NULL (unit unknown; not guessed)
       ----------------------------------------------------------------- */
    m AS (
        SELECT
            c.*,
            CASE c.minor_flag
                WHEN 'Y' THEN c.amount_num / POWER(CAST(10 AS DECIMAL(18,4)), c.exponent)
                WHEN 'N' THEN c.amount_num
            END AS amount_major,
            CASE c.minor_flag
                WHEN 'Y' THEN c.interchange_num / POWER(CAST(10 AS DECIMAL(18,4)), c.exponent)
                WHEN 'N' THEN c.interchange_num
            END AS interchange_major
        FROM c
    ),

    /* -----------------------------------------------------------------
       CTE 4: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(TRIM(m.arn), '')                       AS arn,   -- Acquirer Reference Number

            -- Acquirer: one name per acquirer (same mapping as transactions)
            CASE UPPER(TRIM(m.acquirer))
                WHEN 'NORTHGATE ACQUIRING'   THEN 'Northgate Acquiring'
                WHEN 'NORTHGATE'             THEN 'Northgate Acquiring'
                WHEN 'NG ACQ'                THEN 'Northgate Acquiring'
                WHEN 'PACIFIC MERCHANT BANK' THEN 'Pacific Merchant Bank'
                WHEN 'PACIFIC MERCH BANK'    THEN 'Pacific Merchant Bank'
                WHEN 'PACMB'                 THEN 'Pacific Merchant Bank'
                WHEN 'EUROSETTLE PAYMENTS'   THEN 'EuroSettle Payments'
                WHEN 'EUROSETTLE'            THEN 'EuroSettle Payments'
                ELSE NULLIF(TRIM(m.acquirer), '')
            END                                           AS acquirer,

            -- Clearing month: keep only a valid YYYY-MM
            CASE WHEN TRIM(m.batch_period) LIKE '[12][0-9][0-9][0-9]-[01][0-9]'
                 THEN TRIM(m.batch_period) END            AS batch_period,

            TRY_CAST(TRIM(m.batch_item_count) AS INT)     AS batch_item_count,
            NULLIF(TRIM(m.mid), '')                       AS mid,   -- Merchant ID

            m.auth_date_clean                             AS auth_date,
            CASE WHEN TRIM(m.clear_date) LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'
                     THEN TRY_CONVERT(DATE, LEFT(TRIM(m.clear_date), 10), 23)
                 WHEN TRIM(m.clear_date) LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'
                     THEN TRY_CONVERT(DATE, TRIM(m.clear_date), 101)
            END                                           AS clear_date,

            NULLIF(TRIM(m.bin), '')                       AS bin,
            NULLIF(TRIM(m.last4), '')                     AS last4,
            NULLIF(m.currency_clean, '')                  AS currency_code,

            -- Major-unit amounts
            CAST(ROUND(m.amount_major, 2)      AS DECIMAL(18,2)) AS amount,
            CAST(ROUND(m.interchange_major, 4) AS DECIMAL(18,4)) AS interchange,

            -- USD values using the US Treasury rate (USD per 1 unit):
            --   USD           -> unchanged
            --   other         -> value * usd_per_unit
            --   no rate found -> NULL (becomes 'N/A')
            CASE
                WHEN m.currency_clean = 'USD' THEN CAST(ROUND(m.amount_major, 2) AS DECIMAL(18,2))
                ELSE CAST(ROUND(m.amount_major * r.usd_per_unit, 2) AS DECIMAL(18,2))
            END                                           AS amount_usd,
            CASE
                WHEN m.currency_clean = 'USD' THEN CAST(ROUND(m.interchange_major, 4) AS DECIMAL(18,4))
                ELSE CAST(ROUND(m.interchange_major * r.usd_per_unit, 4) AS DECIMAL(18,4))
            END                                           AS interchange_usd,
            r.usd_per_unit                                AS fx_rate,        -- US Treasury rate used
            r.rate_date                                   AS fx_rate_date,   -- date of that rate

            -- Lineage
            m.source_system,
            m.source_file_name,
            m.batch_id,
            m.ingested_at                                 AS bronze_ingested_at,
            m.ingested_by
        FROM m
        -- Most recent US Treasury rate for the item's currency on or before the
        -- auth date; skipped for USD items.
        -- OUTER APPLY keeps the item even when no rate is found.
        OUTER APPLY (
            SELECT TOP (1) f.usd_per_unit, f.rate_date
            FROM fx f
            WHERE m.currency_clean <> 'USD'
              AND f.currency = m.currency_clean
              AND f.rate_date <= m.auth_date_clean
              AND f.usd_per_unit > 0
            ORDER BY f.rate_date DESC
        ) r
    ),

    /* -----------------------------------------------------------------
       CTE 5: dedup - keep only one row per ARN
       If an ARN appears more than once (e.g. a clearing file loaded
       twice), keep the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY arn                    -- restart numbering for each ARN
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        -- Skip rows with no ARN: they can't be identified or keyed
        WHERE arn IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.clearing_transactions (
        arn, acquirer, batch_period, batch_item_count, mid,
        auth_date, clear_date, bin, last4, currency_code,
        amount, interchange, amount_usd, interchange_usd, fx_rate, fx_rate_date,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        arn,                                                            -- never NULL (filtered above)
        COALESCE(acquirer, 'N/A'),
        COALESCE(batch_period, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), batch_item_count), 'N/A'),
        COALESCE(mid, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), auth_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), clear_date, 23), 'N/A'),
        COALESCE(bin, 'N/A'),
        COALESCE(last4, 'N/A'),
        COALESCE(currency_code, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), amount), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), interchange), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), amount_usd), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), interchange_usd), 'N/A'),
        COALESCE(CONVERT(VARCHAR(30), fx_rate), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), fx_rate_date, 23), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per ARN

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Rows whose amounts could not be read because the unit flag was missing/invalid
    SELECT @UnitNA = COUNT(*)
    FROM [SegPay].[bronze].[clearing_transactions]
    WHERE UPPER(TRIM(is_minor_unit)) NOT IN ('Y','N') OR is_minor_unit IS NULL;

    -- Rows with no USD amount (no US Treasury rate found, or no amount)
    SELECT @UsdNA = COUNT(*) FROM silver.clearing_transactions WHERE amount_usd = 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated ARNs removed (plus any rows without an ARN)
           UnitFlagInvalid   = @UnitNA,            -- bronze rows with is_minor_unit not Y/N (amounts left as 'N/A')
           UsdNotAvailable   = @UsdNA;             -- rows where amount_usd = 'N/A'
END

-- ===== usp_load_clicks

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_clicks
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.clicks', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.clicks (
            click_id            VARCHAR(50)    NOT NULL CONSTRAINT PK_silver_clicks PRIMARY KEY,
            click_ts_utc        VARCHAR(23)    NOT NULL,  -- click time, UTC, YYYY-MM-DD hh:mm:ss.mmm
            publisher_id        VARCHAR(10)    NOT NULL,  -- tracker's publisher (affiliate) number
            affiliate_id        VARCHAR(20)    NOT NULL,  -- publisher_id as AFF-0000 (ASSUMED mapping to affiliates)
            offer_id            VARCHAR(10)    NOT NULL,  -- offer being promoted
            sub_id              VARCHAR(100)   NOT NULL,  -- publisher's own tracking value
            ip                  VARCHAR(45)    NOT NULL,  -- visitor IP (IPv4 or IPv6) - personal data
            ua_family           VARCHAR(30)    NOT NULL,  -- browser family, e.g. Chrome, Safari iOS, Bot/Unknown
            device_category     VARCHAR(10)    NOT NULL,  -- Mobile / Desktop (from ua_family)
            is_bot              VARCHAR(3)     NOT NULL,  -- '1' = bot/unknown traffic, '0' = known browser
            country             VARCHAR(3)     NOT NULL,  -- visitor country, 2-letter code (bronze: geo)
            landing_variant     VARCHAR(20)    NOT NULL,  -- landing page A/B variant, e.g. lp_a
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_clicks_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT,     -- number of rows written to silver (output)
            @Bots   INT;     -- clicks flagged as bot/unknown traffic

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[clicks];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.clicks;

    /* -----------------------------------------------------------------
       CTE 1: c - values that other steps depend on, cleaned once
       ----------------------------------------------------------------- */
    WITH c AS (
        SELECT
            b.*,
            -- click_ts_ms as a number (Unix epoch milliseconds)
            TRY_CAST(TRIM(b.click_ts_ms) AS BIGINT)   AS ts_ms,
            -- publisher_id as a number (used for publisher_id and affiliate_id)
            TRY_CAST(TRIM(b.publisher_id) AS INT)     AS pub_id,
            -- browser family, trimmed and uppercased for matching
            UPPER(TRIM(b.ua_family))                  AS ua
        FROM [SegPay].[bronze].[clicks] b
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(TRIM(c.click_id), '')                  AS click_id,

            -- Epoch milliseconds -> UTC date/time: 1776421035000 -> 2026-04-17 10:17:15.000
            -- (split into seconds + leftover ms because DATEADD only accepts an INT)
            DATEADD(MILLISECOND, c.ts_ms % 1000,
                DATEADD(SECOND, c.ts_ms / 1000, CAST('1970-01-01' AS DATETIME2(3))))
                                                          AS click_ts_utc,

            c.pub_id                                      AS publisher_id,

            -- Affiliate ID in the affiliates table format: 4 -> 'AFF-0004'
            -- ASSUMPTION: publisher number = number in the affiliate ID (verify)
            CASE WHEN c.pub_id IS NOT NULL
                 THEN 'AFF-' + RIGHT('0000' + CONVERT(VARCHAR(10), c.pub_id), 4)
            END                                           AS affiliate_id,

            TRY_CAST(TRIM(c.offer_id) AS INT)             AS offer_id,
            NULLIF(TRIM(c.sub_id), '')                    AS sub_id,
            NULLIF(TRIM(c.ip), '')                        AS ip,

            -- Browser family: known values kept; 'bot/unknown' -> 'Bot/Unknown'
            CASE c.ua
                WHEN 'CHROME'           THEN 'Chrome'
                WHEN 'CHROME MOBILE'    THEN 'Chrome Mobile'
                WHEN 'SAFARI'           THEN 'Safari'
                WHEN 'SAFARI IOS'       THEN 'Safari iOS'
                WHEN 'EDGE'             THEN 'Edge'
                WHEN 'FIREFOX'          THEN 'Firefox'
                WHEN 'SAMSUNG INTERNET' THEN 'Samsung Internet'
                WHEN 'BOT/UNKNOWN'      THEN 'Bot/Unknown'
            END                                           AS ua_family,

            -- Device category from the browser family; bots/unknown -> NULL
            CASE c.ua
                WHEN 'CHROME MOBILE'    THEN 'Mobile'
                WHEN 'SAFARI IOS'       THEN 'Mobile'
                WHEN 'SAMSUNG INTERNET' THEN 'Mobile'
                WHEN 'CHROME'           THEN 'Desktop'
                WHEN 'SAFARI'           THEN 'Desktop'
                WHEN 'EDGE'             THEN 'Desktop'
                WHEN 'FIREFOX'          THEN 'Desktop'
            END                                           AS device_category,

            -- 1 = bot/unknown traffic, 0 = known browser, NULL = browser missing
            CASE WHEN c.ua = 'BOT/UNKNOWN' THEN 1
                 WHEN c.ua IS NOT NULL AND c.ua <> '' THEN 0
            END                                           AS is_bot,

            -- Visitor country (bronze column geo): 2-letter code, uppercased; anything else -> NULL
            CASE WHEN TRIM(c.geo) LIKE '[A-Za-z][A-Za-z]' THEN UPPER(TRIM(c.geo)) END AS country,

            -- Landing page variant: trimmed, lowercase
            NULLIF(LOWER(TRIM(c.landing_variant)), '')    AS landing_variant,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                 AS bronze_ingested_at,
            c.ingested_by
        FROM c
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - keep only one row per click_id
       If a click appears more than once (e.g. the file loaded twice),
       keep the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY click_id               -- restart numbering for each click
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        -- Skip rows with no click_id: they can't be identified or keyed
        WHERE click_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Timestamps use style 121 (YYYY-MM-DD hh:mm:ss.mmm).
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.clicks (
        click_id, click_ts_utc, publisher_id, affiliate_id, offer_id, sub_id, ip,
        ua_family, device_category, is_bot, country, landing_variant,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        click_id,                                                       -- never NULL (filtered above)
        COALESCE(CONVERT(VARCHAR(23), click_ts_utc, 121), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), publisher_id), 'N/A'),
        COALESCE(affiliate_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), offer_id), 'N/A'),
        COALESCE(sub_id, 'N/A'),
        COALESCE(ip, 'N/A'),
        COALESCE(ua_family, 'N/A'),
        COALESCE(device_category, 'N/A'),
        COALESCE(CONVERT(VARCHAR(1), is_bot), 'N/A'),
        COALESCE(country, 'N/A'),
        COALESCE(landing_variant, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per click

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- How many loaded clicks are bot/unknown traffic
    SELECT @Bots = COUNT(*) FROM silver.clicks WHERE is_bot = '1';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated clicks removed (plus any rows without a click_id)
           BotClicks         = @Bots;              -- clicks flagged is_bot = '1'
END

-- ===== usp_load_conversions

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_conversions
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.conversions', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.conversions (
            conversion_id       VARCHAR(50)    NOT NULL CONSTRAINT PK_silver_conversions PRIMARY KEY,
            click_id            VARCHAR(50)    NOT NULL,  -- click that converted (joins to silver.clicks)
            conversion_ts_utc   VARCHAR(23)    NOT NULL,  -- conversion time, UTC, YYYY-MM-DD hh:mm:ss.mmm
            order_id            VARCHAR(20)    NOT NULL,  -- purchase created (joins to transactions purchase_id)
            event               VARCHAR(30)    NOT NULL,  -- event type, e.g. Sale
            payout_usd          VARCHAR(20)    NOT NULL,  -- amount owed to the affiliate, USD, 2 decimals
            status              VARCHAR(30)    NOT NULL,  -- Approved / Pending / Rejected
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_conversions_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze     INT,     -- number of rows in bronze (input)
            @Loaded     INT,     -- number of rows written to silver (output)
            @NoOrderId  INT;     -- conversions with no order_id (can't be linked to a purchase)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[conversions];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.conversions;

    /* -----------------------------------------------------------------
       CTE 1: c - values that other steps depend on, cleaned once
       ----------------------------------------------------------------- */
    WITH c AS (
        SELECT
            b.*,
            -- conversion_ts_ms as a number (Unix epoch milliseconds)
            TRY_CAST(TRIM(b.conversion_ts_ms) AS BIGINT)  AS ts_ms
        FROM [SegPay].[bronze].[conversions] b
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(TRIM(c.conversion_id), '')             AS conversion_id,
            NULLIF(TRIM(c.click_id), '')                  AS click_id,

            -- Epoch milliseconds -> UTC date/time: 1727772163000 -> 2024-10-01 08:42:43.000
            -- (split into seconds + leftover ms because DATEADD only accepts an INT)
            DATEADD(MILLISECOND, c.ts_ms % 1000,
                DATEADD(SECOND, c.ts_ms / 1000, CAST('1970-01-01' AS DATETIME2(3))))
                                                          AS conversion_ts_utc,

            -- Order created by the conversion (same format as transactions purchase_id)
            TRY_CAST(TRIM(c.order_id) AS BIGINT)          AS order_id,

            -- Capitalize: 'sale' -> 'Sale'
            NULLIF(UPPER(LEFT(TRIM(c.event), 1)) + LOWER(SUBSTRING(TRIM(c.event), 2, 50)), '')   AS event,

            -- Payout in USD: '$' and thousands commas removed, 2 decimals ('11.9900' -> 11.99)
            CAST(ROUND(TRY_CAST(REPLACE(REPLACE(TRIM(c.payout_usd), '$', ''), ',', '') AS DECIMAL(18,4)), 2)
                 AS DECIMAL(18,2))                        AS payout_usd,

            -- Capitalize: 'approved' -> 'Approved'
            NULLIF(UPPER(LEFT(TRIM(c.status), 1)) + LOWER(SUBSTRING(TRIM(c.status), 2, 50)), '') AS status,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                 AS bronze_ingested_at,
            c.ingested_by
        FROM c
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - keep only one row per conversion_id
       If a conversion appears more than once (e.g. the file loaded twice),
       keep the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY conversion_id          -- restart numbering for each conversion
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        -- Skip rows with no conversion_id: they can't be identified or keyed
        WHERE conversion_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Timestamps use style 121 (YYYY-MM-DD hh:mm:ss.mmm).
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.conversions (
        conversion_id, click_id, conversion_ts_utc, order_id, event, payout_usd, status,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        conversion_id,                                                  -- never NULL (filtered above)
        COALESCE(click_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), conversion_ts_utc, 121), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), order_id), 'N/A'),
        COALESCE(event, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), payout_usd), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per conversion

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- How many loaded conversions have no order_id
    SELECT @NoOrderId = COUNT(*) FROM silver.conversions WHERE order_id = 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated conversions removed (plus any rows without a conversion_id)
           OrderIdMissing    = @NoOrderId;         -- conversions that can't be linked to a purchase
END

-- ===== usp_load_customers

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_customers
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.customers', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.customers (
            customer_id         VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_customers PRIMARY KEY,
            email               NVARCHAR(320)  NOT NULL,  -- lowercased - personal data
            country             VARCHAR(3)     NOT NULL,  -- ISO 2-letter code, or 'N/A'
            postal_code         VARCHAR(20)    NOT NULL,  -- uppercased text - personal data
            created_at          VARCHAR(10)    NOT NULL,  -- account creation date, YYYY-MM-DD
            marketing_opt_in    VARCHAR(3)     NOT NULL,  -- '1' = opted in, '0' = opted out, 'N/A' = no answer
                                                          -- (only '1' may be marketed to)
            last_updated        VARCHAR(10)    NOT NULL,  -- last change at the source, YYYY-MM-DD
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_customers_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze    INT,     -- number of rows in bronze (input)
            @Loaded    INT,     -- number of rows written to silver (output)
            @OptedIn   INT,     -- customers with marketing_opt_in = '1'
            @OptInNA   INT;     -- customers with no marketing answer recorded

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[customers];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.customers;

    /* -----------------------------------------------------------------
       CTE 1: c - values that other steps depend on, cleaned once
       ----------------------------------------------------------------- */
    WITH c AS (
        SELECT
            b.*,
            NULLIF(TRIM(b.created_at), '')     AS ca,     -- created_at, trimmed
            NULLIF(TRIM(b.last_updated), '')   AS lu,     -- last_updated, trimmed
            NULLIF(TRIM(b.country), '')        AS ctry    -- country, trimmed
        FROM [SegPay].[bronze].[customers] b
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(UPPER(TRIM(c.customer_id)), '')        AS customer_id,

            -- Email: trimmed, lowercased
            NULLIF(LOWER(TRIM(c.email)), '')              AS email,

            -- Country: 2-letter ISO code (same mapping as bin_reference.issuer_country)
            CASE REPLACE(UPPER(c.ctry), '.', '')
                WHEN 'AUS'                      THEN 'AU'
                WHEN 'AUSTRALIA'                THEN 'AU'
                WHEN 'BRA'                      THEN 'BR'
                WHEN 'BRAZIL'                   THEN 'BR'
                WHEN 'CAN'                      THEN 'CA'
                WHEN 'CANADA'                   THEN 'CA'
                WHEN 'DEU'                      THEN 'DE'
                WHEN 'GERMANY'                  THEN 'DE'
                WHEN 'DEUTSCHLAND'              THEN 'DE'
                WHEN 'ESP'                      THEN 'ES'
                WHEN 'SPAIN'                    THEN 'ES'
                WHEN 'FRA'                      THEN 'FR'
                WHEN 'FRANCE'                   THEN 'FR'
                WHEN 'GBR'                      THEN 'GB'
                WHEN 'UK'                       THEN 'GB'
                WHEN 'UNITED KINGDOM'           THEN 'GB'
                WHEN 'IRL'                      THEN 'IE'
                WHEN 'IRELAND'                  THEN 'IE'
                WHEN 'IND'                      THEN 'IN'
                WHEN 'INDIA'                    THEN 'IN'
                WHEN 'ITA'                      THEN 'IT'
                WHEN 'ITALY'                    THEN 'IT'
                WHEN 'JPN'                      THEN 'JP'
                WHEN 'JAPAN'                    THEN 'JP'
                WHEN 'MEX'                      THEN 'MX'
                WHEN 'MEXICO'                   THEN 'MX'
                WHEN 'NLD'                      THEN 'NL'
                WHEN 'NETHERLANDS'              THEN 'NL'
                WHEN 'HOLLAND'                  THEN 'NL'
                WHEN 'NOR'                      THEN 'NO'
                WHEN 'NORWAY'                   THEN 'NO'
                WHEN 'POL'                      THEN 'PL'
                WHEN 'POLAND'                   THEN 'PL'
                WHEN 'SWE'                      THEN 'SE'
                WHEN 'SWEDEN'                   THEN 'SE'
                WHEN 'ZAF'                      THEN 'ZA'
                WHEN 'SOUTH AFRICA'             THEN 'ZA'
                WHEN 'USA'                      THEN 'US'
                WHEN 'UNITED STATES'            THEN 'US'
                WHEN 'UNITED STATES OF AMERICA' THEN 'US'
                ELSE CASE WHEN LEN(REPLACE(c.ctry, '.', '')) = 2
                          THEN UPPER(REPLACE(c.ctry, '.', '')) END
            END                                           AS country,

            -- Postal code: trimmed, uppercased, kept as text
            NULLIF(UPPER(TRIM(c.postal_code)), '')        AS postal_code,

            -- Account creation date: each format converted with its own style code
            CASE
                WHEN c.ca LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'         -- 08/24/2026
                    THEN TRY_CONVERT(DATE, c.ca, 101)
                WHEN c.ca LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'        -- 2026-08-24
                    THEN TRY_CONVERT(DATE, LEFT(c.ca, 10), 23)
                WHEN c.ca LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'           -- 20260824
                    THEN TRY_CONVERT(DATE, c.ca, 112)
                WHEN c.ca LIKE '[0-3][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]'   -- 24-Aug-26
                    THEN TRY_CONVERT(DATE, REPLACE(c.ca, '-', ' '), 6)            -- style 6 = dd mon yy
            END                                           AS created_at,

            -- Marketing consent: '1' opted in, '0' opted out, NULL = no answer (becomes 'N/A')
            CASE UPPER(TRIM(c.marketing_opt_in))
                WHEN 'TRUE'  THEN '1'
                WHEN 'Y'     THEN '1'
                WHEN 'YES'   THEN '1'
                WHEN '1'     THEN '1'
                WHEN 'FALSE' THEN '0'
                WHEN 'N'     THEN '0'
                WHEN 'NO'    THEN '0'
                WHEN '0'     THEN '0'
            END                                           AS marketing_opt_in,

            -- Last update date: same formats as created_at
            CASE
                WHEN c.lu LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'
                    THEN TRY_CONVERT(DATE, c.lu, 101)
                WHEN c.lu LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'
                    THEN TRY_CONVERT(DATE, LEFT(c.lu, 10), 23)
                WHEN c.lu LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'
                    THEN TRY_CONVERT(DATE, c.lu, 112)
                WHEN c.lu LIKE '[0-3][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]'
                    THEN TRY_CONVERT(DATE, REPLACE(c.lu, '-', ' '), 6)
            END                                           AS last_updated,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                 AS bronze_ingested_at,
            c.ingested_by
        FROM c
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - keep only one row per customer_id
       If a customer appears more than once, keep the most recently
       updated record, then the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY customer_id            -- restart numbering for each customer
                   ORDER BY last_updated DESC,         -- most recent source update first
                            bronze_ingested_at DESC    -- then newest bronze load
               ) AS rn
        FROM s
        -- Skip rows with no customer_id: they can't be identified or keyed
        WHERE customer_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.customers (
        customer_id, email, country, postal_code, created_at, marketing_opt_in, last_updated,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        customer_id,                                                    -- never NULL (filtered above)
        COALESCE(email, 'N/A'),
        COALESCE(country, 'N/A'),
        COALESCE(postal_code, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), created_at, 23), 'N/A'),
        COALESCE(marketing_opt_in, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), last_updated, 23), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per customer

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Marketing consent counts
    SELECT @OptedIn = COUNT(*) FROM silver.customers WHERE marketing_opt_in = '1';
    SELECT @OptInNA = COUNT(*) FROM silver.customers WHERE marketing_opt_in = 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated customers removed (plus any rows without a customer_id)
           MarketingOptedIn  = @OptedIn,           -- customers who may be marketed to
           MarketingNoAnswer = @OptInNA;           -- customers with no consent recorded (do not market)
END

-- ===== usp_load_fx_rates_daily

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_fx_rates_daily
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       The key is currency + rate_date (one US Treasury rate per currency per day).
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.fx_rates_daily', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.fx_rates_daily (
            rate_date           VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            currency            VARCHAR(3)     NOT NULL,  -- non-USD currency, e.g. GBP, AUD, EUR, CAD
            usd_per_unit        VARCHAR(30)    NOT NULL,  -- US Treasury rate: USD per 1 unit of currency
                                                          -- (amount * usd_per_unit = amount in USD)
            units_per_usd       VARCHAR(30)    NOT NULL,  -- inverse: units of currency per 1 USD
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_fx_rates_loaded DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_silver_fx_rates_daily PRIMARY KEY (currency, rate_date)
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze    INT,     -- all rows in bronze (input)
            @Treasury  INT,     -- bronze rows from the US Treasury feed
            @Loaded    INT;     -- rows written to silver (output)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze   = COUNT(*) FROM [SegPay].[bronze].[fx_rates_daily];
    SELECT @Treasury = COUNT(*) FROM [SegPay].[bronze].[fx_rates_daily]
    WHERE UPPER(TRIM(source)) = 'TREASURY-FEED';

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.fx_rates_daily;

    /* -----------------------------------------------------------------
       CTE 1: c - US Treasury rows only, with date, pair and rate cleaned
       ----------------------------------------------------------------- */
    WITH c AS (
        SELECT
            b.*,
            TRY_CONVERT(DATE, TRIM(b.rate_date), 23)        AS rate_date_clean,   -- YYYY-MM-DD
            UPPER(REPLACE(TRIM(b.pair), '/', ''))           AS pair_clean,        -- 'gbp/usd' -> 'GBPUSD'
            TRY_CAST(TRIM(b.rate) AS DECIMAL(18,8))         AS rate_num
        FROM [SegPay].[bronze].[fx_rates_daily] b
        WHERE UPPER(TRIM(b.source)) = 'TREASURY-FEED'       -- US Treasury rates only; ECB etc. excluded
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - currency and rates in one direction (USD per 1 unit)
         XXXUSD (e.g. GBPUSD): currency = first 3 letters, usd_per_unit = rate
         USDXXX (e.g. USDCAD): currency = last 3 letters,  usd_per_unit = 1 / rate
         anything else: currency NULL -> row skipped
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            c.rate_date_clean                               AS rate_date,

            CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' AND c.pair_clean <> 'USDUSD' THEN LEFT(c.pair_clean, 3)
                 WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]'                             THEN RIGHT(c.pair_clean, 3)
            END                                             AS currency,

            CAST(ROUND(
                CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' THEN c.rate_num
                     WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]' THEN 1.0 / c.rate_num
                END, 8) AS DECIMAL(18,8))                   AS usd_per_unit,

            CAST(ROUND(
                CASE WHEN c.pair_clean LIKE '[A-Z][A-Z][A-Z]USD' THEN 1.0 / c.rate_num
                     WHEN c.pair_clean LIKE 'USD[A-Z][A-Z][A-Z]' THEN c.rate_num
                END, 8) AS DECIMAL(18,8))                   AS units_per_usd,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                   AS bronze_ingested_at,
            c.ingested_by
        FROM c
        WHERE c.rate_num > 0                                -- skip missing, zero or negative rates
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - keep only one row per currency per date
       If the same currency and date appear more than once, keep the
       copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY currency, rate_date    -- restart numbering for each currency + date
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        -- Skip rows that can't be keyed (no valid date, or not a USD pair)
        WHERE currency IS NOT NULL
          AND rate_date IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.fx_rates_daily (
        rate_date, currency, usd_per_unit, units_per_usd,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(10), rate_date, 23),                            -- never NULL (filtered above)
        currency,                                                       -- never NULL (filtered above)
        COALESCE(CONVERT(VARCHAR(30), usd_per_unit), 'N/A'),
        COALESCE(CONVERT(VARCHAR(30), units_per_usd), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per currency per date

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Return a one-row summary of the load
    SELECT BronzeRows         = @Bronze,              -- all rows in bronze
           OtherSourcesRemoved = @Bronze - @Treasury, -- ECB and other non-Treasury rows excluded
           TreasuryRows       = @Treasury,            -- US Treasury rows in bronze
           SilverRows         = @Loaded,              -- rows written to silver
           TreasuryRowsDropped = @Treasury - @Loaded; -- Treasury rows skipped (duplicates, non-USD pairs, bad values)
END

-- ===== usp_load_helpdesk_tickets

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_helpdesk_tickets
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.helpdesk_tickets', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.helpdesk_tickets (
            ticket_id            VARCHAR(30)    NOT NULL CONSTRAINT PK_silver_helpdesk_tickets PRIMARY KEY,
            requester_email      NVARCHAR(320)  NOT NULL,  -- lowercased - personal data
            order_ref            VARCHAR(50)    NOT NULL,  -- as written, e.g. SP-4140960
            order_id             VARCHAR(20)    NOT NULL,  -- number from order_ref (ASSUMED = transactions purchase_id)
            brand_domain         VARCHAR(200)   NOT NULL,  -- lowercased domain, e.g. pixelacademy.com
            category             VARCHAR(100)   NOT NULL,  -- e.g. Refund Request, Billing Question
            priority             VARCHAR(20)    NOT NULL,  -- Low / Normal / High / Urgent
            status               VARCHAR(20)    NOT NULL,  -- e.g. Solved
            created_at           VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss
            solved_at            VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss, 'N/A' if not solved
            first_reply_minutes  VARCHAR(10)    NOT NULL,  -- minutes to first agent reply
            resolution_minutes   VARCHAR(10)    NOT NULL,  -- minutes from created_at to solved_at
            csat                 VARCHAR(20)    NOT NULL,  -- Good / Bad / Offered (no answer)
            assignee             VARCHAR(100)   NOT NULL,  -- agent username, or Unassigned
            channel              VARCHAR(20)    NOT NULL,  -- Email / Phone / Chat / Web Form
            tags                 VARCHAR(500)   NOT NULL,  -- pipe-separated, e.g. vip|repeat_contact
            source_system        VARCHAR(50)    NOT NULL,
            source_file_name     NVARCHAR(260)  NOT NULL,
            batch_id             VARCHAR(36)    NOT NULL,
            bronze_ingested_at   VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by          NVARCHAR(128)  NOT NULL,
            silver_loaded_at     DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_helpdesk_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze     INT,     -- number of rows in bronze (input)
            @Loaded     INT,     -- number of rows written to silver (output)
            @NoOrderId  INT;     -- tickets with no usable order number

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[helpdesk_tickets];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.helpdesk_tickets;

    /* -----------------------------------------------------------------
       CTE 1: c - values that other steps depend on, cleaned once
       ----------------------------------------------------------------- */
    WITH c AS (
        SELECT
            b.*,
            UPPER(TRIM(b.order_ref))                       AS oref,

            -- Created / solved times: DD/MM/YYYY hh:mm (day first) -> style 103
            CASE WHEN TRIM(b.created_at) LIKE '[0-3][0-9]/[01][0-9]/[12][0-9][0-9][0-9]%'
                 THEN TRY_CONVERT(DATETIME2(0), TRIM(b.created_at), 103) END AS created_dt,
            CASE WHEN TRIM(b.solved_at)  LIKE '[0-3][0-9]/[01][0-9]/[12][0-9][0-9][0-9]%'
                 THEN TRY_CONVERT(DATETIME2(0), TRIM(b.solved_at), 103)  END AS solved_dt
        FROM [SegPay].[bronze].[helpdesk_tickets] b
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            NULLIF(UPPER(TRIM(c.ticket_id)), '')          AS ticket_id,
            NULLIF(LOWER(TRIM(c.requester_email)), '')    AS requester_email,
            NULLIF(c.oref, '')                            AS order_ref,

            -- Number after 'SP-': 'SP-4140960' -> 4140960 (NULL if not that format)
            CASE WHEN c.oref LIKE 'SP-%'
                 THEN TRY_CAST(SUBSTRING(c.oref, 4, 30) AS BIGINT) END AS order_id,

            -- Domain: lowercase, without http(s):// or www.
            NULLIF(REPLACE(REPLACE(REPLACE(LOWER(TRIM(c.brand_domain)),
                   'https://', ''), 'http://', ''), 'www.', ''), '') AS brand_domain,

            NULLIF(TRIM(c.category), '')                  AS category,

            -- Capitalize: 'urgent' -> 'Urgent', 'solved' -> 'Solved'
            NULLIF(UPPER(LEFT(TRIM(c.priority), 1)) + LOWER(SUBSTRING(TRIM(c.priority), 2, 50)), '') AS priority,
            NULLIF(UPPER(LEFT(TRIM(c.status), 1))   + LOWER(SUBSTRING(TRIM(c.status), 2, 50)), '')   AS status,

            c.created_dt                                  AS created_at,
            c.solved_dt                                   AS solved_at,

            TRY_CAST(TRIM(c.first_reply_minutes) AS INT)  AS first_reply_minutes,

            -- Minutes from created to solved; NULL if missing or negative
            CASE WHEN c.solved_dt >= c.created_dt
                 THEN DATEDIFF(MINUTE, c.created_dt, c.solved_dt) END AS resolution_minutes,

            -- Capitalize: 'good' -> 'Good', 'offered' -> 'Offered'
            NULLIF(UPPER(LEFT(TRIM(c.csat), 1)) + LOWER(SUBSTRING(TRIM(c.csat), 2, 50)), '') AS csat,

            -- Agent: lowercase username; 'agent_unassigned' -> 'Unassigned'
            CASE WHEN LOWER(TRIM(c.assignee)) = 'agent_unassigned' THEN 'Unassigned'
                 ELSE NULLIF(LOWER(TRIM(c.assignee)), '') END AS assignee,

            -- Channel: known values standardized, others capitalized
            CASE LOWER(TRIM(c.channel))
                WHEN 'email'    THEN 'Email'
                WHEN 'phone'    THEN 'Phone'
                WHEN 'chat'     THEN 'Chat'
                WHEN 'web_form' THEN 'Web Form'
                ELSE NULLIF(UPPER(LEFT(TRIM(c.channel), 1)) + LOWER(SUBSTRING(TRIM(c.channel), 2, 50)), '')
            END                                           AS channel,

            -- Tags: lowercase, no spaces around the '|' separator
            NULLIF(REPLACE(REPLACE(LOWER(TRIM(c.tags)), ' |', '|'), '| ', '|'), '') AS tags,

            -- Lineage
            c.source_system,
            c.source_file_name,
            c.batch_id,
            c.ingested_at                                 AS bronze_ingested_at,
            c.ingested_by
        FROM c
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - keep only one row per ticket_id
       If a ticket appears more than once (e.g. the file loaded twice),
       keep the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY ticket_id              -- restart numbering for each ticket
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        -- Skip rows with no ticket_id: they can't be identified or keyed
        WHERE ticket_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Ticket times use style 120 (YYYY-MM-DD hh:mm:ss); the load timestamp
       style 121. The column list and the SELECT below must stay in the
       same order, because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.helpdesk_tickets (
        ticket_id, requester_email, order_ref, order_id, brand_domain, category,
        priority, status, created_at, solved_at, first_reply_minutes, resolution_minutes,
        csat, assignee, channel, tags,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        ticket_id,                                                      -- never NULL (filtered above)
        COALESCE(requester_email, 'N/A'),
        COALESCE(order_ref, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), order_id), 'N/A'),
        COALESCE(brand_domain, 'N/A'),
        COALESCE(category, 'N/A'),
        COALESCE(priority, 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), created_at, 120), 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), solved_at, 120), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), first_reply_minutes), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), resolution_minutes), 'N/A'),
        COALESCE(csat, 'N/A'),
        COALESCE(assignee, 'N/A'),
        COALESCE(channel, 'N/A'),
        COALESCE(tags, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per ticket

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Tickets with no usable order number
    SELECT @NoOrderId = COUNT(*) FROM silver.helpdesk_tickets WHERE order_id = 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver
           DuplicatesDropped = @Bronze - @Loaded,  -- repeated tickets removed (plus any rows without a ticket_id)
           OrderIdMissing    = @NoOrderId;         -- tickets that can't be linked to a purchase
END

-- ===== usp_load_merchant_accounts

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_merchant_accounts
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.merchant_accounts', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.merchant_accounts (
            mid                 VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_merchant_accounts PRIMARY KEY,
                                                          -- Merchant ID: the acquirer's ID for the merchant's
                                                          -- processing account
            merchant_id         VARCHAR(20)    NOT NULL,  -- merchant that owns the account, e.g. MRC-00001
            acquirer_name       VARCHAR(50)    NOT NULL,  -- Northgate Acquiring / Pacific Merchant Bank / EuroSettle Payments
            currency_group      VARCHAR(50)    NOT NULL,  -- currencies processed, e.g. USD/CAD/AUD, EUR/GBP
                                                          -- (split into separate currencies in gold)
            mcc                 VARCHAR(4)     NOT NULL,  -- Merchant Category Code, 4 digits with leading zeros
            effective_from      VARCHAR(10)    NOT NULL,  -- date the account took effect, YYYY-MM-DD
            status              VARCHAR(20)    NOT NULL,  -- Active / Closed / Terminated
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_merchant_accounts_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,     -- number of rows in bronze (input)
            @Loaded INT;     -- number of rows written to silver (output)

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[merchant_accounts];

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.merchant_accounts;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       ----------------------------------------------------------------- */
    WITH s AS (
        SELECT
            NULLIF(TRIM(b.mid), '')                       AS mid,   -- Merchant ID

            NULLIF(UPPER(TRIM(b.merchant_id)), '')        AS merchant_id,

            -- Acquirer: one name per acquirer (same mapping as transactions and clearing)
            CASE UPPER(TRIM(b.acquirer_name))
                WHEN 'NORTHGATE ACQUIRING'   THEN 'Northgate Acquiring'
                WHEN 'NORTHGATE'             THEN 'Northgate Acquiring'
                WHEN 'NG ACQ'                THEN 'Northgate Acquiring'
                WHEN 'PACIFIC MERCHANT BANK' THEN 'Pacific Merchant Bank'
                WHEN 'PACIFIC MERCH BANK'    THEN 'Pacific Merchant Bank'
                WHEN 'PACMB'                 THEN 'Pacific Merchant Bank'
                WHEN 'EUROSETTLE PAYMENTS'   THEN 'EuroSettle Payments'
                WHEN 'EUROSETTLE'            THEN 'EuroSettle Payments'
                ELSE NULLIF(TRIM(b.acquirer_name), '')
            END                                           AS acquirer_name,

            -- Currency group: uppercase, no spaces ('usd / cad/aud' -> 'USD/CAD/AUD')
            NULLIF(REPLACE(UPPER(TRIM(b.currency_group)), ' ', ''), '') AS currency_group,

            -- MCC: 1-4 digits, padded to 4 with leading zeros ('742' -> '0742')
            CASE WHEN TRIM(b.mcc) NOT LIKE '%[^0-9]%' AND LEN(TRIM(b.mcc)) BETWEEN 1 AND 4
                 THEN RIGHT('0000' + TRIM(b.mcc), 4) END  AS mcc,

            -- Effective date: each format converted with its own style code
            CASE
                WHEN e.ef LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      -- 2023-04-24
                    THEN TRY_CONVERT(DATE, LEFT(e.ef, 10), 23)
                WHEN e.ef LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'       -- 04/24/2023
                    THEN TRY_CONVERT(DATE, e.ef, 101)
                WHEN e.ef LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         -- 20230424
                    THEN TRY_CONVERT(DATE, e.ef, 112)
            END                                           AS effective_from,

            -- Capitalize: 'ACTIVE' -> 'Active', 'TERMINATED' -> 'Terminated'
            NULLIF(UPPER(LEFT(TRIM(b.status), 1)) + LOWER(SUBSTRING(TRIM(b.status), 2, 50)), '') AS status,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                 AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[merchant_accounts] b
        CROSS APPLY (SELECT ef = NULLIF(TRIM(b.effective_from), '')) e
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - keep only one row per MID
       If a MID appears more than once, keep the row with the latest
       effective_from, then the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY mid                    -- restart numbering for each MID
                   ORDER BY effective_from DESC,       -- latest setup first
                            bronze_ingested_at DESC    -- then newest bronze load
               ) AS rn
        FROM s
        -- Skip rows with no MID: they can't be identified or keyed
        WHERE mid IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.merchant_accounts (
        mid, merchant_id, acquirer_name, currency_group, mcc, effective_from, status,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        mid,                                                            -- never NULL (filtered above)
        COALESCE(merchant_id, 'N/A'),
        COALESCE(acquirer_name, 'N/A'),
        COALESCE(currency_group, 'N/A'),
        COALESCE(mcc, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), effective_from, 23), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per MID

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- rows written to silver (one per MID)
           DuplicatesDropped = @Bronze - @Loaded;  -- repeated MIDs removed (plus any rows without a MID)
END

-- ===== usp_load_merchant_xref

/* =====================================================================
   Procedure : silver.usp_load_merchant_xref
   Source    : bronze.merchant_xref   (raw text, loaded by bronze.usp_load_merchant_xref)
   Target    : silver.merchant_xref   (cleaned, one row per legacy merchant ID)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   The payment gateway migrated in March 2026. The old gateway identified
   merchants with numeric IDs (e.g. 1005); the new gateway uses IDs like
   MRC-00002. This table maps each legacy ID to its new merchant ID so
   pre-migration transactions can be linked to silver.merchant_accounts.

   Key terms
   ---------
   Legacy merchant ID : the old gateway's numeric merchant identifier.
   Merchant ID        : the new gateway's identifier (MRC-nnnnn).
   Effective from     : the date the legacy -> new mapping took effect.

   Transformations
   ---------------
     * legacy_merchant_id : trimmed and converted to a number (removes spaces
                            and leading zeros), then stored as text. Rows with
                            no valid numeric legacy ID are skipped.
     * merchant_id        : trimmed and uppercased (e.g. mrc-00002 -> MRC-00002).
     * effective_from     : parsed from YYYY-MM-DD, MM/DD/YYYY or YYYYMMDD
                            (each with its own style code) and stored as YYYY-MM-DD.
     * effective_to       : dropped - one row per legacy ID, so it adds nothing.
     * notes              : trimmed, kept as written.
     * Test data          : rows whose notes = 'test' (e.g. legacy 9999 ->
                            MRC-99999) are excluded as test/placeholder mappings.
     * Duplicates         : one row per legacy_merchant_id - the latest
                            effective_from wins, then the newest bronze load.
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Legacy IDs 1002, 1229 and 1310 appear in pre-migration transactions
       but have no mapping here (9,313 transactions in total).

   Usage
   -----
     EXEC silver.usp_load_merchant_xref;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE [silver].[usp_load_merchant_xref]
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    -- Keeps output clean and avoids confusing client tools such as PowerShell.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    -- Without this, some errors would leave silver half-loaded.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists.
       OBJECT_ID returns NULL when the table is missing - in that case
       create it here, so the TRUNCATE below can never fail with
       "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.merchant_xref', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.merchant_xref (
            legacy_merchant_id  VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_merchant_xref PRIMARY KEY,
                                                          -- old gateway's numeric merchant ID, e.g. 1005
            merchant_id         VARCHAR(20)    NOT NULL,  -- new gateway's merchant ID, e.g. MRC-00002
            effective_from      VARCHAR(10)    NOT NULL,  -- date the mapping took effect, YYYY-MM-DD
            notes               NVARCHAR(500)  NOT NULL,  -- free-text comments about the mapping
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_merchant_xref_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze  INT,     -- number of rows in bronze (input)
            @Test    INT,     -- test/placeholder rows excluded (notes = 'test')
            @Loaded  INT,     -- number of rows written to silver (output)
            @NewIds  INT;     -- distinct new merchant IDs the legacy IDs map to

    -- Count the bronze rows before loading, for the summary
    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[merchant_xref];

    -- Count the test rows that will be excluded, for the summary
    SELECT @Test = COUNT(*)
    FROM [SegPay].[bronze].[merchant_xref]
    WHERE LOWER(TRIM(notes)) = 'test';

    -- Start a transaction: the TRUNCATE and INSERT below succeed or fail together.
    -- If the insert fails, the TRUNCATE is undone and the previous silver data stays.
    BEGIN TRAN;

    -- Remove all existing rows from silver (faster than DELETE, keeps the table structure)
    TRUNCATE TABLE silver.merchant_xref;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, with proper data types.
       Missing values are NULL here; they become 'N/A' in the final insert.
       Test/placeholder mappings are filtered out here.
       ----------------------------------------------------------------- */
    WITH s AS (
        SELECT
            -- Legacy ID as a number (removes spaces and leading zeros)
            TRY_CAST(TRIM(b.legacy_merchant_id) AS INT)   AS legacy_merchant_id,

            NULLIF(UPPER(TRIM(b.merchant_id)), '')        AS merchant_id,

            -- Effective date: each format converted with its own style code
            CASE
                WHEN e.ef LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      -- 2026-03-01
                    THEN TRY_CONVERT(DATE, LEFT(e.ef, 10), 23)
                WHEN e.ef LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'       -- 03/01/2026
                    THEN TRY_CONVERT(DATE, e.ef, 101)
                WHEN e.ef LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         -- 20260301
                    THEN TRY_CONVERT(DATE, e.ef, 112)
            END                                           AS effective_from,

            -- Notes: trimmed, kept as written
            NULLIF(TRIM(b.notes), '')                     AS notes,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                 AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[merchant_xref] b
        CROSS APPLY (SELECT ef = NULLIF(TRIM(b.effective_from), '')) e
        -- Exclude test/placeholder mappings (e.g. legacy 9999 -> MRC-99999).
        -- ISNULL keeps rows with empty notes (NULL <> 'test' would drop them).
        WHERE ISNULL(LOWER(TRIM(b.notes)), '') <> 'test'
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - keep only one row per legacy_merchant_id
       If a legacy ID appears more than once, keep the row with the latest
       effective_from, then the copy from the latest bronze load.
       This also prevents a primary-key violation on the silver table.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY legacy_merchant_id     -- restart numbering for each legacy ID
                   ORDER BY effective_from DESC,       -- latest mapping first
                            bronze_ingested_at DESC    -- then newest bronze load
               ) AS rn
        FROM s
        -- Skip rows with no valid legacy ID: they can't be identified or keyed
        WHERE legacy_merchant_id IS NOT NULL
    )

    /* -----------------------------------------------------------------
       Write the cleaned, de-duplicated rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Dates use style 23 (YYYY-MM-DD); the load timestamp style 121.
       The column list and the SELECT below must stay in the same order,
       because INSERT fills columns by position.
       silver_loaded_at is not listed: it fills itself with the current
       time through its DEFAULT on the table.
       ----------------------------------------------------------------- */
    INSERT silver.merchant_xref (
        legacy_merchant_id, merchant_id, effective_from, notes,
        source_system, source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(20), legacy_merchant_id),                      -- never NULL (filtered above)
        COALESCE(merchant_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), effective_from, 23), 'N/A'),
        COALESCE(notes, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;          -- only one row per legacy merchant ID

    -- @@ROWCOUNT = rows affected by the previous statement (the INSERT).
    -- Must be read immediately, before any other statement resets it.
    SET @Loaded = @@ROWCOUNT;

    -- Everything succeeded: make the TRUNCATE + INSERT permanent
    COMMIT;

    -- Distinct new merchant IDs covered by the mapping
    SELECT @NewIds = COUNT(DISTINCT merchant_id) FROM silver.merchant_xref WHERE merchant_id <> 'N/A';

    -- Return a one-row summary of the load
    SELECT BronzeRows        = @Bronze,                    -- rows read from bronze
           TestRowsExcluded  = @Test,                      -- test/placeholder mappings removed
           SilverRows        = @Loaded,                    -- legacy IDs mapped (one row each)
           DuplicatesDropped = @Bronze - @Test - @Loaded,  -- repeated legacy IDs removed (plus rows with no valid legacy ID)
           NewMerchantIds    = @NewIds;                    -- distinct new merchant IDs they map to
END

-- ===== usp_load_merchants_crm_export

/* =====================================================================
   Procedure : silver.usp_load_merchants_crm_export
   Source    : bronze.merchants_crm_export   (raw text, loaded by bronze.usp_load_merchants_crm_export)
   Target    : silver.merchants_crm_export   (cleaned, one row per merchant)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   The CRM export holds each merchant's business details: legal and trading
   names, industry, country, onboarding date, account status, risk tier and
   the pricing the merchant was signed at (reserve, processing fee,
   per-transaction fee, chargeback fee).

   Key terms
   ---------
   Merchant ID      : the new gateway's merchant identifier (MRC-nnnnn); joins to
                      silver.merchant_accounts and silver.merchant_xref.
   DBA name         : "Doing Business As" - the trading name customers see.
   Vertical         : the merchant's industry (Dating, SaaS, Streaming, ...).
   Risk tier        : SegPay's internal risk rating of the merchant,
                      Tier 1 (lowest risk) to Tier 5 (highest).
   Reserve          : share of each sale held back by SegPay to cover future
                      chargebacks and refunds.
   Processing fee   : SegPay's percentage fee on each sale.
   Per-txn fee      : flat fee charged on every transaction.
   Chargeback fee   : flat fee charged to the merchant for each chargeback.
   MCC              : Merchant Category Code - 4-digit card-network industry code.

   Transformations
   ---------------
     * merchant_id        : trimmed and uppercased. Rows with no merchant ID are skipped.
     * legal_name,
       dba_name,
       account_manager    : trimmed, kept as written.
     * vertical           : spelling/case variants unified:
                              Software/SaaS, SaaS / Software, SaaS -> SaaS
                              E-Learning, E Learning              -> E-Learning
                              FITNESS                             -> Fitness
                            Other values are trimmed and kept as written.
     * country            : mapped to 2-letter ISO codes
                            (United States -> US, Cyprus / CYP -> CY, ...).
                            Values that can't be mapped -> 'N/A'.
     * onboard_date       : parsed from YYYY-MM-DD, MM/DD/YYYY, YYYYMMDD,
                            DD-Mon-YY, DD-Mon-YYYY and "Mon DD, YYYY"
                            (each with its own style code), stored as YYYY-MM-DD.
                            Slash dates are read as US month/day.
     * status             : capitalized and abbreviations expanded:
                              Act, A, ACTIVE                -> Active
                              Term                          -> Terminated
                            (A and Term mappings confirmed against
                            silver.merchant_accounts status.)
                            'Closed - terminated' and 'Closed by merchant' are
                            kept as their own values - they record how the
                            account was closed, which the gateway's plain
                            'Terminated' / 'Closed' does not.
     * risk_tier          : unified to 'Tier 1'-'Tier 5':
                              1 / T1 / Tier 1 / Low                  -> Tier 1
                              2 / T2 / Tier 2 / Low-Med              -> Tier 2
                              3 / T3 / Tier 3 / MED / Medium         -> Tier 3
                              4 / T4 / Tier 4 / High                 -> Tier 4
                              5 / T5 / Tier 5 / Very High / Critical -> Tier 5
                            ASSUMPTION: labels follow the 5-step scale Low -> Very High;
                            Critical is treated as the top tier. Unrecognized values -> 'N/A'.
     * reserve_pct,
       processing_fee_pct : stored as a fraction with 4 decimals (0.1500 = 15%).
                            '15%' -> 0.1500; numbers >= 1 are read as percents
                            (15 -> 0.1500, 4.77 -> 0.0477); numbers < 1 are
                            already fractions (0.05 -> 0.0500).
     * per_txn_fee,
       chargeback_fee     : '$' and ',' removed, 2 decimals (0.3000 -> 0.30, 15 -> 15.00).
     * mcc                : padded to 4 digits with leading zeros (742 -> 0742).
     * contact_email      : trimmed and lowercased.
     * last_modified      : parsed from YYYY-MM-DD hh:mm:ss or MM/DD/YYYY hh:mm,
                            stored as YYYY-MM-DD hh:mm:ss.
     * modified_by        : trimmed and lowercased (SYSTEM -> system).
     * Duplicates         : one row per merchant_id - the latest last_modified
                            wins, then the newest bronze load.
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   PII
   ---
   contact_email is personal data when it names a person (most here are
   billing@ role addresses). account_manager names a SegPay employee.

   Usage
   -----
     EXEC silver.usp_load_merchants_crm_export;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_merchants_crm_export
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.merchants_crm_export', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.merchants_crm_export (
            merchant_id         VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_merchants_crm_export PRIMARY KEY,
                                                          -- new gateway merchant ID, e.g. MRC-00078
            legal_name          NVARCHAR(200)  NOT NULL,  -- registered company name
            dba_name            NVARCHAR(200)  NOT NULL,  -- "Doing Business As" trading name
            vertical            VARCHAR(50)    NOT NULL,  -- industry, e.g. Dating, SaaS
            country             VARCHAR(3)     NOT NULL,  -- 2-letter ISO code, or 'N/A'
            onboard_date        VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            status              VARCHAR(30)    NOT NULL,  -- Active, Pending Review, Suspended, Closed, Closed by merchant, Closed - terminated, Terminated
            risk_tier           VARCHAR(20)    NOT NULL,  -- Tier 1 (lowest risk) to Tier 5 (highest)
            reserve_pct         VARCHAR(10)    NOT NULL,  -- fraction, 0.1500 = 15% of sales held back
            processing_fee_pct  VARCHAR(10)    NOT NULL,  -- fraction, 0.0922 = 9.22% fee per sale
            per_txn_fee         VARCHAR(12)    NOT NULL,  -- flat fee per transaction, 2 decimals
            chargeback_fee      VARCHAR(12)    NOT NULL,  -- flat fee per chargeback, 2 decimals
            mcc                 VARCHAR(4)     NOT NULL,  -- Merchant Category Code, 4 digits
            account_manager     NVARCHAR(100)  NOT NULL,  -- SegPay account manager
            contact_email       NVARCHAR(254)  NOT NULL,  -- lowercase; PII when it names a person
            last_modified       VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss
            modified_by         NVARCHAR(100)  NOT NULL,  -- user or service that last changed the record
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_merchants_crm_export_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze       INT,   -- rows in bronze (input)
            @Loaded       INT,   -- rows written to silver (output)
            @DateNA       INT,   -- merchants with no usable onboard_date
            @CountryNA    INT,   -- merchants whose country couldn't be mapped
            @TierNA       INT,   -- merchants with a missing or unrecognized risk tier
            @EmailMissing INT;   -- merchants with no contact email

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[merchants_crm_export];

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.merchants_crm_export;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, cleaned and typed.
       Missing values are NULL here; they become 'N/A' in the final insert.

       CROSS APPLY x : trimmed raw values and lookup keys, computed once.
       CROSS APPLY n : numbers parsed from the cleaned strings.
       ----------------------------------------------------------------- */
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
                ELSE x.vertical                                    -- unknown: keep as written
            END                                                    AS vertical,

            -- Country: names and 3-letter codes -> 2-letter ISO codes
            CASE
                WHEN x.country_key IN ('US','USA','UNITED STATES','UNITED STATES OF AMERICA') THEN 'US'
                WHEN x.country_key IN ('GB','GBR','UK','UNITED KINGDOM','GREAT BRITAIN')      THEN 'GB'
                WHEN x.country_key IN ('CY','CYP','CYPRUS')                                   THEN 'CY'
                WHEN x.country_key IN ('DE','DEU','GERMANY')                                  THEN 'DE'
                WHEN x.country_key IN ('NL','NLD','NETHERLANDS','THE NETHERLANDS')            THEN 'NL'
                WHEN x.country_key IN ('HK','HKG','HONG KONG')                                THEN 'HK'
                WHEN x.country_key IN ('CZ','CZE','CZECHIA','CZECH REPUBLIC')                 THEN 'CZ'
                WHEN x.country_key IN ('CA','CAN','CANADA')                                   THEN 'CA'
                WHEN x.country_key IN ('AU','AUS','AUSTRALIA')                                THEN 'AU'
                WHEN x.country_key IN ('FR','FRA','FRANCE')                                   THEN 'FR'
                WHEN x.country_key IN ('IE','IRL','IRELAND')                                  THEN 'IE'
                WHEN x.country_key IN ('ES','ESP','SPAIN')                                    THEN 'ES'
                WHEN x.country_key IN ('MT','MLT','MALTA')                                    THEN 'MT'
                WHEN x.country_key LIKE '[A-Z][A-Z]'                                          THEN x.country_key
            END                                                    AS country,

            -- Onboard date: each format converted with its own style code
            CASE
                WHEN x.od LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'                -- 2024-11-06
                    THEN TRY_CONVERT(DATE, LEFT(x.od, 10), 23)
                WHEN x.od LIKE '%/%/[12][0-9][0-9][0-9]'                                  -- 01/15/2022
                    THEN TRY_CONVERT(DATE, x.od, 101)
                WHEN x.od LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'                   -- 20210704
                    THEN TRY_CONVERT(DATE, x.od, 112)
                WHEN x.od LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'                    -- 20-Jan-18
                    THEN TRY_CONVERT(DATE, REPLACE(x.od, '-', ' '), 6)
                WHEN x.od LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]'           -- 20-Jan-2018
                    THEN TRY_CONVERT(DATE, REPLACE(x.od, '-', ' '), 106)
                WHEN x.od LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]'          -- Sep 09, 2023
                    THEN TRY_CONVERT(DATE, x.od, 107)
            END                                                    AS onboard_date,

            -- Status: capitalized, abbreviations expanded
            CASE x.status_key
                WHEN 'act'            THEN 'Active'
                WHEN 'active'         THEN 'Active'
                WHEN 'pending review' THEN 'Pending Review'
                WHEN 'pending_review' THEN 'Pending Review'
                WHEN 'pending'        THEN 'Pending Review'
                WHEN 'closed'         THEN 'Closed'
                WHEN 'terminated'     THEN 'Terminated'
                WHEN 'suspended'      THEN 'Suspended'
                -- Abbreviations / variants, confirmed against silver.merchant_accounts status:
                WHEN 'a'                   THEN 'Active'               -- gateway shows all as Active
                WHEN 'term'                THEN 'Terminated'           -- gateway shows all as Terminated
                -- Kept as their own values: they record how the account was closed,
                -- which the gateway's plain Closed / Terminated does not
                WHEN 'closed - terminated' THEN 'Closed - terminated'  -- gateway: Terminated
                WHEN 'closed by merchant'  THEN 'Closed by merchant'   -- gateway: Closed
                ELSE UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50)
            END                                                    AS status,

            -- Risk tier: numeric forms and labels unified to 'Tier 1'-'Tier 5'
            -- ASSUMPTION: labels follow the 5-step scale Low -> Very High;
            --             Critical is treated as the top tier (Tier 5).
            -- risk_key has spaces removed, so 'Very High' arrives as 'veryhigh'.
            CASE
                WHEN x.risk_key LIKE 'tier[1-5]'                   THEN 'Tier ' + RIGHT(x.risk_key, 1)   -- Tier 3
                WHEN x.risk_key LIKE 't[1-5]'                      THEN 'Tier ' + RIGHT(x.risk_key, 1)   -- T3
                WHEN x.risk_key LIKE '[1-5]'                       THEN 'Tier ' + x.risk_key             -- 3
                WHEN x.risk_key = 'low'                            THEN 'Tier 1'
                WHEN x.risk_key IN ('low-med','lowmed','low/med',
                                    'low-medium','lowmedium')      THEN 'Tier 2'
                WHEN x.risk_key IN ('med','medium')                THEN 'Tier 3'
                WHEN x.risk_key IN ('hi','high')                   THEN 'Tier 4'
                WHEN x.risk_key IN ('veryhigh','very-high',
                                    'crit','critical')             THEN 'Tier 5'
            END                                                    AS risk_tier,   -- anything else -> 'N/A'

            -- Percentages -> fraction: '%' or a number >= 1 means "percent"
            CASE WHEN x.reserve_has_pct = 1 OR n.reserve >= 1
                 THEN n.reserve / 100 ELSE n.reserve END           AS reserve_pct,
            CASE WHEN x.fee_has_pct = 1 OR n.fee >= 1
                 THEN n.fee / 100 ELSE n.fee END                   AS processing_fee_pct,

            n.per_txn_fee,
            n.chargeback_fee,

            -- MCC: 4 digits with leading zeros
            CASE WHEN n.mcc BETWEEN 0 AND 9999
                 THEN RIGHT('0000' + CONVERT(VARCHAR(4), n.mcc), 4) END AS mcc,

            NULLIF(TRIM(b.account_manager), '')                    AS account_manager,
            NULLIF(LOWER(TRIM(b.contact_email)), '')               AS contact_email,

            -- Last modified: ISO or US month/day, with time
            CASE
                WHEN x.lm LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      -- 2026-06-15 15:00:52
                    THEN TRY_CONVERT(DATETIME2(0), x.lm, 120)
                WHEN x.lm LIKE '%/%/[12][0-9][0-9][0-9]%'                       -- 01/10/2026 02:24
                    THEN TRY_CONVERT(DATETIME2(0), x.lm, 101)
            END                                                    AS last_modified,

            NULLIF(LOWER(TRIM(b.modified_by)), '')                 AS modified_by,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                          AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[merchants_crm_export] b
        CROSS APPLY (
            SELECT
                merchant_id     = NULLIF(UPPER(TRIM(b.merchant_id)), ''),
                vertical        = NULLIF(TRIM(b.vertical), ''),
                vertical_key    = LOWER(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.vertical),
                                      ' ', ''), '-', ''), '/', ''), '&', '')),
                country_key     = UPPER(REPLACE(TRIM(b.country), '.', '')),
                od              = NULLIF(TRIM(b.onboard_date), ''),
                status_key      = NULLIF(LOWER(TRIM(b.status)), ''),
                risk_key        = LOWER(REPLACE(TRIM(b.risk_tier), ' ', '')),
                reserve_txt     = NULLIF(REPLACE(REPLACE(TRIM(b.reserve_pct), '%', ''), ' ', ''), ''),
                reserve_has_pct = CASE WHEN b.reserve_pct LIKE '%[%]%' THEN 1 ELSE 0 END,
                fee_txt         = NULLIF(REPLACE(REPLACE(TRIM(b.processing_fee_pct), '%', ''), ' ', ''), ''),
                fee_has_pct     = CASE WHEN b.processing_fee_pct LIKE '%[%]%' THEN 1 ELSE 0 END,
                lm              = NULLIF(TRIM(b.last_modified), '')
        ) x
        CROSS APPLY (
            SELECT
                reserve        = TRY_CAST(x.reserve_txt AS DECIMAL(12,6)),
                fee            = TRY_CAST(x.fee_txt     AS DECIMAL(12,6)),
                per_txn_fee    = TRY_CAST(REPLACE(REPLACE(TRIM(b.per_txn_fee),    '$', ''), ',', '') AS DECIMAL(12,4)),
                chargeback_fee = TRY_CAST(REPLACE(REPLACE(TRIM(b.chargeback_fee), '$', ''), ',', '') AS DECIMAL(12,4)),
                mcc            = TRY_CAST(TRIM(b.mcc) AS INT)
        ) n
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - one row per merchant_id.
       Latest last_modified wins, then the newest bronze load.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY merchant_id
                   ORDER BY last_modified DESC,        -- most recent CRM edit first
                            bronze_ingested_at DESC    -- then newest bronze load
               ) AS rn
        FROM s
        WHERE merchant_id IS NOT NULL                  -- can't key a row with no merchant ID
    )

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    INSERT silver.merchants_crm_export (
        merchant_id, legal_name, dba_name, vertical, country, onboard_date,
        status, risk_tier, reserve_pct, processing_fee_pct, per_txn_fee,
        chargeback_fee, mcc, account_manager, contact_email, last_modified,
        modified_by, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        merchant_id,
        COALESCE(legal_name, 'N/A'),
        COALESCE(dba_name, 'N/A'),
        COALESCE(vertical, 'N/A'),
        COALESCE(country, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), onboard_date, 23), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(risk_tier, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), CAST(reserve_pct        AS DECIMAL(6,4))), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), CAST(processing_fee_pct AS DECIMAL(6,4))), 'N/A'),
        COALESCE(CONVERT(VARCHAR(12), CAST(per_txn_fee        AS DECIMAL(10,2))), 'N/A'),
        COALESCE(CONVERT(VARCHAR(12), CAST(chargeback_fee     AS DECIMAL(10,2))), 'N/A'),
        COALESCE(mcc, 'N/A'),
        COALESCE(account_manager, 'N/A'),
        COALESCE(contact_email, 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), last_modified, 120), 'N/A'),
        COALESCE(modified_by, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary
    SELECT @DateNA       = SUM(CASE WHEN onboard_date  = 'N/A' THEN 1 ELSE 0 END),
           @CountryNA    = SUM(CASE WHEN country       = 'N/A' THEN 1 ELSE 0 END),
           @TierNA       = SUM(CASE WHEN risk_tier     = 'N/A' THEN 1 ELSE 0 END),
           @EmailMissing = SUM(CASE WHEN contact_email = 'N/A' THEN 1 ELSE 0 END)
    FROM silver.merchants_crm_export;

    -- One-row summary of the load
    SELECT BronzeRows              = @Bronze,            -- rows read from bronze
           SilverRows              = @Loaded,            -- merchants loaded (one row each)
           DuplicatesDropped       = @Bronze - @Loaded,  -- older copies removed (plus rows with no merchant ID)
           OnboardDateNotAvailable = @DateNA,            -- missing or unreadable onboard date
           CountryNotAvailable     = @CountryNA,         -- missing or unmappable country
           RiskTierNotAvailable    = @TierNA,            -- missing or unrecognized risk tier
           ContactEmailMissing     = @EmailMissing;      -- no contact email
END


-- ===== usp_load_packages
/* =====================================================================
   Procedure : silver.usp_load_packages
   Source    : bronze.packages   (raw text, loaded by bronze.usp_load_packages)
   Target    : silver.packages   (cleaned, one row per package)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A package is a price point a merchant's site sells: a one-time purchase,
   a recurring membership, or a trial that turns into a recurring membership.
   Each package belongs to one site (silver.sites, via site_id).

   Key terms
   ---------
   Billing model  : how the customer is charged:
                      One-Time  - charged once, no rebill
                      Recurring - charged the same price every rebill period
                      Trial     - a short, cheap (or free) trial, then rebills
   Initial price  : the first charge (for a trial, the trial price - often 0.00).
   Rebill price   : the amount charged on each renewal.
   Rebill period  : days between renewals (30 = monthly, 90 = quarterly, 365 = annual).
   Trial days     : length of the trial before the first rebill.

   Transformations
   ---------------
     * package_id,
       site_id           : trimmed and converted to a number (removes spaces and
                           leading zeros), stored as text. Rows with no valid
                           package_id are skipped.
     * package_name      : trimmed, kept as written.
     * billing_model     : 11 spellings unified to 3 values:
                             RECURRING, SUBSCRIPTION                       -> Recurring
                             TRIAL, Trial>Recurring, TRIAL+REBILL,
                             TRIAL_RECURRING                               -> Trial
                             ONE_TIME, ONETIME, One Time, one-time, OT     -> One-Time
                           Unrecognized values -> 'N/A'.
     * initial_price,
       rebill_price      : '$' removed; a decimal comma is changed to a point
                           ('9,00' -> 9.00, '4,43' -> 4.43); 2 decimals.
                           (All prices are under 1,000, so a comma is never a
                           thousands separator here.)
     * currency          : trimmed and uppercased 3-letter code; missing -> 'N/A'.
     * trial_days        : whole number; 'N/A' for packages with no trial.
     * rebill_period     : converted to a number of days:
                             30, 30d, 30 days, monthly                      -> 30
                             90, 90 days, 3 months, quarterly               -> 90
                             365, 365 days, 1 year, annual, yearly          -> 365
                           'N/A' for one-time packages (no rebill).
     * status            : title case ('ACTIVE', 'active' -> 'Active').
     * created_date,
       updated_date      : parsed from YYYY-MM-DD, MM/DD/YYYY, DD/MM/YYYY,
                           YYYYMMDD, DD-Mon-YY and "Mon DD, YYYY" (each with its
                           own style code), stored as YYYY-MM-DD.
                           Slash dates are read as US month/day first; when that
                           is impossible (e.g. 18/07/2023) they are read day-first.
                           A slash date that is valid both ways (05/12/2025) is
                           read as US month/day.
     * Test data         : packages sold on test sites (bronze.sites category
                           'Test' or the test merchant MRC-99999, e.g. site 4001
                           'QA Sandbox A') are excluded, matching silver.sites.
     * Duplicates        : one row per package_id - the latest updated_date
                           wins, then the newest bronze load.
     * Missing values    : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage           : source_system, source_file_name, batch_id,
                           ingested_at (as bronze_ingested_at) and ingested_by
                           carried over from bronze; silver_loaded_at added.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Some created_date / updated_date values are later than the load date
       (e.g. 17-Dec-26) - 47 packages. They are kept as given; the summary
       counts them.
     * 7 packages end up with updated_date before created_date (e.g. 90863:
       created 2018-05-23, updated 04/10/2018). Each involves a slash date
       that is valid both ways; read day-first, all 7 would be in order, so
       the source likely mixes US and day-first dates. Kept as US month/day.

   Usage
   -----
     EXEC silver.usp_load_packages;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_packages
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.packages', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.packages (
            package_id          VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_packages PRIMARY KEY,
                                                          -- package number, e.g. 90005
            site_id             VARCHAR(20)    NOT NULL,  -- site selling the package, e.g. 5003
            package_name        NVARCHAR(255)  NOT NULL,  -- e.g. 14-Day Trial + Monthly
            billing_model       VARCHAR(10)    NOT NULL,  -- One-Time / Recurring / Trial
            initial_price       VARCHAR(12)    NOT NULL,  -- first charge, 2 decimals
            currency            VARCHAR(3)     NOT NULL,  -- ISO 3-letter code, e.g. USD
            trial_days          VARCHAR(5)     NOT NULL,  -- trial length in days, 'N/A' if no trial
            rebill_price        VARCHAR(12)    NOT NULL,  -- renewal charge, 2 decimals, 'N/A' if one-time
            rebill_period_days  VARCHAR(5)     NOT NULL,  -- 30 / 90 / 365, 'N/A' if one-time
            status              VARCHAR(20)    NOT NULL,  -- Active / Retired
            created_date        VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            updated_date        VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_packages_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze      INT,   -- rows in bronze (input)
            @Test        INT,   -- packages on test sites, excluded
            @Loaded      INT,   -- rows written to silver (output)
            @ModelNA     INT,   -- packages with a missing or unrecognized billing model
            @PriceNA     INT,   -- packages with no usable initial price
            @CurrencyNA  INT,   -- packages with no currency
            @DateNA      INT,   -- packages with an unreadable created or updated date
            @FutureDates INT;   -- packages with a created or updated date after today

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[packages];

    -- Count the packages on test sites that will be excluded, for the summary
    SELECT @Test = COUNT(*)
    FROM [SegPay].[bronze].[packages] b
    WHERE EXISTS (SELECT 1 FROM [SegPay].[bronze].[sites] t
                  WHERE TRIM(t.site_id) = TRIM(b.site_id)
                    AND (UPPER(TRIM(t.category)) = 'TEST' OR UPPER(TRIM(t.merchant_id)) = 'MRC-99999'));

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.packages;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, cleaned and typed.
       Missing values are NULL here; they become 'N/A' in the final insert.

       CROSS APPLY x : trimmed raw values and lookup keys, computed once.
       ----------------------------------------------------------------- */
    WITH s AS (
        SELECT
            -- IDs as numbers (removes spaces and leading zeros)
            TRY_CAST(x.package_id AS INT)                          AS package_id,
            TRY_CAST(x.site_id    AS INT)                          AS site_id,

            NULLIF(TRIM(b.package_name), '')                       AS package_name,

            -- Billing model: compare on a key with spaces, '-', '_', '+' and '>' removed,
            -- so 'One Time', 'one-time', 'ONE_TIME' and 'ONETIME' all become 'onetime'
            CASE x.model_key
                WHEN 'recurring'          THEN 'Recurring'
                WHEN 'subscription'       THEN 'Recurring'
                WHEN 'trial'              THEN 'Trial'
                WHEN 'trialrecurring'     THEN 'Trial'      -- Trial>Recurring, TRIAL_RECURRING
                WHEN 'trialrebill'        THEN 'Trial'      -- TRIAL+REBILL
                WHEN 'onetime'            THEN 'One-Time'
                WHEN 'ot'                 THEN 'One-Time'
            END                                                    AS billing_model,   -- anything else -> 'N/A'

            -- Prices: '$' removed; a comma before the last 2 digits is a decimal comma
            TRY_CAST(CASE WHEN x.ip LIKE '%,[0-9][0-9]' THEN REPLACE(x.ip, ',', '.') ELSE x.ip END
                     AS DECIMAL(12,2))                             AS initial_price,
            TRY_CAST(CASE WHEN x.rp LIKE '%,[0-9][0-9]' THEN REPLACE(x.rp, ',', '.') ELSE x.rp END
                     AS DECIMAL(12,2))                             AS rebill_price,

            -- Currency: 3-letter code only, uppercased
            CASE WHEN x.currency LIKE '[A-Z][A-Z][A-Z]' THEN x.currency END AS currency,

            TRY_CAST(TRIM(b.trial_days) AS INT)                    AS trial_days,

            -- Rebill period -> number of days
            CASE
                WHEN x.period_key IN ('30', '30d', '30days', 'monthly', 'month', '1month')             THEN 30
                WHEN x.period_key IN ('90', '90d', '90days', 'quarterly', 'quarter', '3months')        THEN 90
                WHEN x.period_key IN ('365', '365d', '365days', 'annual', 'annually', 'yearly', '1year') THEN 365
            END                                                    AS rebill_period_days,

            -- Status: capitalized ('ACTIVE', 'active' -> 'Active')
            CASE WHEN x.status_key IS NOT NULL
                 THEN UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50)
            END                                                    AS status,

            -- Dates: each format converted with its own style code
            CASE
                WHEN x.cd LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'                -- 2023-08-31
                    THEN TRY_CONVERT(DATE, LEFT(x.cd, 10), 23)
                WHEN x.cd LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'                -- 06/14/2023 or 18/07/2023
                    THEN COALESCE(TRY_CONVERT(DATE, x.cd, 101),                           --   US month/day first
                                  TRY_CONVERT(DATE, x.cd, 103))                           --   else day/month
                WHEN x.cd LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'                   -- 20230708
                    THEN TRY_CONVERT(DATE, x.cd, 112)
                WHEN x.cd LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'                    -- 04-May-25
                    THEN TRY_CONVERT(DATE, REPLACE(x.cd, '-', ' '), 6)
                WHEN x.cd LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]'           -- 04-May-2025
                    THEN TRY_CONVERT(DATE, REPLACE(x.cd, '-', ' '), 106)
                WHEN x.cd LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]'          -- Apr 26, 2025
                    THEN TRY_CONVERT(DATE, x.cd, 107)
            END                                                    AS created_date,

            CASE
                WHEN x.ud LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'
                    THEN TRY_CONVERT(DATE, LEFT(x.ud, 10), 23)
                WHEN x.ud LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'
                    THEN COALESCE(TRY_CONVERT(DATE, x.ud, 101),
                                  TRY_CONVERT(DATE, x.ud, 103))
                WHEN x.ud LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'
                    THEN TRY_CONVERT(DATE, x.ud, 112)
                WHEN x.ud LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'
                    THEN TRY_CONVERT(DATE, REPLACE(x.ud, '-', ' '), 6)
                WHEN x.ud LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]'
                    THEN TRY_CONVERT(DATE, REPLACE(x.ud, '-', ' '), 106)
                WHEN x.ud LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]'
                    THEN TRY_CONVERT(DATE, x.ud, 107)
            END                                                    AS updated_date,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                          AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[packages] b
        CROSS APPLY (
            SELECT
                package_id = NULLIF(TRIM(b.package_id), ''),
                site_id    = NULLIF(TRIM(b.site_id), ''),
                model_key  = LOWER(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.billing_model),
                                 ' ', ''), '-', ''), '_', ''), '+', ''), '>', '')),
                ip         = NULLIF(REPLACE(REPLACE(TRIM(b.initial_price), '$', ''), ' ', ''), ''),
                rp         = NULLIF(REPLACE(REPLACE(TRIM(b.rebill_price),  '$', ''), ' ', ''), ''),
                currency   = UPPER(TRIM(b.currency)),
                period_key = LOWER(REPLACE(TRIM(b.rebill_period), ' ', '')),
                status_key = NULLIF(LOWER(TRIM(b.status)), ''),
                cd         = NULLIF(TRIM(b.created_date), ''),
                ud         = NULLIF(TRIM(b.updated_date), '')
        ) x
        -- Exclude packages sold on test sites (same test rule as silver.usp_load_sites)
        WHERE NOT EXISTS (SELECT 1 FROM [SegPay].[bronze].[sites] t
                          WHERE TRIM(t.site_id) = TRIM(b.site_id)
                            AND (UPPER(TRIM(t.category)) = 'TEST' OR UPPER(TRIM(t.merchant_id)) = 'MRC-99999'))
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - one row per package_id.
       Latest updated_date wins, then the newest bronze load.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY package_id
                   ORDER BY updated_date DESC,         -- most recent package change first
                            bronze_ingested_at DESC    -- then newest bronze load
               ) AS rn
        FROM s
        WHERE package_id IS NOT NULL                   -- can't key a row with no package ID
    )

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    INSERT silver.packages (
        package_id, site_id, package_name, billing_model, initial_price, currency,
        trial_days, rebill_price, rebill_period_days, status, created_date,
        updated_date, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(20), package_id),                              -- never NULL (filtered above)
        COALESCE(CONVERT(VARCHAR(20), site_id), 'N/A'),
        COALESCE(package_name, 'N/A'),
        COALESCE(billing_model, 'N/A'),
        COALESCE(CONVERT(VARCHAR(12), initial_price), 'N/A'),
        COALESCE(currency, 'N/A'),
        COALESCE(CONVERT(VARCHAR(5), trial_days), 'N/A'),
        COALESCE(CONVERT(VARCHAR(12), rebill_price), 'N/A'),
        COALESCE(CONVERT(VARCHAR(5), rebill_period_days), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), created_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), updated_date, 23), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary.
    -- Dates are stored as YYYY-MM-DD text, so a text comparison with today works.
    DECLARE @Today VARCHAR(10) = CONVERT(VARCHAR(10), CAST(SYSUTCDATETIME() AS DATE), 23);

    SELECT @ModelNA     = SUM(CASE WHEN billing_model = 'N/A' THEN 1 ELSE 0 END),
           @PriceNA     = SUM(CASE WHEN initial_price = 'N/A' THEN 1 ELSE 0 END),
           @CurrencyNA  = SUM(CASE WHEN currency      = 'N/A' THEN 1 ELSE 0 END),
           @DateNA      = SUM(CASE WHEN created_date  = 'N/A' OR updated_date = 'N/A' THEN 1 ELSE 0 END),
           @FutureDates = SUM(CASE WHEN (created_date <> 'N/A' AND created_date > @Today)
                                     OR (updated_date <> 'N/A' AND updated_date > @Today) THEN 1 ELSE 0 END)
    FROM silver.packages;

    -- One-row summary of the load
    SELECT BronzeRows               = @Bronze,                    -- rows read from bronze
           TestRowsExcluded         = @Test,                      -- packages on test sites removed
           SilverRows               = @Loaded,                    -- packages loaded (one row each)
           DuplicatesDropped        = @Bronze - @Test - @Loaded,  -- older copies removed (plus rows with no package ID)
           BillingModelNotAvailable = @ModelNA,           -- missing or unrecognized billing model
           InitialPriceNotAvailable = @PriceNA,           -- missing or unreadable initial price
           CurrencyNotAvailable     = @CurrencyNA,        -- no currency given
           DateNotAvailable         = @DateNA,            -- unreadable created or updated date
           FutureDated              = @FutureDates;       -- created or updated after today
END

-- ===== usp_load_purchases_snapshot
/* =====================================================================
   Procedure : silver.usp_load_purchases_snapshot
   Source    : bronze.purchases_snapshot   (raw text, loaded by bronze.usp_load_purchases_snapshot)
   Target    : silver.purchases_snapshot   (cleaned, one row per purchase)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A purchase is a customer's order or subscription for one package on one
   site. Each row is the purchase's state when the billing system exported
   the snapshot: status, cancellation details, next rebill date, number of
   rebills so far, and how the customer arrived (affiliate, traffic source,
   promo code). Every transaction in silver.transactions carries a
   purchase_id, so this table gives the subscription-level context for each
   sale, rebill, refund and chargeback.

   Key terms
   ---------
   Rebill            : an automatic renewal charge on a subscription.
   Next rebill date  : when the next renewal charge is due (Active / Past Due only).
   Trial             : the purchase started on a trial package (silver.packages
                       billing_model 'Trial').
   Cancel initiated  : who ended the purchase - Consumer, Merchant, Segpay
   by                  Support or System (e.g. after failed payments).

   Transformations
   ---------------
     * purchase_id, site_id,
       package_id         : trimmed and converted to a number, stored as text.
                            Rows with no valid purchase_id are skipped.
     * customer_id,
       merchant_id        : trimmed and uppercased. merchant_id is kept as sent -
                            it matches the purchase's transactions in every case.
     * purchase_status    : 26 spellings unified to 6 values:
                              Active, ACTIVE, Act                       -> Active
                              Cancelled, Canceled, X                    -> Cancelled
                              Completed, Complete, Closed               -> Completed
                              Expired, NSF Expired, Expired - Payment   -> Expired
                              Chargeback, Charged Back, CB              -> Chargeback
                              Past Due, PASTDUE, DELINQ                 -> Past Due
                            'X' rows all have a cancel date and reason; 'Closed'
                            rows are all finished one-time purchases, like
                            Completed. Unrecognized -> 'N/A'.
     * cancel_reason      : ~40 spellings unified to 12 reasons:
                              CUST_REQUEST, CUSTOMER_REQ, cust requested cancel -> Customer Request
                              PAYMENT_FAILURE, PAYMENT_FAIL, NSF                -> Payment Failure
                              TOO_EXPENSIVE, price                              -> Too Expensive
                              REFUND, Refund requested                          -> Refund
                              NOT_SATISFIED, unsatisfied                        -> Not Satisfied
                              SUPPORT_CANCEL, CS cancel                         -> Support Cancel
                              MERCHANT_CANCEL, MERCH_CXL, Merchant cancelled    -> Merchant Cancel
                              VOID, same-day void                               -> Void
                              DUPLICATE_ACCT, dup                               -> Duplicate Account
                              FRAUD                                             -> Fraud
                              FRAUD_SUSPECTED                                   -> Fraud Suspected
                              CHARGEBACK, CB                                    -> Chargeback
                            (Fraud and Fraud Suspected are kept apart: confirmed
                            vs suspected.) Unrecognized -> kept, capitalized.
     * cancel_initiated_by,
       traffic_source,
       promo_code         : trimmed, kept as written.
     * purchase_date,
       cancel_date,
       next_rebill_date   : parsed from YYYY-MM-DD, MM/DD/YYYY, DD/MM/YYYY,
                            YYYYMMDD, DD-Mon-YY and "Mon DD, YYYY", stored as
                            YYYY-MM-DD. 'N/A', 'NULL' and '-' -> 'N/A'.
                            Slash dates valid both ways (e.g. 05/12/2025) are
                            resolved against another date in the data instead
                            of guessed:
                              purchase_date    -> the reading within 1 day of the
                                                  purchase's first transaction
                              cancel_date,
                              next_rebill_date -> the reading equal to last_updated
                                                  (they match it 99.6%+ of the time)
                            If neither reading matches, US month/day is used.
     * rebill_count       : whole number; 'n/a' / 'NULL' text -> 'N/A'.
     * affiliate_id       : AFF-0000 format.
     * is_trial           : '1' / '0' (TRUE, Y, 1 / FALSE, N, 0). Blank values
                            are filled from the package's billing model
                            (Trial -> '1', otherwise '0'); the two agree in
                            every row where both are given.
     * last_updated       : YYYY-MM-DD.
     * Test data          : purchases by the test merchant MRC-99999 or on a test
                            site (same rule as silver.sites) are excluded.
     * Duplicates         : the snapshot can hold one purchase at two points in
                            its life (e.g. Active, then Cancelled). One row per
                            purchase_id is kept: the latest last_updated, then
                            the later lifecycle state (Cancelled / Expired /
                            Completed / Chargeback before Past Due before Active).
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   Dependencies
   ------------
   Load these silver tables first:
     silver.transactions   (first transaction date, to resolve purchase_date)
     silver.packages       (billing model, to fill is_trial)
     silver.sites          (test-site rule)

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * 1,951 purchases are on 12 sites that silver.sites assigns to merchants
       MRC-00201 - MRC-00205 (e.g. site 5522 -> MRC-00202), while the purchase
       and all its transactions name another merchant (e.g. MRC-00096). The
       purchase's merchant is kept; the sites file looks wrong (those 5
       merchants are also missing from silver.merchant_accounts).
     * 70 purchases have a cancel_date a few days before their purchase_date
       (e.g. 4106473: bought 2026-04-16, cancelled 2026-04-11). Most are ISO
       dates, so this is in the source, not a misread; kept as sent. Unlike
       every other cancel_date, these also differ from last_updated.

   Usage
   -----
     EXEC silver.usp_load_purchases_snapshot;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_purchases_snapshot
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.purchases_snapshot', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.purchases_snapshot (
            purchase_id         VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_purchases_snapshot PRIMARY KEY,
                                                          -- e.g. 4011260
            customer_id         VARCHAR(20)    NOT NULL,  -- e.g. C00004835
            merchant_id         VARCHAR(20)    NOT NULL,  -- MRC-nnnnn
            site_id             VARCHAR(20)    NOT NULL,
            package_id          VARCHAR(20)    NOT NULL,
            purchase_date       VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            purchase_status     VARCHAR(20)    NOT NULL,  -- Active / Past Due / Cancelled / Expired / Completed / Chargeback
            cancel_date         VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD; 'N/A' if not ended
            cancel_reason       VARCHAR(50)    NOT NULL,  -- e.g. Customer Request, Payment Failure
            cancel_initiated_by VARCHAR(50)    NOT NULL,  -- Consumer / Merchant / Segpay Support / System
            next_rebill_date    VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD; 'N/A' if no rebill due
            rebill_count        VARCHAR(10)    NOT NULL,  -- rebills so far
            affiliate_id        VARCHAR(20)    NOT NULL,  -- AFF-0000
            traffic_source      VARCHAR(50)    NOT NULL,  -- Affiliate / Direct / Organic / Paid Social
            promo_code          VARCHAR(50)    NOT NULL,
            is_trial            VARCHAR(3)     NOT NULL,  -- '1' = started as a trial, '0' = not
            last_updated        VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_purchases_snapshot_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze      INT,   -- rows in bronze (input)
            @Test        INT,   -- test purchases excluded
            @Loaded      INT,   -- rows written to silver (output)
            @Resolved    INT,   -- ambiguous slash dates resolved by the cross-check
            @StatusNA    INT,   -- rows with an unrecognized status
            @TrialFilled INT;   -- blank is_trial filled from the package

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[purchases_snapshot];

    -- Test sites (same rule as silver.usp_load_sites), as numbers for matching
    DECLARE @TestSites TABLE (site_id INT PRIMARY KEY);
    INSERT @TestSites (site_id)
    SELECT DISTINCT TRY_CAST(TRIM(site_id) AS INT)
    FROM [SegPay].[bronze].[sites]
    WHERE (UPPER(TRIM(category)) = 'TEST' OR UPPER(TRIM(merchant_id)) = 'MRC-99999')
      AND TRY_CAST(TRIM(site_id) AS INT) IS NOT NULL;

    -- First transaction date per purchase (UTC), used to resolve ambiguous purchase dates
    CREATE TABLE #first_txn (purchase_id VARCHAR(20) PRIMARY KEY, first_txn_date DATE NOT NULL);
    INSERT #first_txn (purchase_id, first_txn_date)
    SELECT purchase_id, MIN(CAST(txn_ts_utc AS DATE))
    FROM [SegPay].[silver].[transactions]
    WHERE txn_ts_utc <> 'N/A' AND purchase_id <> 'N/A'
    GROUP BY purchase_id;

    /* -----------------------------------------------------------------
       Step 1: clean every column into a temporary table (#s).
       Missing values are NULL here; they become 'N/A' in the final insert.
       Test purchases are filtered out here.

       CROSS APPLY x  : trimmed raw values and lookup keys, computed once.
       CROSS APPLY pd / cd / nd : each date parsed three ways -
                        'fixed' (formats with only one reading),
                        'us' (MM/DD/YYYY) and 'dm' (DD/MM/YYYY).
       ----------------------------------------------------------------- */
    SELECT
        x.purchase_id,
        NULLIF(UPPER(TRIM(b.customer_id)), '')                     AS customer_id,
        NULLIF(UPPER(TRIM(b.merchant_id)), '')                     AS merchant_id,
        x.site_id,
        x.package_id,

        -- Purchase date: an ambiguous slash date takes the reading within
        -- 1 day of the purchase's first transaction; otherwise US first
        COALESCE(pd.fixed,
            CASE WHEN pd.us IS NOT NULL AND pd.dm IS NOT NULL AND pd.us <> pd.dm
                      AND ABS(DATEDIFF(DAY, pd.dm, ft.first_txn_date)) <= 1
                      AND NOT ABS(DATEDIFF(DAY, pd.us, ft.first_txn_date)) <= 1
                 THEN pd.dm
                 ELSE COALESCE(pd.us, pd.dm)
            END)                                                   AS purchase_date,

        -- Status: 26 spellings -> 6 values
        CASE x.status_key
            WHEN 'ACTIVE'            THEN 'Active'
            WHEN 'ACT'               THEN 'Active'
            WHEN 'PAST DUE'          THEN 'Past Due'
            WHEN 'PASTDUE'           THEN 'Past Due'
            WHEN 'DELINQ'            THEN 'Past Due'
            WHEN 'CANCELLED'         THEN 'Cancelled'
            WHEN 'CANCELED'          THEN 'Cancelled'
            WHEN 'X'                 THEN 'Cancelled'
            WHEN 'COMPLETED'         THEN 'Completed'
            WHEN 'COMPLETE'          THEN 'Completed'
            WHEN 'CLOSED'            THEN 'Completed'
            WHEN 'EXPIRED'           THEN 'Expired'
            WHEN 'NSF EXPIRED'       THEN 'Expired'
            WHEN 'EXPIRED - PAYMENT' THEN 'Expired'
            WHEN 'CHARGEBACK'        THEN 'Chargeback'
            WHEN 'CHARGED BACK'      THEN 'Chargeback'
            WHEN 'CB'                THEN 'Chargeback'
        END                                                        AS purchase_status,

        -- Cancel date: an ambiguous slash date takes the reading equal to last_updated
        COALESCE(cd.fixed,
            CASE WHEN cd.us IS NOT NULL AND cd.dm IS NOT NULL AND cd.us <> cd.dm
                      AND cd.dm = x.last_updated AND cd.us <> x.last_updated
                 THEN cd.dm
                 ELSE COALESCE(cd.us, cd.dm)
            END)                                                   AS cancel_date,

        -- Cancel reason: compare on a key with spaces, '_' and '-' removed
        CASE x.reason_key
            WHEN 'CUSTREQUEST'         THEN 'Customer Request'
            WHEN 'CUSTOMERREQUEST'     THEN 'Customer Request'
            WHEN 'CUSTOMERREQ'         THEN 'Customer Request'
            WHEN 'CUSTREQUESTEDCANCEL' THEN 'Customer Request'
            WHEN 'PAYMENTFAILURE'      THEN 'Payment Failure'
            WHEN 'PAYMENTFAIL'         THEN 'Payment Failure'
            WHEN 'NSF'                 THEN 'Payment Failure'     -- insufficient funds
            WHEN 'TOOEXPENSIVE'        THEN 'Too Expensive'
            WHEN 'PRICE'               THEN 'Too Expensive'
            WHEN 'REFUND'              THEN 'Refund'
            WHEN 'REFUNDREQUESTED'     THEN 'Refund'
            WHEN 'NOTSATISFIED'        THEN 'Not Satisfied'
            WHEN 'UNSATISFIED'         THEN 'Not Satisfied'
            WHEN 'SUPPORTCANCEL'       THEN 'Support Cancel'
            WHEN 'CSCANCEL'            THEN 'Support Cancel'
            WHEN 'MERCHANTCANCEL'      THEN 'Merchant Cancel'
            WHEN 'MERCHCXL'            THEN 'Merchant Cancel'
            WHEN 'MERCHANTCANCELLED'   THEN 'Merchant Cancel'
            WHEN 'VOID'                THEN 'Void'
            WHEN 'SAMEDAYVOID'         THEN 'Void'
            WHEN 'DUPLICATEACCT'       THEN 'Duplicate Account'
            WHEN 'DUPLICATEACCOUNT'    THEN 'Duplicate Account'
            WHEN 'DUP'                 THEN 'Duplicate Account'
            WHEN 'FRAUD'               THEN 'Fraud'
            WHEN 'FRAUDSUSPECTED'      THEN 'Fraud Suspected'
            WHEN 'CHARGEBACK'          THEN 'Chargeback'
            WHEN 'CB'                  THEN 'Chargeback'
            -- Unknown reason: keep it, capitalized
            ELSE NULLIF(UPPER(LEFT(TRIM(b.cancel_reason), 1)) + LOWER(SUBSTRING(TRIM(b.cancel_reason), 2, 100)), '')
        END                                                        AS cancel_reason,

        NULLIF(TRIM(b.cancel_initiated_by), '')                    AS cancel_initiated_by,

        -- Next rebill date: an ambiguous slash date takes the reading equal to last_updated
        COALESCE(nd.fixed,
            CASE WHEN nd.us IS NOT NULL AND nd.dm IS NOT NULL AND nd.us <> nd.dm
                      AND nd.dm = x.last_updated AND nd.us <> x.last_updated
                 THEN nd.dm
                 ELSE COALESCE(nd.us, nd.dm)
            END)                                                   AS next_rebill_date,

        TRY_CAST(TRIM(b.rebill_count) AS INT)                      AS rebill_count,

        CASE WHEN UPPER(TRIM(b.affiliate_id)) LIKE 'AFF-[0-9][0-9][0-9][0-9]'
             THEN UPPER(TRIM(b.affiliate_id)) END                  AS affiliate_id,

        NULLIF(TRIM(b.traffic_source), '')                         AS traffic_source,
        NULLIF(UPPER(TRIM(b.promo_code)), '')                      AS promo_code,

        -- Trial flag; blank -> from the package's billing model
        COALESCE(
            CASE UPPER(TRIM(b.is_trial))
                WHEN 'TRUE' THEN '1' WHEN 'Y' THEN '1' WHEN '1' THEN '1'
                WHEN 'FALSE' THEN '0' WHEN 'N' THEN '0' WHEN '0' THEN '0'
            END,
            CASE WHEN pk.billing_model = 'Trial' THEN '1'
                 WHEN pk.billing_model IN ('Recurring', 'One-Time') THEN '0'
            END)                                                   AS is_trial,
        CASE WHEN UPPER(TRIM(b.is_trial)) IN ('TRUE','Y','1','FALSE','N','0') THEN 0
             WHEN pk.billing_model IN ('Trial', 'Recurring', 'One-Time') THEN 1
             ELSE 0 END                                            AS trial_filled,

        x.last_updated,

        -- Flags for the summary: was an ambiguous date resolved, and was it read day-first?
        (CASE WHEN pd.fixed IS NULL AND pd.us <> pd.dm THEN 1 ELSE 0 END
       + CASE WHEN cd.fixed IS NULL AND cd.us <> cd.dm THEN 1 ELSE 0 END
       + CASE WHEN nd.fixed IS NULL AND nd.us <> nd.dm THEN 1 ELSE 0 END)   AS ambiguous_dates,

        -- Lineage
        b.source_system,
        b.source_file_name,
        b.batch_id,
        b.ingested_at                                              AS bronze_ingested_at,
        b.ingested_by
    INTO #s
    FROM [SegPay].[bronze].[purchases_snapshot] b
    CROSS APPLY (
        SELECT
            purchase_id  = TRY_CAST(TRIM(b.purchase_id) AS INT),
            site_id      = TRY_CAST(TRIM(b.site_id) AS INT),
            package_id   = TRY_CAST(TRIM(b.package_id) AS INT),
            status_key   = UPPER(TRIM(b.purchase_status)),
            reason_key   = UPPER(REPLACE(REPLACE(REPLACE(TRIM(b.cancel_reason), ' ', ''), '_', ''), '-', '')),
            last_updated = TRY_CONVERT(DATE, LEFT(TRIM(b.last_updated), 10), 23),
            -- 'N/A', 'NULL' and '-' mean "no date"
            pd_txt = CASE WHEN UPPER(TRIM(b.purchase_date))    IN ('', 'N/A', 'NULL', '-') THEN NULL ELSE TRIM(b.purchase_date)    END,
            cd_txt = CASE WHEN UPPER(TRIM(b.cancel_date))      IN ('', 'N/A', 'NULL', '-') THEN NULL ELSE TRIM(b.cancel_date)      END,
            nd_txt = CASE WHEN UPPER(TRIM(b.next_rebill_date)) IN ('', 'N/A', 'NULL', '-') THEN NULL ELSE TRIM(b.next_rebill_date) END
    ) x
    -- Each date parsed: 'fixed' = formats with one possible reading; 'us' / 'dm' = slash readings
    CROSS APPLY (
        SELECT
            fixed = CASE
                WHEN x.pd_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.pd_txt, 10), 23)          -- 2025-01-31
                WHEN x.pd_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.pd_txt, 112)                   -- 20250131
                WHEN x.pd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.pd_txt, '-', ' '), 6)  -- 04-May-26
                WHEN x.pd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.pd_txt, '-', ' '), 106)
                WHEN x.pd_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 107)                  -- Apr 26, 2025
            END,
            us = CASE WHEN x.pd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 101) END,     -- MM/DD/YYYY
            dm = CASE WHEN x.pd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 103) END      -- DD/MM/YYYY
    ) pd
    CROSS APPLY (
        SELECT
            fixed = CASE
                WHEN x.cd_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.cd_txt, 10), 23)
                WHEN x.cd_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.cd_txt, 112)
                WHEN x.cd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.cd_txt, '-', ' '), 6)
                WHEN x.cd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.cd_txt, '-', ' '), 106)
                WHEN x.cd_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.cd_txt, 107)
            END,
            us = CASE WHEN x.cd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.cd_txt, 101) END,
            dm = CASE WHEN x.cd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.cd_txt, 103) END
    ) cd
    CROSS APPLY (
        SELECT
            fixed = CASE
                WHEN x.nd_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.nd_txt, 10), 23)
                WHEN x.nd_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.nd_txt, 112)
                WHEN x.nd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.nd_txt, '-', ' '), 6)
                WHEN x.nd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.nd_txt, '-', ' '), 106)
                WHEN x.nd_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.nd_txt, 107)
            END,
            us = CASE WHEN x.nd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.nd_txt, 101) END,
            dm = CASE WHEN x.nd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.nd_txt, 103) END
    ) nd
    LEFT JOIN #first_txn ft
           ON ft.purchase_id = CONVERT(VARCHAR(20), x.purchase_id)
    LEFT JOIN [SegPay].[silver].[packages] pk
           ON pk.package_id = CONVERT(VARCHAR(20), x.package_id)
    -- Exclude test purchases: the test merchant, or a test site
    WHERE ISNULL(UPPER(TRIM(b.merchant_id)), '') <> 'MRC-99999'
      AND NOT EXISTS (SELECT 1 FROM @TestSites ts WHERE ts.site_id = x.site_id);

    -- Test rows excluded = bronze rows not carried into #s
    SELECT @Test = @Bronze - COUNT(*) FROM #s;

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.purchases_snapshot;

    /* -----------------------------------------------------------------
       Step 2: one row per purchase_id, then write to silver.
       Latest last_updated wins; on the same day, the later lifecycle
       state wins (an Active row and a Cancelled row from the same day
       means the purchase was cancelled that day).
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    WITH dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY purchase_id
                   ORDER BY last_updated DESC,                       -- most recent snapshot row first
                            CASE purchase_status                     -- then the later lifecycle state
                                WHEN 'Active'   THEN 1
                                WHEN 'Past Due' THEN 2
                                ELSE 3                               -- Cancelled / Expired / Completed / Chargeback
                            END DESC,
                            bronze_ingested_at DESC                  -- then the newest bronze load
               ) AS rn
        FROM #s
        WHERE purchase_id IS NOT NULL                                -- can't key a row with no purchase ID
    )
    INSERT silver.purchases_snapshot (
        purchase_id, customer_id, merchant_id, site_id, package_id, purchase_date,
        purchase_status, cancel_date, cancel_reason, cancel_initiated_by,
        next_rebill_date, rebill_count, affiliate_id, traffic_source, promo_code,
        is_trial, last_updated, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(20), purchase_id),                             -- never NULL (filtered above)
        COALESCE(customer_id, 'N/A'),
        COALESCE(merchant_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), site_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), package_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), purchase_date, 23), 'N/A'),
        COALESCE(purchase_status, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), cancel_date, 23), 'N/A'),
        COALESCE(cancel_reason, 'N/A'),
        COALESCE(cancel_initiated_by, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), next_rebill_date, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), rebill_count), 'N/A'),
        COALESCE(affiliate_id, 'N/A'),
        COALESCE(traffic_source, 'N/A'),
        COALESCE(promo_code, 'N/A'),
        COALESCE(is_trial, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), last_updated, 23), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary (from the cleaned rows, before de-duplication)
    SELECT @Resolved    = SUM(ambiguous_dates),
           @TrialFilled = SUM(trial_filled)
    FROM #s;

    SELECT @StatusNA = COUNT(*) FROM silver.purchases_snapshot WHERE purchase_status = 'N/A';

    -- One-row summary of the load
    SELECT BronzeRows             = @Bronze,                    -- rows read from bronze
           TestRowsExcluded       = @Test,                      -- test purchases removed
           SilverRows             = @Loaded,                    -- purchases loaded (one row each)
           DuplicatesDropped      = @Bronze - @Test - @Loaded,  -- earlier snapshot rows of the same purchase
           AmbiguousDatesResolved = @Resolved,                  -- slash dates valid both ways, resolved by cross-check
           IsTrialFilledFromPackage = @TrialFilled,             -- blank is_trial taken from the package
           StatusNotAvailable     = @StatusNA;                  -- unrecognized purchase_status
END

-- ===== usp_load_response_codes
/* =====================================================================
   Procedure : silver.usp_load_response_codes
   Source    : bronze.response_codes   (raw text, loaded by bronze.usp_load_response_codes)
   Target    : silver.response_codes   (cleaned, one row per response code)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   Reference list of authorization response codes - the code the card issuer
   returns for every transaction (00 = approved, 51 = insufficient funds, ...).
   silver.transactions takes its response_text from here, so every code has
   one description instead of the gateways' several wordings.

   Key terms
   ---------
   Response code : 2-character ISO 8583 code returned by the issuer; text, not a
                   number ('05' and 'N7' are both valid codes).

   Transformations
   ---------------
     * response_code : trimmed and uppercased, kept as text ('05' keeps its zero).
     * description   : trimmed, then title case like the other silver status
                       values: the first letter of each word is capitalized
                       ('Do not honor' -> 'Do Not Honor'). Letters already in
                       capitals stay that way, so 'CVV2 / CVC2 failure' ->
                       'CVV2 / CVC2 Failure'.
     * Duplicates    : one row per response_code - the newest bronze load wins.
     * Missing values: every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage       : source_system, source_file_name, batch_id,
                       ingested_at (as bronze_ingested_at) and ingested_by
                       carried over from bronze; silver_loaded_at added.

   Usage
   -----
     EXEC silver.usp_load_response_codes;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_response_codes
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.response_codes', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.response_codes (
            response_code       VARCHAR(10)    NOT NULL CONSTRAINT PK_silver_response_codes PRIMARY KEY,
                                                          -- e.g. 00, 51, N7
            description         VARCHAR(200)   NOT NULL,  -- title case, e.g. Insufficient Funds
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_response_codes_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze INT,   -- rows in bronze (input)
            @Loaded INT,   -- rows written to silver (output)
            @i      INT,   -- character position, for the title-case loop
            @MaxLen INT;   -- longest description

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[response_codes];

    /* -----------------------------------------------------------------
       Step 1: clean and de-duplicate into a temporary table.
       One row per code - the newest bronze load wins.
       ----------------------------------------------------------------- */
    SELECT response_code, description, source_system, source_file_name,
           batch_id, bronze_ingested_at, ingested_by
    INTO #rc
    FROM (
        SELECT
            NULLIF(UPPER(TRIM(response_code)), '')     AS response_code,
            NULLIF(TRIM(description), '')              AS description,
            source_system,
            source_file_name,
            batch_id,
            ingested_at                                AS bronze_ingested_at,
            ingested_by,
            ROW_NUMBER() OVER (
                PARTITION BY UPPER(TRIM(response_code))
                ORDER BY ingested_at DESC              -- newest bronze load first
            ) AS rn
        FROM [SegPay].[bronze].[response_codes]
    ) b
    WHERE rn = 1
      AND response_code IS NOT NULL;                   -- can't key a row with no code

    /* -----------------------------------------------------------------
       Step 2: title case the descriptions.
       Walk through the character positions; a letter at the start of the
       text, or right after a space, '/', '-' or '(', is capitalized.
       Other letters are left as they are, so abbreviations already in
       capitals (CVV2, CVC2) are kept.
       ----------------------------------------------------------------- */
    SELECT @MaxLen = MAX(LEN(description)) FROM #rc;
    SET @i = 1;

    WHILE @i <= @MaxLen
    BEGIN
        UPDATE #rc
        SET description = STUFF(description, @i, 1, UPPER(SUBSTRING(description, @i, 1)))
        WHERE LEN(description) >= @i
          AND (@i = 1 OR SUBSTRING(description, @i - 1, 1) IN (' ', '/', '-', '('));

        SET @i += 1;
    END

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.response_codes;

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       ----------------------------------------------------------------- */
    INSERT silver.response_codes (
        response_code, description, source_system, source_file_name,
        batch_id, bronze_ingested_at, ingested_by)
    SELECT
        response_code,                                             -- never NULL (filtered above)
        COALESCE(description, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM #rc;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- One-row summary of the load
    SELECT BronzeRows        = @Bronze,            -- rows read from bronze
           SilverRows        = @Loaded,            -- response codes loaded (one row each)
           DuplicatesDropped = @Bronze - @Loaded;  -- repeated codes removed (plus rows with no code)
END

-- ===== usp_load_risk_events
/* =====================================================================
   Procedure : silver.usp_load_risk_events
   Source    : bronze.risk_events        (one JSON event per row, loaded by bronze.usp_load_risk_events)
   Targets   : silver.risk_events        (cleaned, one row per event)
               silver.risk_event_rules   (one row per rule triggered by an event)
   Load type : Full refresh - both silver tables are emptied and rebuilt from
               bronze each run, in one transaction so they always match.

   Purpose
   -------
   The fraud / risk engine scores each payment attempt before it is sent for
   authorization. Each event records the transaction and purchase it relates
   to, the score (1-99), the decision, which rules fired, and the signals the
   engine used. Joined to silver.transactions and chargebacks, it shows how
   well the engine catches fraud.

   Key terms
   ---------
   Risk score     : 1 (low risk) - 99 (high risk). The same thresholds apply in
                    both engine versions: Approve 1-64, Review 65-87, Decline 88-99.
   Decision       : Approve / Review (sent for manual review) / Decline.
   Rule           : a fraud check that fired, e.g. R104 IP_BIN_COUNTRY_MISMATCH
                    (the IP country differs from the card's issuing country).
   Rule weight    : points the rule adds to the score (engine 2.9.1 only).
   Signals        : inputs the engine used - IP country, card (BIN) country,
                    email address age, attempts in the last hour (velocity),
                    proxy / VPN detected, device fingerprint.

   Engine versions handled
   -----------------------
   The engine was upgraded in February 2026 and its JSON layout changed. The
   bronze columns only hold the old field names, so both versions are read
   from raw_json:
       2.9.1 (Oct 2024 - Jan 2026)            3.1.0 (Feb 2026 onward)
       ---------------------------            -----------------------
       score                                  risk_score
       rules_triggered: [{"rule_id":"R130",   rules: ["R130:PREPAID_BIN"]
         "rule_name":"PREPAID_BIN",             (no weight)
         "weight":6}]
       signals.device_id                      signals.device_fp

   Transformations
   ---------------
     * event_id           : trimmed, kept as text (evt_...).
     * txn_id             : number stored as text; 'N/A' when the engine
                            scored an attempt that never became a transaction.
     * purchase_id        : number stored as text. Declined attempts have a
                            purchase_id that is not in silver.purchases_snapshot
                            (the snapshot only holds purchases that went through).
     * merchant_id        : trimmed and uppercased (MRC-nnnnn).
     * event_ts_utc       : ISO 8601 UTC -> YYYY-MM-DD hh:mm:ss.
     * risk_score         : whole number 1-99 (score or risk_score).
     * decision           : title case - APPROVE / approve -> Approve, etc.
     * rules_triggered_count,
       rule_ids           : number of rules that fired and their IDs in order,
                            e.g. 'R104, R130'; 'N/A' when none fired.
     * signal_ip_country,
       signal_bin_country : 2-letter codes, uppercased.
     * signal_email_age_days,
       signal_velocity_1h : whole numbers.
     * signal_proxy       : '1' = proxy / VPN detected, '0' = not.
     * signal_device_id   : device fingerprint (device_id or device_fp).
     * Signals missing    : 2,497 events have no signals block at all; their
                            signal columns are 'N/A'.
     * risk_event_rules   : one row per rule per event: rule_id, rule_name and
                            rule_weight. Engine 3.1.0 does not send weights,
                            so rule_weight is 'N/A' for those events.
     * Test data          : events for the test merchant MRC-99999 are excluded.
     * Duplicates         : 741 events appear twice in their file (identical
                            JSON); one row per event_id is kept.
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Events for old-gateway merchants name the MRC- merchant that
       silver.merchant_xref is missing: legacy 1002 -> MRC-00001,
       1310 -> MRC-00148, 1229 -> MRC-00107 (consistent in every event).

   Usage
   -----
     EXEC silver.usp_load_risk_events;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_risk_events
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure both target tables exist, so the TRUNCATEs below can
       never fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.risk_events', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.risk_events (
            event_id              VARCHAR(40)    NOT NULL CONSTRAINT PK_silver_risk_events PRIMARY KEY,
                                                            -- e.g. evt_34e6775cdf9e9d97
            txn_id                VARCHAR(20)    NOT NULL,  -- joins to silver.transactions; 'N/A' if none
            purchase_id           VARCHAR(20)    NOT NULL,
            merchant_id           VARCHAR(20)    NOT NULL,  -- MRC-nnnnn
            event_ts_utc          VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss, UTC
            engine_version        VARCHAR(10)    NOT NULL,  -- 2.9.1 / 3.1.0
            risk_score            VARCHAR(3)     NOT NULL,  -- 1-99
            decision              VARCHAR(10)    NOT NULL,  -- Approve / Review / Decline
            rules_triggered_count VARCHAR(3)     NOT NULL,  -- number of rules that fired
            rule_ids              VARCHAR(200)   NOT NULL,  -- e.g. 'R104, R130'; 'N/A' if none
            signal_ip_country     VARCHAR(3)     NOT NULL,  -- 2-letter code
            signal_bin_country    VARCHAR(3)     NOT NULL,  -- card issuing country, 2-letter code
            signal_email_age_days VARCHAR(10)    NOT NULL,
            signal_velocity_1h    VARCHAR(10)    NOT NULL,  -- attempts in the last hour
            signal_proxy          VARCHAR(3)     NOT NULL,  -- '1' = proxy / VPN detected
            signal_device_id      VARCHAR(50)    NOT NULL,  -- device fingerprint
            source_system         VARCHAR(50)    NOT NULL,
            source_file_name      NVARCHAR(260)  NOT NULL,
            batch_id              VARCHAR(36)    NOT NULL,
            bronze_ingested_at    VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by           NVARCHAR(128)  NOT NULL,
            silver_loaded_at      DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_risk_events_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    IF OBJECT_ID(N'silver.risk_event_rules', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.risk_event_rules (
            event_id          VARCHAR(40)    NOT NULL,  -- joins to silver.risk_events
            rule_id           VARCHAR(10)    NOT NULL,  -- e.g. R104
            rule_name         VARCHAR(100)   NOT NULL,  -- e.g. IP_BIN_COUNTRY_MISMATCH
            rule_weight       VARCHAR(5)     NOT NULL,  -- points added to the score; 'N/A' for engine 3.1.0
            engine_version    VARCHAR(10)    NOT NULL,
            source_file_name  NVARCHAR(260)  NOT NULL,
            batch_id          VARCHAR(36)    NOT NULL,
            silver_loaded_at  DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_risk_event_rules_loaded DEFAULT SYSUTCDATETIME(),
            CONSTRAINT PK_silver_risk_event_rules PRIMARY KEY (event_id, rule_id)
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze     INT,   -- rows in bronze (input)
            @Invalid    INT,   -- rows whose raw_json is not valid JSON (skipped)
            @Test       INT,   -- test-merchant events excluded
            @Loaded     INT,   -- events written to silver
            @RulesRows  INT,   -- rule rows written to silver.risk_event_rules
            @V29        INT,   -- events from engine 2.9.1
            @V31        INT,   -- events from engine 3.1.0
            @NoSignals  INT,   -- events with no signals block
            @NoTxn      INT;   -- events with no transaction

    SELECT @Bronze  = COUNT(*),
           @Invalid = SUM(CASE WHEN ISJSON(raw_json) = 1 THEN 0 ELSE 1 END)
    FROM [SegPay].[bronze].[risk_events];

    /* -----------------------------------------------------------------
       Step 1: parse every event from raw_json into #e.
       OPENJSON ... WITH reads both engine versions' field names; the
       cleaning below takes whichever one is present.
       One row per event_id - duplicates are identical copies.
       ----------------------------------------------------------------- */
    SELECT
        j.event_id,
        TRY_CAST(j.txn_id AS BIGINT)                                AS txn_id,
        TRY_CAST(j.purchase_id AS BIGINT)                           AS purchase_id,
        NULLIF(UPPER(TRIM(j.merchant)), '')                         AS merchant_id,

        -- ISO 8601 UTC: '2025-08-22T20:57:41Z' -> 2025-08-22 20:57:41
        TRY_CONVERT(DATETIME2(0), REPLACE(LEFT(j.event_ts, 19), 'T', ' '), 120) AS event_ts_utc,

        NULLIF(TRIM(j.engine_version), '')                          AS engine_version,

        -- Score: 'score' (2.9.1) or 'risk_score' (3.1.0)
        TRY_CAST(COALESCE(j.score, j.risk_score) AS INT)            AS risk_score,

        CASE UPPER(TRIM(j.decision))
            WHEN 'APPROVE' THEN 'Approve'
            WHEN 'REVIEW'  THEN 'Review'
            WHEN 'DECLINE' THEN 'Decline'
        END                                                         AS decision,

        -- The rules list as JSON: 'rules_triggered' (2.9.1) or 'rules' (3.1.0)
        COALESCE(j.rules_triggered, j.rules)                        AS rules_json,

        CASE WHEN UPPER(TRIM(j.ip_country))  LIKE '[A-Z][A-Z]' THEN UPPER(TRIM(j.ip_country))  END AS signal_ip_country,
        CASE WHEN UPPER(TRIM(j.bin_country)) LIKE '[A-Z][A-Z]' THEN UPPER(TRIM(j.bin_country)) END AS signal_bin_country,
        TRY_CAST(j.email_age_days AS INT)                           AS signal_email_age_days,
        TRY_CAST(j.velocity_1h AS INT)                              AS signal_velocity_1h,
        CASE LOWER(TRIM(j.proxy)) WHEN 'true' THEN '1' WHEN 'false' THEN '0' END AS signal_proxy,

        -- Device fingerprint: 'device_id' (2.9.1) or 'device_fp' (3.1.0)
        NULLIF(TRIM(COALESCE(j.device_id, j.device_fp)), '')        AS signal_device_id,

        CASE WHEN j.signals IS NULL THEN 1 ELSE 0 END               AS no_signals,

        -- Lineage
        b.source_system,
        b.source_file_name,
        b.batch_id,
        b.ingested_at                                               AS bronze_ingested_at,
        b.ingested_by,

        ROW_NUMBER() OVER (
            PARTITION BY j.event_id
            ORDER BY b.ingested_at DESC                             -- newest bronze load first
        ) AS rn
    INTO #e
    FROM [SegPay].[bronze].[risk_events] b
    CROSS APPLY OPENJSON(b.raw_json) WITH (
        event_id        VARCHAR(40)   '$.event_id',
        txn_id          VARCHAR(30)   '$.txn_id',
        purchase_id     VARCHAR(30)   '$.purchase_id',
        merchant        VARCHAR(30)   '$.merchant',
        event_ts        VARCHAR(40)   '$.event_ts',
        engine_version  VARCHAR(10)   '$.engine_version',
        score           VARCHAR(10)   '$.score',              -- 2.9.1
        risk_score      VARCHAR(10)   '$.risk_score',         -- 3.1.0
        decision        VARCHAR(20)   '$.decision',
        rules_triggered NVARCHAR(MAX) '$.rules_triggered' AS JSON,   -- 2.9.1
        rules           NVARCHAR(MAX) '$.rules'           AS JSON,   -- 3.1.0
        signals         NVARCHAR(MAX) '$.signals'         AS JSON,
        ip_country      VARCHAR(10)   '$.signals.ip_country',
        bin_country     VARCHAR(10)   '$.signals.bin_country',
        email_age_days  VARCHAR(20)   '$.signals.email_age_days',
        velocity_1h     VARCHAR(20)   '$.signals.velocity_1h',
        proxy           VARCHAR(10)   '$.signals.proxy',
        device_id       VARCHAR(50)   '$.signals.device_id',  -- 2.9.1
        device_fp       VARCHAR(50)   '$.signals.device_fp'   -- 3.1.0
    ) j
    WHERE ISJSON(b.raw_json) = 1
      AND NULLIF(TRIM(j.event_id), '') IS NOT NULL                  -- can't key an event with no ID
      AND ISNULL(UPPER(TRIM(j.merchant)), '') <> 'MRC-99999';       -- exclude the test merchant

    DELETE FROM #e WHERE rn > 1;                                    -- keep one row per event_id

    /* -----------------------------------------------------------------
       Step 2: one row per rule per event into #r.
         2.9.1: [{"rule_id":"R130","rule_name":"PREPAID_BIN","weight":6}]
         3.1.0: ["R130:PREPAID_BIN"]  - split at ':'; no weight
       ----------------------------------------------------------------- */
    SELECT DISTINCT
        e.event_id,
        UPPER(TRIM(COALESCE(r.rule_id,
                   LEFT(r.rule_text, NULLIF(CHARINDEX(':', r.rule_text), 0) - 1)))) AS rule_id,
        UPPER(TRIM(COALESCE(r.rule_name,
                   SUBSTRING(r.rule_text, NULLIF(CHARINDEX(':', r.rule_text), 0) + 1, 100)))) AS rule_name,
        TRY_CAST(r.weight AS INT)                                   AS rule_weight,
        e.engine_version,
        e.source_file_name,
        e.batch_id
    INTO #r
    FROM #e e
    CROSS APPLY OPENJSON(e.rules_json) WITH (
        rule_id    VARCHAR(10)  '$.rule_id',      -- 2.9.1 object
        rule_name  VARCHAR(100) '$.rule_name',
        weight     VARCHAR(10)  '$.weight',
        rule_text  VARCHAR(120) '$'               -- 3.1.0 plain string 'R130:PREPAID_BIN'
    ) r
    WHERE e.rules_json IS NOT NULL;

    DELETE FROM #r WHERE rule_id IS NULL OR rule_id = '';          -- unreadable rule entries

    /* -----------------------------------------------------------------
       Step 3: write both tables in one transaction.
       Every value is converted to text and NULL is replaced with 'N/A'.
       ----------------------------------------------------------------- */
    BEGIN TRAN;

    TRUNCATE TABLE silver.risk_event_rules;
    TRUNCATE TABLE silver.risk_events;

    INSERT silver.risk_events (
        event_id, txn_id, purchase_id, merchant_id, event_ts_utc, engine_version,
        risk_score, decision, rules_triggered_count, rule_ids, signal_ip_country,
        signal_bin_country, signal_email_age_days, signal_velocity_1h, signal_proxy,
        signal_device_id, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        e.event_id,                                                 -- never NULL (filtered above)
        COALESCE(CONVERT(VARCHAR(20), e.txn_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), e.purchase_id), 'N/A'),
        COALESCE(e.merchant_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), e.event_ts_utc, 120), 'N/A'),
        COALESCE(e.engine_version, 'N/A'),
        COALESCE(CONVERT(VARCHAR(3), e.risk_score), 'N/A'),
        COALESCE(e.decision, 'N/A'),
        CONVERT(VARCHAR(3), ISNULL(rl.rule_count, 0)),
        COALESCE(rl.rule_ids, 'N/A'),
        COALESCE(e.signal_ip_country, 'N/A'),
        COALESCE(e.signal_bin_country, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), e.signal_email_age_days), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), e.signal_velocity_1h), 'N/A'),
        COALESCE(e.signal_proxy, 'N/A'),
        COALESCE(e.signal_device_id, 'N/A'),
        COALESCE(e.source_system, 'N/A'),
        COALESCE(e.source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), e.batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), e.bronze_ingested_at, 121), 'N/A'),
        COALESCE(e.ingested_by, 'N/A')
    FROM #e e
    -- Rule count and IDs per event, e.g. 2 / 'R104, R130'
    OUTER APPLY (
        SELECT COUNT(*) AS rule_count,
               STRING_AGG(r.rule_id, ', ') WITHIN GROUP (ORDER BY r.rule_id) AS rule_ids
        FROM #r r
        WHERE r.event_id = e.event_id
    ) rl;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    INSERT silver.risk_event_rules (
        event_id, rule_id, rule_name, rule_weight, engine_version, source_file_name, batch_id)
    SELECT
        event_id,
        rule_id,
        COALESCE(NULLIF(rule_name, ''), 'N/A'),
        COALESCE(CONVERT(VARCHAR(5), rule_weight), 'N/A'),
        COALESCE(engine_version, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A')
    FROM #r;

    SET @RulesRows = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary
    SELECT @Test = COUNT(*)
    FROM [SegPay].[bronze].[risk_events]
    WHERE ISJSON(raw_json) = 1
      AND UPPER(TRIM(JSON_VALUE(raw_json, '$.merchant'))) = 'MRC-99999';

    SELECT @V29       = SUM(CASE WHEN engine_version = '2.9.1' THEN 1 ELSE 0 END),
           @V31       = SUM(CASE WHEN engine_version = '3.1.0' THEN 1 ELSE 0 END),
           @NoSignals = SUM(no_signals),
           @NoTxn     = SUM(CASE WHEN txn_id IS NULL THEN 1 ELSE 0 END)
    FROM #e;

    -- One-row summary of the load
    SELECT BronzeRows         = @Bronze,                                -- rows read from bronze
           InvalidJsonSkipped = @Invalid,                               -- lines that are not valid JSON
           TestRowsExcluded   = @Test,                                  -- test-merchant events removed
           SilverEvents       = @Loaded,                                -- events loaded (one row each)
           Engine291Events    = @V29,                                   --   of which engine 2.9.1
           Engine310Events    = @V31,                                   --   of which engine 3.1.0
           DuplicatesDropped  = @Bronze - @Invalid - @Test - @Loaded,   -- repeated events removed
           RuleRows           = @RulesRows,                             -- rows in silver.risk_event_rules
           EventsWithoutSignals = @NoSignals,                           -- no signals block in the JSON
           EventsWithoutTxn   = @NoTxn;                                 -- scored attempts with no transaction
END

-- ===== usp_load_settlements_weekly
/* =====================================================================
   Procedure : silver.usp_load_settlements_weekly
   Source    : bronze.settlements_weekly   (raw text, loaded by bronze.usp_load_settlements_weekly)
   Target    : silver.settlements_weekly   (cleaned, one row per settlement - latest version)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A settlement is the weekly statement of what SegPay pays a merchant. Each
   row covers one merchant for one Monday-Sunday period and shows how the
   payout was calculated:
       net_payout = gross_sales + refunds (negative) - chargebacks - fees_total
                    - reserve_held + reserve_released + adjustments
   A settlement can be reissued with a higher version number (e.g. after a
   fee recalculation); silver keeps the latest version. Used to reconcile
   merchant payouts against silver.transactions.

   Key terms
   ---------
   Gross sales       : value of the merchant's sales in the period.
   Reserve held      : part of the payout SegPay keeps back to cover future
                       chargebacks and refunds.
   Reserve released  : earlier reserve paid back to the merchant.
   Adjustments       : manual corrections, explained in adjustment_note.
   Net payout        : the amount wired to the merchant.
   Version           : 1 = original statement, 2 = reissued (restated).

   Transformations
   ---------------
     * settlement_id      : trimmed and uppercased (STL-YYYYMMDD-NNNNN; the date
                            is the period start).
     * merchant_id        : trimmed and uppercased.
     * period_start,
       period_end,
       payout_date        : parsed from YYYY-MM-DD, MM/DD/YYYY, DD/MM/YYYY,
                            YYYYMMDD, DD-Mon-YY and "Mon DD, YYYY", stored as
                            YYYY-MM-DD. Slash dates valid both ways are resolved
                            against the settlement_id date instead of guessed:
                              period_start -> the reading equal to the ID date
                              period_end   -> the reading equal to ID date + 6
                              payout_date  -> the reading 1-14 days after
                                              period_end (payouts land 3-9 days after)
                            If neither reading fits, US month/day is used.
     * amounts            : '$' and thousands commas removed ('$1,671.14' ->
                            1671.14), '(0.99)' read as negative; 2 decimals.
                            refunds are stored as negative (the source mixes
                            signs; the payout formula only holds with refunds
                            as a deduction). Other amounts keep their sign.
     * currency           : uppercased ISO code (all USD today).
     * payout_status      : 15 spellings unified to 6 values:
                              Paid, PAID, paid, Complete         -> Paid
                              Pending, PENDING                   -> Pending
                              Scheduled                          -> Scheduled
                              Held, HELD, On Hold                -> Held
                              Failed, FAILED                     -> Failed
                              Returned, RETURNED, Returned by bank -> Returned
                            ('Complete' rows all have a payout date and bank
                            reference, exactly like Paid.)
     * adjustment_note,
       bank_ref           : trimmed, kept as written.
     * version            : whole number.
     * payout_reconciles  : '1' when net_payout equals the formula above
                            (within 2 cents), '0' when it does not.
     * created_ts         : YYYY-MM-DD hh:mm:ss.
     * Test data          : settlements for the test merchant MRC-99999 are excluded.
     * Duplicates         : one row per settlement_id - the highest version,
                            then the latest created_ts, then the newest bronze
                            load (39 rows are exact copies of the same version).
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * ~40 settlements have a net_payout that does not match their components
       (e.g. STL-20241014-00121: components give 77.41, net_payout is 268.49).
       Kept as sent; payout_reconciles = '0' marks them.

   Usage
   -----
     EXEC silver.usp_load_settlements_weekly;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_settlements_weekly
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.settlements_weekly', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.settlements_weekly (
            settlement_id       VARCHAR(30)    NOT NULL CONSTRAINT PK_silver_settlements_weekly PRIMARY KEY,
                                                          -- STL-YYYYMMDD-NNNNN
            merchant_id         VARCHAR(20)    NOT NULL,  -- MRC-nnnnn
            period_start        VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD (a Monday)
            period_end          VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD (the Sunday after)
            currency            VARCHAR(3)     NOT NULL,
            gross_sales         VARCHAR(20)    NOT NULL,  -- 2 decimals
            refunds             VARCHAR(20)    NOT NULL,  -- negative
            chargebacks         VARCHAR(20)    NOT NULL,
            fees_total          VARCHAR(20)    NOT NULL,
            reserve_held        VARCHAR(20)    NOT NULL,
            reserve_released    VARCHAR(20)    NOT NULL,
            adjustments         VARCHAR(20)    NOT NULL,  -- + or -
            adjustment_note     VARCHAR(500)   NOT NULL,
            net_payout          VARCHAR(20)    NOT NULL,  -- amount wired to the merchant
            payout_reconciles   VARCHAR(3)     NOT NULL,  -- '1' = net_payout matches its components
            payout_date         VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD; 'N/A' if not paid yet
            payout_status       VARCHAR(20)    NOT NULL,  -- Paid / Pending / Scheduled / Held / Failed / Returned
            bank_ref            VARCHAR(100)   NOT NULL,  -- wire reference
            version             VARCHAR(5)     NOT NULL,  -- 1 = original, 2 = reissued
            created_ts          VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_settlements_weekly_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze      INT,   -- rows in bronze (input)
            @Test        INT,   -- test-merchant rows excluded
            @Loaded      INT,   -- rows written to silver (output)
            @Reissued    INT,   -- settlements whose kept row is a reissued version (> 1)
            @NotRecon    INT,   -- settlements whose net_payout doesn't match its components
            @DateNA      INT;   -- settlements with an unreadable period date

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[settlements_weekly];

    SELECT @Test = COUNT(*) FROM [SegPay].[bronze].[settlements_weekly]
    WHERE UPPER(TRIM(merchant_id)) = 'MRC-99999';

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.settlements_weekly;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, cleaned and typed.
       Missing values are NULL here; they become 'N/A' in the final insert.

       CROSS APPLY x  : trimmed values; id_date = the date inside settlement_id.
       CROSS APPLY ps / pe / pd : each date parsed three ways - 'fixed'
                        (formats with only one reading), 'us' (MM/DD/YYYY)
                        and 'dm' (DD/MM/YYYY).
       CROSS APPLY m  : every amount as a number.
       ----------------------------------------------------------------- */
    WITH s AS (
        SELECT
            x.settlement_id,
            NULLIF(UPPER(TRIM(b.merchant_id)), '')                 AS merchant_id,

            -- Period start: an ambiguous slash date takes the reading equal to the ID date
            COALESCE(ps.fixed,
                CASE WHEN ps.dm = x.id_date AND ps.us <> x.id_date THEN ps.dm
                     ELSE COALESCE(ps.us, ps.dm) END)              AS period_start,

            -- Period end: the reading equal to ID date + 6
            COALESCE(pe.fixed,
                CASE WHEN pe.dm = DATEADD(DAY, 6, x.id_date) AND pe.us <> DATEADD(DAY, 6, x.id_date) THEN pe.dm
                     ELSE COALESCE(pe.us, pe.dm) END)              AS period_end,

            NULLIF(UPPER(TRIM(b.currency)), '')                    AS currency,

            m.gross_sales,
            -ABS(m.refunds)                                        AS refunds,     -- always a deduction
            m.chargebacks,
            m.fees_total,
            m.reserve_held,
            m.reserve_released,
            m.adjustments,
            NULLIF(TRIM(b.adjustment_note), '')                    AS adjustment_note,
            m.net_payout,

            -- Does net_payout equal its components? (within 2 cents)
            CASE WHEN ABS(m.gross_sales - ABS(m.refunds) - m.chargebacks - m.fees_total
                          - m.reserve_held + m.reserve_released + m.adjustments - m.net_payout) <= 0.02
                 THEN '1'
                 WHEN m.net_payout IS NOT NULL THEN '0'
            END                                                    AS payout_reconciles,

            -- Payout date: an ambiguous slash date takes the reading 1-14 days after the period end
            COALESCE(pd.fixed,
                CASE WHEN DATEDIFF(DAY, DATEADD(DAY, 6, x.id_date), pd.dm) BETWEEN 1 AND 14
                      AND NOT DATEDIFF(DAY, DATEADD(DAY, 6, x.id_date), pd.us) BETWEEN 1 AND 14
                     THEN pd.dm
                     ELSE COALESCE(pd.us, pd.dm) END)              AS payout_date,

            CASE UPPER(TRIM(b.payout_status))
                WHEN 'PAID'             THEN 'Paid'
                WHEN 'COMPLETE'         THEN 'Paid'
                WHEN 'PENDING'          THEN 'Pending'
                WHEN 'SCHEDULED'        THEN 'Scheduled'
                WHEN 'HELD'             THEN 'Held'
                WHEN 'ON HOLD'          THEN 'Held'
                WHEN 'FAILED'           THEN 'Failed'
                WHEN 'RETURNED'         THEN 'Returned'
                WHEN 'RETURNED BY BANK' THEN 'Returned'
            END                                                    AS payout_status,

            NULLIF(UPPER(TRIM(b.bank_ref)), '')                    AS bank_ref,
            TRY_CAST(TRIM(b.version) AS INT)                       AS version,
            TRY_CONVERT(DATETIME2(0), LEFT(TRIM(b.created_ts), 19), 120) AS created_ts,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                          AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[settlements_weekly] b
        CROSS APPLY (
            SELECT
                settlement_id = NULLIF(UPPER(TRIM(b.settlement_id)), ''),
                -- STL-20240930-00105 -> 2024-09-30 (the period start)
                id_date       = TRY_CONVERT(DATE, SUBSTRING(TRIM(b.settlement_id), 5, 8), 112),
                ps_txt        = NULLIF(TRIM(b.period_start), ''),
                pe_txt        = NULLIF(TRIM(b.period_end), ''),
                pd_txt        = NULLIF(TRIM(b.payout_date), '')
        ) x
        CROSS APPLY (
            SELECT
                fixed = CASE
                    WHEN x.ps_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.ps_txt, 10), 23)          -- 2024-09-30
                    WHEN x.ps_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.ps_txt, 112)                   -- 20240930
                    WHEN x.ps_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.ps_txt, '-', ' '), 6)  -- 30-Sep-24
                    WHEN x.ps_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.ps_txt, '-', ' '), 106)
                    WHEN x.ps_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.ps_txt, 107)                  -- Sep 30, 2024
                END,
                us = CASE WHEN x.ps_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.ps_txt, 101) END,     -- MM/DD/YYYY
                dm = CASE WHEN x.ps_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.ps_txt, 103) END      -- DD/MM/YYYY
        ) ps
        CROSS APPLY (
            SELECT
                fixed = CASE
                    WHEN x.pe_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.pe_txt, 10), 23)
                    WHEN x.pe_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.pe_txt, 112)
                    WHEN x.pe_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.pe_txt, '-', ' '), 6)
                    WHEN x.pe_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.pe_txt, '-', ' '), 106)
                    WHEN x.pe_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pe_txt, 107)
                END,
                us = CASE WHEN x.pe_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pe_txt, 101) END,
                dm = CASE WHEN x.pe_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pe_txt, 103) END
        ) pe
        CROSS APPLY (
            SELECT
                fixed = CASE
                    WHEN x.pd_txt LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'      THEN TRY_CONVERT(DATE, LEFT(x.pd_txt, 10), 23)
                    WHEN x.pd_txt LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'         THEN TRY_CONVERT(DATE, x.pd_txt, 112)
                    WHEN x.pd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'          THEN TRY_CONVERT(DATE, REPLACE(x.pd_txt, '-', ' '), 6)
                    WHEN x.pd_txt LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, REPLACE(x.pd_txt, '-', ' '), 106)
                    WHEN x.pd_txt LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 107)
                END,
                us = CASE WHEN x.pd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 101) END,
                dm = CASE WHEN x.pd_txt LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.pd_txt, 103) END
        ) pd
        -- Amounts: '$', thousands commas and spaces removed; '(0.99)' -> -0.99
        CROSS APPLY (
            SELECT
                gross_sales      = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.gross_sales),      '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                refunds          = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.refunds),          '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                chargebacks      = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.chargebacks),      '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                fees_total       = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.fees_total),       '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                reserve_held     = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.reserve_held),     '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                reserve_released = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.reserve_released), '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                adjustments      = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.adjustments),      '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2)),
                net_payout       = TRY_CAST(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.net_payout),       '$', ''), ',', ''), ' ', ''), '(', '-'), ')', '') AS DECIMAL(18,2))
        ) m
        -- Exclude the test merchant
        WHERE ISNULL(UPPER(TRIM(b.merchant_id)), '') <> 'MRC-99999'
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - one row per settlement_id: the latest version.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY settlement_id
                   ORDER BY version DESC,              -- reissued version first
                            created_ts DESC,           -- then the latest statement
                            bronze_ingested_at DESC    -- then the newest bronze load
               ) AS rn
        FROM s
        WHERE settlement_id IS NOT NULL                -- can't key a row with no settlement ID
    )

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    INSERT silver.settlements_weekly (
        settlement_id, merchant_id, period_start, period_end, currency, gross_sales,
        refunds, chargebacks, fees_total, reserve_held, reserve_released, adjustments,
        adjustment_note, net_payout, payout_reconciles, payout_date, payout_status,
        bank_ref, version, created_ts, source_system, source_file_name, batch_id,
        bronze_ingested_at, ingested_by)
    SELECT
        settlement_id,                                                 -- never NULL (filtered above)
        COALESCE(merchant_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), period_start, 23), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), period_end, 23), 'N/A'),
        COALESCE(currency, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), gross_sales), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), refunds), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), chargebacks), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), fees_total), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), reserve_held), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), reserve_released), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), adjustments), 'N/A'),
        COALESCE(adjustment_note, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), net_payout), 'N/A'),
        COALESCE(payout_reconciles, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), payout_date, 23), 'N/A'),
        COALESCE(payout_status, 'N/A'),
        COALESCE(bank_ref, 'N/A'),
        COALESCE(CONVERT(VARCHAR(5), version), 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), created_ts, 120), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary
    SELECT @Reissued = SUM(CASE WHEN version NOT IN ('1', 'N/A') THEN 1 ELSE 0 END),
           @NotRecon = SUM(CASE WHEN payout_reconciles = '0' THEN 1 ELSE 0 END),
           @DateNA   = SUM(CASE WHEN period_start = 'N/A' OR period_end = 'N/A' THEN 1 ELSE 0 END)
    FROM silver.settlements_weekly;

    -- One-row summary of the load
    SELECT BronzeRows            = @Bronze,                    -- rows read from bronze
           TestRowsExcluded      = @Test,                      -- test-merchant settlements removed
           SilverRows            = @Loaded,                    -- settlements loaded (one row each)
           OlderVersionsDropped  = @Bronze - @Test - @Loaded,  -- superseded versions and exact copies
           ReissuedSettlements   = @Reissued,                  -- kept row is a reissued version
           PayoutNotReconciling  = @NotRecon,                  -- net_payout differs from its components
           PeriodDateNotAvailable = @DateNA;                   -- unreadable period date
END

-- ===== usp_load_sites
/* =====================================================================
   Procedure : silver.usp_load_sites
   Source    : bronze.sites   (raw text, loaded by bronze.usp_load_sites)
   Target    : silver.sites   (cleaned, one row per site)
   Load type : Full refresh - silver is emptied and rebuilt from bronze each run.

   Purpose
   -------
   A site is a website a merchant sells through. Each site belongs to one
   merchant and sells one or more packages (silver.packages, via site_id).
   The billing descriptor is the text that appears on the cardholder's bank
   statement; customers who don't recognize it are more likely to file a
   chargeback.

   Key terms
   ---------
   Site ID            : SegPay's site number (e.g. 5003); matches site_id on
                        packages, purchases and gateway transactions.
   Merchant ID        : the new gateway's merchant identifier (MRC-nnnnn); joins
                        to silver.merchants_crm_export and silver.merchant_accounts.
   Billing descriptor : statement text, in the form SEGPAY*SITENAME.

   Transformations
   ---------------
     * site_id            : trimmed and converted to a number (removes spaces and
                            leading zeros), stored as text. Rows with no valid
                            site_id are skipped.
     * merchant_id        : trimmed and uppercased (mrc-00001 -> MRC-00001).
     * site_name          : trimmed (' Pixel Pass' -> 'Pixel Pass').
     * site_url           : reduced to the bare domain, lowercased:
                              https://emberhub.com/ -> emberhub.com
                              www.emberpro.com      -> emberpro.com
     * category           : trimmed, kept as written.
     * launch_date        : parsed from YYYY-MM-DD, MM/DD/YYYY, DD/MM/YYYY,
                            YYYYMMDD, DD-Mon-YY and "Mon DD, YYYY" (each with its
                            own style code), stored as YYYY-MM-DD.
                            Slash dates are read as US month/day first; when that
                            is impossible (e.g. 18/07/2023) they are read day-first.
     * status             : title case only - values are NOT merged:
                              LIVE, live -> Live      CLOSED -> Closed
                            Live, Active, Closed, Inactive, Paused and
                            Under Review stay distinct.
     * billing_descriptor : prefix unified and uppercased:
                              Segpay *Bluehub, Segpay.Com*Novaplus -> SEGPAY*BLUEHUB, SEGPAY*NOVAPLUS
     * support_email      : trimmed and lowercased.
     * Test data          : test sites (category 'Test' or the test merchant
                            MRC-99999, e.g. 4001 'QA Sandbox A') are excluded.
     * Duplicates         : one row per site_id - the newest bronze load wins.
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : source_system, source_file_name, batch_id,
                            ingested_at (as bronze_ingested_at) and ingested_by
                            carried over from bronze; silver_loaded_at added.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * 4 sites have a launch_date after the load date (5194, 5198, 5734, 5757).
       They are kept as given; the summary counts them.
     * 12 sites belong to merchants MRC-00200 - MRC-00205, which are in
       silver.merchants_crm_export but not in silver.merchant_accounts.
     * 33 sites have no support email.

   Usage
   -----
     EXEC silver.usp_load_sites;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_sites
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.sites', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.sites (
            site_id             VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_sites PRIMARY KEY,
                                                          -- site number, e.g. 5003
            merchant_id         VARCHAR(20)    NOT NULL,  -- owning merchant, e.g. MRC-00001
            site_name           NVARCHAR(255)  NOT NULL,  -- e.g. Ember Pro
            site_url            VARCHAR(255)   NOT NULL,  -- bare domain, e.g. emberpro.com
            category            VARCHAR(100)   NOT NULL,  -- content category, e.g. VPN, Live Cams
            launch_date         VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            status              VARCHAR(20)    NOT NULL,  -- Live / Active / Closed / Inactive / Paused / Under Review
            billing_descriptor  VARCHAR(50)    NOT NULL,  -- statement text, SEGPAY*SITENAME
            support_email       NVARCHAR(320)  NOT NULL,  -- lowercase; 'N/A' when missing
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_sites_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Bronze       INT,   -- rows in bronze (input)
            @Test         INT,   -- test sites excluded
            @Loaded       INT,   -- rows written to silver (output)
            @DateNA       INT,   -- sites with no usable launch_date
            @FutureLaunch INT,   -- sites with a launch_date after today
            @EmailMissing INT,   -- sites with no support email
            @NoAccount    INT;   -- sites whose merchant isn't in silver.merchant_accounts

    SELECT @Bronze = COUNT(*) FROM [SegPay].[bronze].[sites];

    -- Count the test rows that will be excluded, for the summary
    SELECT @Test = COUNT(*)
    FROM [SegPay].[bronze].[sites]
    WHERE UPPER(TRIM(category)) = 'TEST' OR UPPER(TRIM(merchant_id)) = 'MRC-99999';

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.sites;

    /* -----------------------------------------------------------------
       CTE 1: s - every silver column, cleaned and typed.
       Missing values are NULL here; they become 'N/A' in the final insert.
       Test sites are filtered out here.

       CROSS APPLY x : trimmed raw values and lookup keys, computed once.
       ----------------------------------------------------------------- */
    WITH s AS (
        SELECT
            -- Site ID as a number (removes spaces and leading zeros)
            TRY_CAST(x.site_id AS INT)                             AS site_id,

            x.merchant_id,

            NULLIF(TRIM(b.site_name), '')                          AS site_name,

            -- URL: bare domain - scheme, 'www.' and anything after the domain removed.
            -- '/' is appended so CHARINDEX always finds one: 'emberhub.com/' -> 'emberhub.com'
            NULLIF(LEFT(x.url_no_www, CHARINDEX('/', x.url_no_www + '/') - 1), '') AS site_url,

            NULLIF(TRIM(b.category), '')                           AS category,

            -- Launch date: each format converted with its own style code
            CASE
                WHEN x.ld LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'                -- 2023-08-07
                    THEN TRY_CONVERT(DATE, LEFT(x.ld, 10), 23)
                WHEN x.ld LIKE '[0-3][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]'                -- 04/13/2025 or 18/07/2023
                    THEN COALESCE(TRY_CONVERT(DATE, x.ld, 101),                           --   US month/day first
                                  TRY_CONVERT(DATE, x.ld, 103))                           --   else day/month
                WHEN x.ld LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'                   -- 20200917
                    THEN TRY_CONVERT(DATE, x.ld, 112)
                WHEN x.ld LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'                    -- 30-Jun-23
                    THEN TRY_CONVERT(DATE, REPLACE(x.ld, '-', ' '), 6)
                WHEN x.ld LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]'           -- 30-Jun-2023
                    THEN TRY_CONVERT(DATE, REPLACE(x.ld, '-', ' '), 106)
                WHEN x.ld LIKE '[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]'          -- Jul 14, 2020
                    THEN TRY_CONVERT(DATE, x.ld, 107)
            END                                                    AS launch_date,

            -- Status: title case only; values are kept distinct (not merged)
            CASE x.status_key
                WHEN 'live'         THEN 'Live'
                WHEN 'active'       THEN 'Active'
                WHEN 'closed'       THEN 'Closed'
                WHEN 'inactive'     THEN 'Inactive'
                WHEN 'paused'       THEN 'Paused'
                WHEN 'under review' THEN 'Under Review'
                ELSE UPPER(LEFT(x.status_key, 1)) + SUBSTRING(x.status_key, 2, 50)   -- unknown: capitalize
            END                                                    AS status,

            -- Descriptor: whatever prefix comes before '*' becomes 'SEGPAY*'; all uppercase.
            -- A descriptor with no '*' is kept, just trimmed and uppercased.
            CASE
                WHEN CHARINDEX('*', x.descr) > 0
                    THEN 'SEGPAY*' + UPPER(TRIM(SUBSTRING(x.descr, CHARINDEX('*', x.descr) + 1, 100)))
                ELSE UPPER(x.descr)
            END                                                    AS billing_descriptor,

            NULLIF(LOWER(TRIM(b.support_email)), '')               AS support_email,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                          AS bronze_ingested_at,
            b.ingested_by
        FROM [SegPay].[bronze].[sites] b
        CROSS APPLY (
            SELECT
                site_id     = NULLIF(TRIM(b.site_id), ''),
                merchant_id = NULLIF(UPPER(TRIM(b.merchant_id)), ''),
                -- URL lowercased with 'https://', 'http://' and a leading 'www.' removed
                url_no_www  = CASE WHEN u.url LIKE 'www.%' THEN SUBSTRING(u.url, 5, 500) ELSE u.url END,
                ld          = NULLIF(TRIM(b.launch_date), ''),
                status_key  = NULLIF(LOWER(TRIM(b.status)), ''),
                descr       = NULLIF(TRIM(b.billing_descriptor), '')
            FROM (SELECT url = REPLACE(REPLACE(LOWER(TRIM(b.site_url)), 'https://', ''), 'http://', '')) u
        ) x
        -- Exclude test sites (e.g. 4001 'QA Sandbox A', merchant MRC-99999).
        -- ISNULL keeps rows with an empty category or merchant (NULL <> 'TEST' would drop them).
        WHERE ISNULL(UPPER(TRIM(b.category)), '')    <> 'TEST'
          AND ISNULL(UPPER(TRIM(b.merchant_id)), '') <> 'MRC-99999'
    ),

    /* -----------------------------------------------------------------
       CTE 2: dedup - one row per site_id.
       bronze.sites has no last-changed date, so the newest bronze load wins.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY site_id
                   ORDER BY bronze_ingested_at DESC    -- newest bronze load first
               ) AS rn
        FROM s
        WHERE site_id IS NOT NULL                      -- can't key a row with no site ID
    )

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    INSERT silver.sites (
        site_id, merchant_id, site_name, site_url, category, launch_date,
        status, billing_descriptor, support_email, source_system,
        source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(20), site_id),                                 -- never NULL (filtered above)
        COALESCE(merchant_id, 'N/A'),
        COALESCE(site_name, 'N/A'),
        COALESCE(site_url, 'N/A'),
        COALESCE(category, 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), launch_date, 23), 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(billing_descriptor, 'N/A'),
        COALESCE(support_email, 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup
    WHERE rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Data-quality counts for the summary.
    -- Dates are stored as YYYY-MM-DD text, so a text comparison with today works.
    DECLARE @Today VARCHAR(10) = CONVERT(VARCHAR(10), CAST(SYSUTCDATETIME() AS DATE), 23);

    SELECT @DateNA       = SUM(CASE WHEN launch_date   = 'N/A' THEN 1 ELSE 0 END),
           @FutureLaunch = SUM(CASE WHEN launch_date  <> 'N/A' AND launch_date > @Today THEN 1 ELSE 0 END),
           @EmailMissing = SUM(CASE WHEN support_email = 'N/A' THEN 1 ELSE 0 END)
    FROM silver.sites;

    -- Counted separately: SUM can't contain a subquery
    SELECT @NoAccount = COUNT(*)
    FROM silver.sites s
    WHERE NOT EXISTS (SELECT 1 FROM silver.merchant_accounts m WHERE m.merchant_id = s.merchant_id);

    -- One-row summary of the load
    SELECT BronzeRows              = @Bronze,                    -- rows read from bronze
           TestRowsExcluded        = @Test,                      -- test sites removed
           SilverRows              = @Loaded,                    -- sites loaded (one row each)
           DuplicatesDropped       = @Bronze - @Test - @Loaded,  -- older copies removed (plus rows with no site ID)
           LaunchDateNotAvailable  = @DateNA,                    -- missing or unreadable launch date
           FutureLaunchDate        = @FutureLaunch,              -- launch date after today
           SupportEmailMissing     = @EmailMissing,              -- no support email
           MerchantNotInAccounts   = @NoAccount;                 -- merchant missing from silver.merchant_accounts
END

-- ===== usp_load_transactions
/* =====================================================================
   Procedure : silver.usp_load_transactions
   Source    : bronze.txn_pre_migration   (old gateway, Sep 2024 - Feb 2026)
               bronze.txn_post_migration  (new gateway, Mar 2026 onward)
   Target    : silver.transactions        (cleaned, one row per txn_id, both gateways)
   Load type : Full refresh - silver is emptied and rebuilt from both bronze
               tables each run.

   Purpose
   -------
   Each row is one payment event: a sale, rebill, auth, refund, void or
   chargeback. The payment gateway migrated in March 2026, so transactions
   arrive in two bronze tables with slightly different layouts. This
   procedure appends them into one table with one set of cleaning rules,
   so reporting can span the migration.

   Layout differences handled
   --------------------------
       Old gateway (pre)    New gateway (post)    Silver column
       -----------------    ------------------    -------------
       currency             ccy                   currency
       auth_timestamp       txn_ts_utc            txn_ts_utc
         (US Eastern time)    (UTC)                 (UTC for both)
       merchant_id 1005     merchant_id MRC-00002 merchant_id (MRC-) +
                                                  legacy_merchant_id
       card_bin (6 digits)  card_bin (8 digits)   card_bin + card_bin6
       -                    network_txn_id        network_txn_id ('N/A' for pre)

   Key terms
   ---------
   Migration phase : which gateway the row came from - 'Pre-migration' (old)
                     or 'Post-migration' (new).
   Purchase ID     : the customer's purchase (subscription); one purchase has
                     many transactions (the sale, then each rebill).
   Parent txn ID   : the original transaction a refund / void / chargeback
                     reverses.
   BIN             : Bank Identification Number - leading digits of the card;
                     card_bin6 joins to silver.bin_reference.
   MID             : Merchant ID number at the acquirer (the merchant's
                     account at the acquiring bank).
   3-D Secure      : extra cardholder authentication step (1 = used).
   Network txn ID  : the card network's own reference (new gateway only).

   Transformations
   ---------------
     * txn_id, purchase_id,
       parent_txn_id      : trimmed, converted to a number, stored as text.
                            parent_txn_id 0 (old gateway's "none") -> 'N/A'.
     * merchant_id        : new gateway: trimmed and uppercased.
                            Old gateway: legacy number mapped to MRC- through
                            silver.merchant_xref; unmapped -> 'N/A'.
     * legacy_merchant_id : old gateway's number; 'N/A' for new-gateway rows.
     * site_id, package_id: converted to a number, stored as text.
                            A site_id not in silver.sites (random values such
                            as 98497) is replaced by the package's site from
                            silver.packages - for every transaction with a valid
                            site and package, the package's site matches.
     * customer_id        : trimmed and uppercased.
     * txn_type           : 25 spellings unified:
                              SALE, Sale, S              -> Sale
                              REBILL, Rebill, RB, R      -> Rebill
                              AUTH, Auth                 -> Auth
                              ZERO_AUTH                  -> Zero Auth
                              REFUND, Refund, RFND, RF   -> Refund
                              VOID, Void, VD             -> Void
                              CHARGEBACK, Chargeback, CB -> Chargeback
     * amount             : '$' removed, decimal comma -> point ('9,99' -> 9.99),
                            '(0.99)' read as negative; 2 decimals.
                            Sign follows the new gateway's rule for both:
                            Refund / Void / Chargeback negative, all others
                            positive (the old gateway signed ~half its refunds
                            and chargebacks positive).
     * currency           : ISO 3-letter, uppercased; numeric ISO codes mapped
                            (840 USD, 978 EUR, 826 GBP, 036 AUD, 124 CAD).
     * amount_usd         : amount converted with the US Treasury rate from
                            silver.fx_rates_daily - the most recent rate on or
                            before the transaction's UTC date (same method as
                            silver.chargebacks_acquirer_feed and
                            silver.clearing_transactions). USD unchanged; no
                            rate or no currency -> 'N/A'.
     * fx_rate,
       fx_rate_date       : the rate used (USD per 1 unit) and its date;
                            'N/A' for USD.
     * card_brand         : Visa / Mastercard / American Express / UnionPay / JCB
                            (same names as silver.bin_reference; VI, MC, AX, UP mapped).
     * card_bin           : digits as sent (6 old, 8 new).
     * card_bin6          : first 6 digits, for joining to silver.bin_reference.
     * payment_method     : Card / Apple Pay / Google Pay / SEPA Direct Debit
                            (CC, Credit Card -> Card; AP -> Apple Pay; GPAY -> Google Pay).
     * response_code      : trimmed and uppercased, kept as text ('00', 'N7').
     * response_text      : one description per response code, taken from
                            silver.response_codes (51 -> 'Insufficient Funds',
                            whether the gateway sent 'NSF', 'Insufficient funds'
                            or nothing). A code missing from the reference
                            falls back to the gateway's wording.
     * gateway_response_text : the gateway's own wording, kept for detail (e.g.
                            code 00 can be 'Refund Processed' or 'Voided');
                            title case like status ('DO NOT HONOR' ->
                            'Do Not Honor'), abbreviations kept uppercase
                            (NSF, CVV, CVV2, OK).
     * status             : Approved / Declined / Error (APPR, A, DECL, D mapped).
     * txn_ts_utc         : stored as YYYY-MM-DD hh:mm:ss in UTC.
                            Old gateway: YYYY-MM-DD hh:mm:ss, MM/DD/YYYY hh:mm:ss AM
                            and DD-MON-YYYY hh:mm:ss, in US Eastern time,
                            converted to UTC (daylight saving handled by
                            AT TIME ZONE).
                            New gateway: ISO 8601 (with or without
                            milliseconds), 'YYYY-MM-DD hh:mm:ss+00:00' and
                            Unix epoch seconds, already UTC.
     * settle_date        : YYYYMMDD or MM/DD/YYYY -> YYYY-MM-DD.
     * acquirer           : Northgate Acquiring / Pacific Merchant Bank /
                            EuroSettle Payments (NG ACQ, NORTHGATE, PACMB,
                            Pacific Merch Bank, EUROSETTLE mapped).
     * three_ds           : '1' = 3-D Secure used, '0' = not used
                            (Y, y, TRUE, 1 / N, FALSE, 0).
     * device_type        : Mobile / Desktop / Tablet (M, D, PC, T mapped).
     * ip_country         : 2-letter code; 'XX' (unknown) -> 'N/A'.
     * affiliate_id       : AFF-0000 format; old gateway's bare numbers padded
                            (9 -> AFF-0009).
     * gateway_batch_id,
       gateway_load_ts    : the gateway's own batch reference and export time
                            (bronze batch_id_source and load_ts).
     * Test data          : excluded when is_test is set (TRUE, T, Y, 1), the
                            merchant is the test merchant (MRC-99999 / legacy
                            9999), or the transaction is on a test site
                            (bronze.sites category 'Test' or merchant MRC-99999 -
                            same rule as silver.sites and silver.packages).
     * Duplicates         : one row per txn_id. The new gateway re-sent 39
                            February 2026 transactions in its first file, and
                            ~1,400 txn_ids repeat within a gateway (same event,
                            different formatting). Kept: the new-gateway copy,
                            then the latest gateway export, then the newest
                            bronze load.
     * Missing values     : every column is stored as text; NULL/blank -> 'N/A'.
     * Lineage            : migration_phase added; source_system,
                            source_file_name, batch_id, ingested_at (as
                            bronze_ingested_at) and ingested_by carried over;
                            silver_loaded_at added.

   Dependencies
   ------------
   Load these silver tables first:
     silver.merchant_xref    (legacy -> MRC- merchant mapping)
     silver.response_codes   (one description per response code)
     silver.sites,
     silver.packages         (site recovery from the package)
     silver.fx_rates_daily   (USD conversion)

   PII
   ---
   ip_address and card_last4 relate to a cardholder.

   Known data gaps (as of 2026-10-15)
   ----------------------------------
     * Old-gateway legacy merchants 1002, 1229 and 1310 have no MRC- mapping
       in silver.merchant_xref; their transactions have merchant_id 'N/A'
       (legacy_merchant_id is kept).
     * ~490 transactions have a site_id not in silver.sites (e.g. 98497);
       ~480 are recovered from the package, the rest keep the value as sent.
     * ~14,800 transactions have a card_bin6 not in silver.bin_reference
       (243 BINs) - the reference table is incomplete, not the transactions.
     * New-gateway files include some events dated before the migration
       (earliest 2026-01-26): refunds / chargebacks of older sales and the
       39 re-sent February transactions. migration_phase records which
       gateway sent the row, not when the payment happened.
     * The US Eastern assumption for old-gateway times is confirmed for
       February 2026 (exactly 5 hours behind the re-sent new-gateway copies).

   Usage
   -----
     EXEC silver.usp_load_merchant_xref;   -- dependencies
     EXEC silver.usp_load_response_codes;
     EXEC silver.usp_load_sites;
     EXEC silver.usp_load_packages;
     EXEC silver.usp_load_fx_rates_daily;
     EXEC silver.usp_load_transactions;
   ===================================================================== */

-- CREATE OR ALTER: creates the procedure the first time, replaces it on re-runs
CREATE   PROCEDURE silver.usp_load_transactions
AS
BEGIN
    -- Stop SQL Server sending "(n rows affected)" messages after each statement.
    SET NOCOUNT ON;

    -- If any statement fails, abort and roll back the whole transaction.
    SET XACT_ABORT ON;

    /* -----------------------------------------------------------------
       Make sure the target table exists, so the TRUNCATE below can never
       fail with "Cannot find the object" (error 4701).
       All columns are text so any missing value can be stored as 'N/A'.
       ----------------------------------------------------------------- */
    IF OBJECT_ID(N'silver.transactions', N'U') IS NULL
    BEGIN
        CREATE TABLE silver.transactions (
            txn_id              VARCHAR(20)    NOT NULL CONSTRAINT PK_silver_transactions PRIMARY KEY,
                                                          -- transaction number, e.g. 810000001
            migration_phase     VARCHAR(15)    NOT NULL,  -- Pre-migration (old gateway) / Post-migration (new)
            purchase_id         VARCHAR(20)    NOT NULL,  -- purchase (subscription) the transaction belongs to
            parent_txn_id       VARCHAR(20)    NOT NULL,  -- transaction reversed by a refund/void/chargeback
            merchant_id         VARCHAR(20)    NOT NULL,  -- MRC-nnnnn
            legacy_merchant_id  VARCHAR(20)    NOT NULL,  -- old gateway's merchant number; 'N/A' for new gateway
            site_id             VARCHAR(20)    NOT NULL,
            package_id          VARCHAR(20)    NOT NULL,
            customer_id         VARCHAR(20)    NOT NULL,  -- e.g. C00000001
            txn_type            VARCHAR(12)    NOT NULL,  -- Sale / Rebill / Auth / Zero Auth / Refund / Void / Chargeback
            amount              VARCHAR(20)    NOT NULL,  -- 2 decimals; negative for Refund / Void / Chargeback
            currency            VARCHAR(3)     NOT NULL,  -- ISO code, e.g. USD
            amount_usd          VARCHAR(20)    NOT NULL,  -- amount in USD, 2 decimals (US Treasury rate)
            fx_rate             VARCHAR(20)    NOT NULL,  -- USD per 1 unit of currency used; 'N/A' for USD
            fx_rate_date        VARCHAR(10)    NOT NULL,  -- date of that rate, YYYY-MM-DD
            card_brand         VARCHAR(20)    NOT NULL,  -- Visa / Mastercard / American Express / UnionPay / JCB
            card_bin            VARCHAR(8)     NOT NULL,  -- as sent: 6 digits (old) or 8 (new)
            card_bin6           VARCHAR(6)     NOT NULL,  -- first 6 digits; joins to silver.bin_reference
            card_last4          VARCHAR(4)     NOT NULL,  -- PII
            payment_method      VARCHAR(20)    NOT NULL,  -- Card / Apple Pay / Google Pay / SEPA Direct Debit
            response_code       VARCHAR(10)    NOT NULL,  -- e.g. 00 (approved), 51 (insufficient funds)
            response_text       VARCHAR(200)   NOT NULL,  -- one description per code (silver.response_codes)
            gateway_response_text VARCHAR(100) NOT NULL,  -- the gateway's own wording, title case
            status              VARCHAR(10)    NOT NULL,  -- Approved / Declined / Error
            txn_ts_utc          VARCHAR(19)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss, UTC
            settle_date         VARCHAR(10)    NOT NULL,  -- YYYY-MM-DD
            acquirer            VARCHAR(30)    NOT NULL,  -- Northgate Acquiring / Pacific Merchant Bank / EuroSettle Payments
            mid                 VARCHAR(20)    NOT NULL,  -- merchant account number at the acquirer
            three_ds            VARCHAR(3)     NOT NULL,  -- '1' = 3-D Secure used, '0' = not used
            device_type         VARCHAR(10)    NOT NULL,  -- Mobile / Desktop / Tablet
            ip_address          VARCHAR(45)    NOT NULL,  -- IPv4 or IPv6; PII
            ip_country          VARCHAR(3)     NOT NULL,  -- 2-letter code
            affiliate_id        VARCHAR(20)    NOT NULL,  -- AFF-0000
            network_txn_id      VARCHAR(30)    NOT NULL,  -- card network reference; 'N/A' for old gateway
            gateway_batch_id    VARCHAR(50)    NOT NULL,  -- gateway's own batch reference
            gateway_load_ts     VARCHAR(19)    NOT NULL,  -- when the gateway exported the row
            source_system       VARCHAR(50)    NOT NULL,
            source_file_name    NVARCHAR(260)  NOT NULL,
            batch_id            VARCHAR(36)    NOT NULL,
            bronze_ingested_at  VARCHAR(23)    NOT NULL,  -- YYYY-MM-DD hh:mm:ss.mmm
            ingested_by         NVARCHAR(128)  NOT NULL,
            silver_loaded_at    DATETIME2(0)   NOT NULL CONSTRAINT DF_silver_transactions_loaded DEFAULT SYSUTCDATETIME()
        );
    END

    -- Variables for the summary returned at the end
    DECLARE @Pre        INT,   -- rows in bronze.txn_pre_migration
            @Post       INT,   -- rows in bronze.txn_post_migration
            @Test       INT,   -- test transactions excluded
            @Loaded     INT,   -- rows written to silver
            @LoadedPre  INT,   -- of which old gateway
            @LoadedPost INT,   -- of which new gateway
            @MerchantNA INT,   -- old-gateway rows with no MRC- mapping
            @TsNA       INT,   -- rows with no usable timestamp
            @AmountNA   INT,   -- rows with no usable amount
            @UsdNA      INT,   -- rows with an amount but no USD value (no currency or no rate)
            @SiteNA     INT;   -- rows whose site_id is still not in silver.sites

    SELECT @Pre  = COUNT(*) FROM [SegPay].[bronze].[txn_pre_migration];
    SELECT @Post = COUNT(*) FROM [SegPay].[bronze].[txn_post_migration];

    -- Test sites (same rule as silver.usp_load_sites), as numbers for matching
    DECLARE @TestSites TABLE (site_id INT PRIMARY KEY);
    INSERT @TestSites (site_id)
    SELECT DISTINCT TRY_CAST(TRIM(site_id) AS INT)
    FROM [SegPay].[bronze].[sites]
    WHERE (UPPER(TRIM(category)) = 'TEST' OR UPPER(TRIM(merchant_id)) = 'MRC-99999')
      AND TRY_CAST(TRIM(site_id) AS INT) IS NOT NULL;

    /* -----------------------------------------------------------------
       US Treasury rates from silver.fx_rates_daily, as a date and a number,
       indexed by currency + date so each transaction's lookup is fast.
       (Silver holds one rate per currency per day, as USD per 1 unit.)
       ----------------------------------------------------------------- */
    CREATE TABLE #fx (
        currency      VARCHAR(3)     NOT NULL,
        rate_date     DATE           NOT NULL,
        usd_per_unit  DECIMAL(18,8)  NOT NULL,
        PRIMARY KEY (currency, rate_date)
    );
    INSERT #fx (currency, rate_date, usd_per_unit)
    SELECT currency, TRY_CAST(rate_date AS DATE), TRY_CAST(usd_per_unit AS DECIMAL(18,8))
    FROM [SegPay].[silver].[fx_rates_daily]
    WHERE TRY_CAST(rate_date AS DATE) IS NOT NULL
      AND TRY_CAST(usd_per_unit AS DECIMAL(18,8)) > 0;

    -- TRUNCATE and INSERT succeed or fail together
    BEGIN TRAN;

    TRUNCATE TABLE silver.transactions;

    /* -----------------------------------------------------------------
       CTE 1: src - both bronze tables lined up on the same column names.
       Old gateway: currency / auth_timestamp, no network_txn_id.
       New gateway: ccy / txn_ts_utc, with network_txn_id.
       ----------------------------------------------------------------- */
    WITH src AS (
        SELECT 'Pre-migration' AS migration_phase, 1 AS phase_rank,
               txn_id, purchase_id, parent_txn_id, merchant_id, site_id, package_id, customer_id,
               txn_type, amount, currency, card_brand, card_bin, card_last4, payment_method,
               response_code, response_text, status, auth_timestamp AS raw_ts, settle_date,
               acquirer, mid, three_ds, device_type, ip_address, ip_country, affiliate_id,
               is_test, CAST(NULL AS VARCHAR(1000)) AS network_txn_id, batch_id_source, load_ts,
               source_system, source_file_name, batch_id, ingested_at, ingested_by, bronze_id
        FROM [SegPay].[bronze].[txn_pre_migration]
        UNION ALL
        SELECT 'Post-migration', 2,
               txn_id, purchase_id, parent_txn_id, merchant_id, site_id, package_id, customer_id,
               txn_type, amount, ccy, card_brand, card_bin, card_last4, payment_method,
               response_code, response_text, status, txn_ts_utc, settle_date,
               acquirer, mid, three_ds, device_type, ip_address, ip_country, affiliate_id,
               is_test, network_txn_id, batch_id_source, load_ts,
               source_system, source_file_name, batch_id, ingested_at, ingested_by, bronze_id
        FROM [SegPay].[bronze].[txn_post_migration]
    ),

    /* -----------------------------------------------------------------
       CTE 2: s - every silver column, cleaned and typed.
       Missing values are NULL here; they become 'N/A' in the final insert.
       Test transactions are filtered out here.

       CROSS APPLY x : trimmed raw values and lookup keys, computed once.
       CROSS APPLY t : the timestamp parsed (still in the source time zone).
       CROSS APPLY a : the amount parsed (sign as sent).
       ----------------------------------------------------------------- */
    s AS (
        SELECT
            x.txn_id,
            b.migration_phase,
            b.phase_rank,
            TRY_CAST(TRIM(b.purchase_id) AS BIGINT)                AS purchase_id,
            NULLIF(TRY_CAST(TRIM(b.parent_txn_id) AS BIGINT), 0)   AS parent_txn_id,   -- 0 = none

            -- Merchant: new gateway sends MRC-; old gateway's number is mapped via merchant_xref
            CASE WHEN b.migration_phase = 'Post-migration'
                 THEN NULLIF(UPPER(TRIM(b.merchant_id)), '')
                 ELSE mx.merchant_id
            END                                                    AS merchant_id,
            CASE WHEN b.migration_phase = 'Pre-migration' THEN x.legacy_merchant_id END AS legacy_merchant_id,

            -- Site: as sent when it's a known site; otherwise the package's site
            CASE WHEN ks.site_id IS NULL AND pk.site_id IS NOT NULL
                 THEN TRY_CAST(pk.site_id AS INT)
                 ELSE x.site_id
            END                                                    AS site_id,

            x.package_id,
            NULLIF(UPPER(TRIM(b.customer_id)), '')                 AS customer_id,

            x.txn_type,

            -- Amount sign: Refund / Void / Chargeback negative, everything else positive
            CASE WHEN x.txn_type IN ('Refund', 'Void', 'Chargeback') THEN -ABS(a.amount)
                 ELSE ABS(a.amount)
            END                                                    AS amount,

            -- Currency: letters uppercased; numeric ISO 4217 codes mapped
            CASE x.ccy
                WHEN '840' THEN 'USD'
                WHEN '978' THEN 'EUR'
                WHEN '826' THEN 'GBP'
                WHEN '036' THEN 'AUD'
                WHEN '124' THEN 'CAD'
                ELSE CASE WHEN x.ccy LIKE '[A-Z][A-Z][A-Z]' THEN x.ccy END
            END                                                    AS currency,

            -- Card brand: same names as silver.bin_reference
            CASE x.brand
                WHEN 'VISA'             THEN 'Visa'
                WHEN 'VI'               THEN 'Visa'
                WHEN 'MASTERCARD'       THEN 'Mastercard'
                WHEN 'MC'               THEN 'Mastercard'
                WHEN 'AMEX'             THEN 'American Express'
                WHEN 'AX'               THEN 'American Express'
                WHEN 'AMERICAN EXPRESS' THEN 'American Express'
                WHEN 'UNIONPAY'         THEN 'UnionPay'
                WHEN 'UP'               THEN 'UnionPay'
                WHEN 'JCB'              THEN 'JCB'
            END                                                    AS card_brand,

            x.bin                                                  AS card_bin,
            LEFT(x.bin, 6)                                         AS card_bin6,
            CASE WHEN TRIM(b.card_last4) LIKE '[0-9][0-9][0-9][0-9]' THEN TRIM(b.card_last4) END AS card_last4,

            -- Payment method: compare on a key with spaces and '_' removed
            CASE x.pm_key
                WHEN 'CARD'            THEN 'Card'
                WHEN 'CC'              THEN 'Card'
                WHEN 'CREDITCARD'      THEN 'Card'
                WHEN 'APPLEPAY'        THEN 'Apple Pay'
                WHEN 'AP'              THEN 'Apple Pay'
                WHEN 'GOOGLEPAY'       THEN 'Google Pay'
                WHEN 'GPAY'            THEN 'Google Pay'
                WHEN 'SEPA'            THEN 'SEPA Direct Debit'
                WHEN 'SEPADD'          THEN 'SEPA Direct Debit'
                WHEN 'SEPADIRECTDEBIT' THEN 'SEPA Direct Debit'
            END                                                    AS payment_method,

            NULLIF(UPPER(TRIM(b.response_code)), '')               AS response_code,
            -- Response text: one description per code, from silver.response_codes.
            -- A code missing from the reference falls back to the gateway's text.
            COALESCE(rc.description, gt.gateway_response_text)   AS response_text,

            gt.gateway_response_text,

            CASE UPPER(TRIM(b.status))
                WHEN 'APPROVED' THEN 'Approved'
                WHEN 'APPR'     THEN 'Approved'
                WHEN 'A'        THEN 'Approved'
                WHEN 'DECLINED' THEN 'Declined'
                WHEN 'DECL'     THEN 'Declined'
                WHEN 'D'        THEN 'Declined'
                WHEN 'ERROR'    THEN 'Error'
            END                                                    AS status,

            -- Timestamp in UTC: old gateway is US Eastern time, new gateway already UTC.
            -- AT TIME ZONE applies the right offset for each date (EST -5 / EDT -4).
            CASE WHEN b.migration_phase = 'Pre-migration'
                 THEN CAST((t.ts AT TIME ZONE 'Eastern Standard Time') AT TIME ZONE 'UTC' AS DATETIME2(0))
                 ELSE t.ts
            END                                                    AS txn_ts_utc,

            -- Settle date: YYYYMMDD or MM/DD/YYYY
            CASE
                WHEN x.sd LIKE '[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'  THEN TRY_CONVERT(DATE, x.sd, 112)
                WHEN x.sd LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, x.sd, 101)
            END                                                    AS settle_date,

            -- Acquirer: compare on a key with spaces removed
            CASE
                WHEN x.acq_key IN ('NORTHGATEACQUIRING', 'NORTHGATE', 'NGACQ')               THEN 'Northgate Acquiring'
                WHEN x.acq_key IN ('PACIFICMERCHANTBANK', 'PACIFICMERCHBANK', 'PACMB')       THEN 'Pacific Merchant Bank'
                WHEN x.acq_key IN ('EUROSETTLEPAYMENTS', 'EUROSETTLE')                       THEN 'EuroSettle Payments'
            END                                                    AS acquirer,

            TRY_CAST(TRIM(b.mid) AS BIGINT)                        AS mid,

            -- 3-D Secure used: 1 / 0
            CASE UPPER(TRIM(b.three_ds))
                WHEN 'Y' THEN '1' WHEN 'TRUE'  THEN '1' WHEN '1' THEN '1'
                WHEN 'N' THEN '0' WHEN 'FALSE' THEN '0' WHEN '0' THEN '0'
            END                                                    AS three_ds,

            CASE UPPER(TRIM(b.device_type))
                WHEN 'MOBILE'  THEN 'Mobile'
                WHEN 'M'       THEN 'Mobile'
                WHEN 'DESKTOP' THEN 'Desktop'
                WHEN 'D'       THEN 'Desktop'
                WHEN 'PC'      THEN 'Desktop'
                WHEN 'TABLET'  THEN 'Tablet'
                WHEN 'T'       THEN 'Tablet'
            END                                                    AS device_type,

            NULLIF(LOWER(TRIM(b.ip_address)), '')                  AS ip_address,

            -- IP country: 2 letters; 'XX' means unknown
            CASE WHEN x.ipc LIKE '[A-Z][A-Z]' AND x.ipc <> 'XX' THEN x.ipc END AS ip_country,

            -- Affiliate: AFF-0000; old gateway sometimes sends just the number (9 -> AFF-0009)
            CASE
                WHEN x.aff LIKE 'AFF-[0-9][0-9][0-9][0-9]' THEN x.aff
                WHEN TRY_CAST(x.aff AS INT) IS NOT NULL
                    THEN 'AFF-' + RIGHT('0000' + CONVERT(VARCHAR(10), TRY_CAST(x.aff AS INT)), 4)
            END                                                    AS affiliate_id,

            NULLIF(TRIM(b.network_txn_id), '')                     AS network_txn_id,
            NULLIF(TRIM(b.batch_id_source), '')                    AS gateway_batch_id,
            TRY_CONVERT(DATETIME2(0), NULLIF(TRIM(b.load_ts), ''), 120) AS gateway_load_ts,

            -- Lineage
            b.source_system,
            b.source_file_name,
            b.batch_id,
            b.ingested_at                                          AS bronze_ingested_at,
            b.ingested_by,
            b.bronze_id
        FROM src b
        CROSS APPLY (
            SELECT
                txn_id             = TRY_CAST(TRIM(b.txn_id) AS BIGINT),
                site_id            = TRY_CAST(TRIM(b.site_id) AS INT),
                package_id         = TRY_CAST(TRIM(b.package_id) AS INT),
                merchant_key       = UPPER(TRIM(b.merchant_id)),
                legacy_merchant_id = TRY_CAST(TRIM(b.merchant_id) AS INT),
                txn_type           = CASE UPPER(TRIM(b.txn_type))
                                         WHEN 'SALE'       THEN 'Sale'
                                         WHEN 'S'          THEN 'Sale'
                                         WHEN 'REBILL'     THEN 'Rebill'
                                         WHEN 'RB'         THEN 'Rebill'
                                         WHEN 'R'          THEN 'Rebill'
                                         WHEN 'AUTH'       THEN 'Auth'
                                         WHEN 'ZERO_AUTH'  THEN 'Zero Auth'
                                         WHEN 'REFUND'     THEN 'Refund'
                                         WHEN 'RFND'       THEN 'Refund'
                                         WHEN 'RF'         THEN 'Refund'
                                         WHEN 'VOID'       THEN 'Void'
                                         WHEN 'VD'         THEN 'Void'
                                         WHEN 'CHARGEBACK' THEN 'Chargeback'
                                         WHEN 'CB'         THEN 'Chargeback'
                                     END,
                ccy                = UPPER(TRIM(b.currency)),
                brand              = UPPER(TRIM(b.card_brand)),
                bin                = CASE WHEN TRIM(b.card_bin) NOT LIKE '%[^0-9]%' AND LEN(TRIM(b.card_bin)) >= 6
                                          THEN TRIM(b.card_bin) END,
                pm_key             = UPPER(REPLACE(REPLACE(TRIM(b.payment_method), ' ', ''), '_', '')),
                acq_key            = UPPER(REPLACE(TRIM(b.acquirer), ' ', '')),
                sd                 = NULLIF(TRIM(b.settle_date), ''),
                ipc                = UPPER(TRIM(b.ip_country)),
                aff                = NULLIF(UPPER(TRIM(b.affiliate_id)), ''),
                ts                 = NULLIF(TRIM(b.raw_ts), ''),
                -- amount text: '$' and spaces removed; '(0.99)' -> '-0.99'; decimal comma -> point
                amt                = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(TRIM(b.amount), '$', ''), ' ', ''),
                                         '(', '-'), ')', ''), ',', '.')
        ) x
        CROSS APPLY (
            SELECT ts = CASE
                WHEN x.ts LIKE '[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9][ T][0-2][0-9]:[0-5][0-9]:[0-5][0-9]%'
                    THEN TRY_CONVERT(DATETIME2(0), REPLACE(LEFT(x.ts, 19), 'T', ' '), 120)   -- 2026-03-26T10:38:12Z, 2024-10-01 04:42:43, ...+00:00, ...123Z
                WHEN x.ts LIKE '[01][0-9]/[0-3][0-9]/[12][0-9][0-9][0-9] [0-1][0-9]:[0-5][0-9]:[0-5][0-9] [AP]M'
                    THEN TRY_CONVERT(DATETIME2(0), x.ts, 101)                                   -- 10/01/2024 07:27:06 AM
                WHEN x.ts LIKE '[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9] [0-2][0-9]:[0-5][0-9]:[0-5][0-9]'
                    THEN TRY_CONVERT(DATETIME2(0), REPLACE(x.ts, '-', ' '), 113)               -- 03-OCT-2024 12:14:57
                WHEN x.ts NOT LIKE '%[^0-9]%' AND LEN(x.ts) = 10
                    THEN DATEADD(SECOND, CAST(x.ts AS INT), CAST('1970-01-01' AS DATETIME2(0)))  -- 1772329760 (Unix epoch, UTC)
            END
        ) t
        CROSS APPLY (SELECT amount = TRY_CAST(x.amt AS DECIMAL(18,2))) a
        -- Gateway's own response wording, title case like status ('DO NOT HONOR' -> 'Do Not Honor').
        -- Listed explicitly so abbreviations stay uppercase (NSF, CVV, CVV2, OK).
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
                -- Any new text: capitalize the first letter, lowercase the rest
                ELSE NULLIF(UPPER(LEFT(TRIM(b.response_text), 1))
                            + LOWER(SUBSTRING(TRIM(b.response_text), 2, 100)), '')
            END
        ) gt
        -- One description per response code
        LEFT JOIN silver.response_codes rc
               ON rc.response_code = NULLIF(UPPER(TRIM(b.response_code)), '')
              AND rc.description <> 'N/A'
        LEFT JOIN silver.merchant_xref mx
               ON b.migration_phase = 'Pre-migration'
              AND mx.legacy_merchant_id = CONVERT(VARCHAR(20), x.legacy_merchant_id)
        -- Is the site_id a known site? If not, the package's site is used instead.
        LEFT JOIN silver.sites ks
               ON ks.site_id = CONVERT(VARCHAR(20), x.site_id)
        LEFT JOIN silver.packages pk
               ON pk.package_id = CONVERT(VARCHAR(20), x.package_id)
              AND pk.site_id <> 'N/A'
        -- Exclude test transactions: flagged by the gateway, the test merchant,
        -- or made on a test site
        WHERE ISNULL(UPPER(TRIM(b.is_test)), '') NOT IN ('TRUE', 'T', 'Y', '1')
          AND ISNULL(x.merchant_key, '') NOT IN ('MRC-99999', '9999')
          AND NOT EXISTS (SELECT 1 FROM @TestSites ts WHERE ts.site_id = x.site_id)
    ),

    /* -----------------------------------------------------------------
       CTE 3: dedup - one row per txn_id.
       Keep the new-gateway copy, then the latest gateway export, then the
       newest bronze load.
       ----------------------------------------------------------------- */
    dedup AS (
        SELECT *,
               ROW_NUMBER() OVER (
                   PARTITION BY txn_id
                   ORDER BY phase_rank DESC,           -- new gateway first
                            gateway_load_ts DESC,      -- then the latest gateway export
                            bronze_ingested_at DESC,   -- then the newest bronze load
                            bronze_id DESC             -- then the last row loaded
               ) AS rn
        FROM s
        WHERE txn_id IS NOT NULL                       -- can't key a row with no txn ID
    )

    /* -----------------------------------------------------------------
       Write the cleaned rows into silver.
       Every value is converted to text and NULL is replaced with 'N/A'.
       Column list and SELECT must stay in the same order (INSERT is by position).
       ----------------------------------------------------------------- */
    INSERT silver.transactions (
        txn_id, migration_phase, purchase_id, parent_txn_id, merchant_id, legacy_merchant_id,
        site_id, package_id, customer_id, txn_type, amount, currency,
        amount_usd, fx_rate, fx_rate_date, card_brand, card_bin,
        card_bin6, card_last4, payment_method, response_code, response_text,
        gateway_response_text, status,
        txn_ts_utc, settle_date, acquirer, mid, three_ds, device_type, ip_address, ip_country,
        affiliate_id, network_txn_id, gateway_batch_id, gateway_load_ts, source_system,
        source_file_name, batch_id, bronze_ingested_at, ingested_by)
    SELECT
        CONVERT(VARCHAR(20), txn_id),                                  -- never NULL (filtered above)
        migration_phase,
        COALESCE(CONVERT(VARCHAR(20), purchase_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), parent_txn_id), 'N/A'),
        COALESCE(merchant_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), legacy_merchant_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), site_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), package_id), 'N/A'),
        COALESCE(customer_id, 'N/A'),
        COALESCE(txn_type, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), amount), 'N/A'),
        COALESCE(currency, 'N/A'),
        -- USD amount: USD unchanged; other currencies * US Treasury rate; no rate -> 'N/A'
        COALESCE(CONVERT(VARCHAR(20),
            CASE WHEN currency = 'USD' THEN amount
                 ELSE CAST(ROUND(amount * r.usd_per_unit, 2) AS DECIMAL(18,2))
            END), 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), r.usd_per_unit), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), r.rate_date, 23), 'N/A'),
        COALESCE(card_brand, 'N/A'),
        COALESCE(card_bin, 'N/A'),
        COALESCE(card_bin6, 'N/A'),
        COALESCE(card_last4, 'N/A'),
        COALESCE(payment_method, 'N/A'),
        COALESCE(response_code, 'N/A'),
        COALESCE(response_text, 'N/A'),
        COALESCE(gateway_response_text, 'N/A'),
        COALESCE(status, 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), txn_ts_utc, 120), 'N/A'),
        COALESCE(CONVERT(VARCHAR(10), settle_date, 23), 'N/A'),
        COALESCE(acquirer, 'N/A'),
        COALESCE(CONVERT(VARCHAR(20), mid), 'N/A'),
        COALESCE(three_ds, 'N/A'),
        COALESCE(device_type, 'N/A'),
        COALESCE(ip_address, 'N/A'),
        COALESCE(ip_country, 'N/A'),
        COALESCE(affiliate_id, 'N/A'),
        COALESCE(network_txn_id, 'N/A'),
        COALESCE(gateway_batch_id, 'N/A'),
        COALESCE(CONVERT(VARCHAR(19), gateway_load_ts, 120), 'N/A'),
        COALESCE(source_system, 'N/A'),
        COALESCE(source_file_name, 'N/A'),
        COALESCE(CONVERT(VARCHAR(36), batch_id), 'N/A'),
        COALESCE(CONVERT(VARCHAR(23), bronze_ingested_at, 121), 'N/A'),
        COALESCE(ingested_by, 'N/A')
    FROM dedup d
    -- Most recent US Treasury rate for the currency on or before the transaction's
    -- UTC date; skipped for USD. OUTER APPLY keeps the transaction when no rate is found.
    OUTER APPLY (
        SELECT TOP (1) f.usd_per_unit, f.rate_date
        FROM #fx f
        WHERE d.currency <> 'USD'
          AND f.currency  = d.currency
          AND f.rate_date <= CAST(d.txn_ts_utc AS DATE)
        ORDER BY f.rate_date DESC
    ) r
    WHERE d.rn = 1;

    -- Read immediately, before another statement resets it
    SET @Loaded = @@ROWCOUNT;

    COMMIT;

    -- Test rows excluded = bronze rows with a test flag, the test merchant, or on a test site
    SELECT @Test = COUNT(*)
    FROM (SELECT is_test, site_id, merchant_id FROM [SegPay].[bronze].[txn_pre_migration]
          UNION ALL
          SELECT is_test, site_id, merchant_id FROM [SegPay].[bronze].[txn_post_migration]) b
    WHERE ISNULL(UPPER(TRIM(b.is_test)), '') IN ('TRUE', 'T', 'Y', '1')
       OR ISNULL(UPPER(TRIM(b.merchant_id)), '') IN ('MRC-99999', '9999')
       OR EXISTS (SELECT 1 FROM @TestSites ts WHERE ts.site_id = TRY_CAST(TRIM(b.site_id) AS INT));

    -- Data-quality counts for the summary
    SELECT @LoadedPre  = SUM(CASE WHEN migration_phase = 'Pre-migration'  THEN 1 ELSE 0 END),
           @LoadedPost = SUM(CASE WHEN migration_phase = 'Post-migration' THEN 1 ELSE 0 END),
           @MerchantNA = SUM(CASE WHEN merchant_id = 'N/A' THEN 1 ELSE 0 END),
           @TsNA       = SUM(CASE WHEN txn_ts_utc  = 'N/A' THEN 1 ELSE 0 END),
           @AmountNA   = SUM(CASE WHEN amount      = 'N/A' THEN 1 ELSE 0 END),
           @UsdNA      = SUM(CASE WHEN amount <> 'N/A' AND amount_usd = 'N/A' THEN 1 ELSE 0 END)
    FROM silver.transactions;

    -- Counted separately: SUM can't contain a subquery
    SELECT @SiteNA = COUNT(*)
    FROM silver.transactions t
    WHERE NOT EXISTS (SELECT 1 FROM silver.sites s WHERE s.site_id = t.site_id);

    -- One-row summary of the load
    SELECT PreMigrationRows        = @Pre,                          -- rows read from the old-gateway table
           PostMigrationRows       = @Post,                         -- rows read from the new-gateway table
           TestRowsExcluded        = @Test,                         -- test transactions removed
           SilverRows              = @Loaded,                       -- transactions loaded (one row each)
           SilverPreMigration      = @LoadedPre,                    --   of which old gateway
           SilverPostMigration     = @LoadedPost,                   --   of which new gateway
           DuplicatesDropped       = @Pre + @Post - @Test - @Loaded, -- repeated txn_ids removed (incl. 39 re-sent across gateways)
           MerchantNotAvailable    = @MerchantNA,                   -- old-gateway merchant with no MRC- mapping
           TimestampNotAvailable   = @TsNA,                         -- missing or unreadable timestamp
           AmountNotAvailable      = @AmountNA,                     -- missing or unreadable amount
           AmountUsdNotAvailable   = @UsdNA,                        -- amount known but no currency or no FX rate
           SiteNotInSilverSites    = @SiteNA;                       -- site_id still unknown after package recovery
END

