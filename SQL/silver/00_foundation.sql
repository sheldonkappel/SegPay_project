/* =====================================================================
   Script    : 00_foundation.sql
   Purpose   : Shared objects used by the silver load procedures.
               Run once before 01_silver_tables.sql; safe to re-run.

   Schemas
   -------
     util  - reusable parsing functions (dates, amounts, flags), so every
             procedure cleans these values the same way.
     ref   - small reference / mapping tables maintained by hand
             (country names, card brands, acquirers, test merchants).
     audit - load_log: one row per procedure run, written by every load.

   Why shared objects
   ------------------
   Before this, each procedure had its own copy of the date parsing and the
   country / card brand / acquirer mappings. The copies drifted apart (one
   missed 'Mon DD, YYYY', one read slash dates day-first), which caused
   wrong or missing values. Fixing a rule here now fixes it everywhere.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   Schemas
   --------------------------------------------------------------------- */
IF SCHEMA_ID(N'util')  IS NULL EXEC (N'CREATE SCHEMA util');
IF SCHEMA_ID(N'ref')   IS NULL EXEC (N'CREATE SCHEMA ref');
IF SCHEMA_ID(N'audit') IS NULL EXEC (N'CREATE SCHEMA audit');
GO

/* =====================================================================
   util.fn_parse_date
   ---------------------------------------------------------------------
   Reads a date written in any of the formats found in the source files
   and returns three candidate readings:

     fixed_date    : formats with only one possible reading
                       2024-09-30 (time part ignored), 20240930,
                       30-Sep-24, 30-Sep-2024, 30 Sep 2024,
                       Sep 30, 2024, 30-09-2024 (DD-MM-YYYY)
     us_date       : a slash date read as MM/DD/YYYY
     dm_date       : a slash date read as DD/MM/YYYY
     date_us_first : fixed_date, else us_date, else dm_date - the default
                     reading (US month/day first, day-first only when the
                     US reading is impossible, e.g. 18/07/2023)

   A slash date that is valid both ways (05/12/2025) has us_date <> dm_date.
   Procedures that have another date to check against (e.g. a purchase's
   first transaction) use that to choose; otherwise they use date_us_first.
   'N/A', 'NULL', '-' and blanks return all NULLs.

   Inline table-valued function: SQL Server expands it into the calling
   query, so it is as fast as writing the expressions in place.

   Usage:  SELECT d.date_us_first
           FROM bronze.x b
           CROSS APPLY util.fn_parse_date(b.some_date) d;
   ===================================================================== */
CREATE OR ALTER FUNCTION util.fn_parse_date (@value NVARCHAR(100))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT
        p.fixed_date,
        p.us_date,
        p.dm_date,
        COALESCE(p.fixed_date, p.us_date, p.dm_date) AS date_us_first
    FROM (
        -- Trimmed text; the usual "no value" placeholders become NULL
        SELECT t = CASE WHEN UPPER(TRIM(@value)) IN (N'', N'N/A', N'NA', N'NULL', N'-')
                        THEN NULL ELSE TRIM(@value) END
    ) v
    CROSS APPLY (
        SELECT
            fixed_date = CASE
                WHEN v.t LIKE N'[12][0-9][0-9][0-9]-[01][0-9]-[0-3][0-9]%'          THEN TRY_CONVERT(DATE, LEFT(v.t, 10), 23)          -- 2024-09-30
                WHEN v.t LIKE N'[12][0-9][0-9][0-9][01][0-9][0-3][0-9]'             THEN TRY_CONVERT(DATE, v.t, 112)                   -- 20240930
                WHEN v.t LIKE N'[0-3][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9]'              THEN TRY_CONVERT(DATE, REPLACE(v.t, N'-', N' '), 6)  -- 30-Sep-24
                WHEN v.t LIKE N'[0-3][0-9]-[A-Z][A-Z][A-Z]-[12][0-9][0-9][0-9]'     THEN TRY_CONVERT(DATE, REPLACE(v.t, N'-', N' '), 106)-- 30-Sep-2024
                WHEN v.t LIKE N'[0-3][0-9] [A-Z][A-Z][A-Z] [12][0-9][0-9][0-9]'     THEN TRY_CONVERT(DATE, v.t, 106)                   -- 30 Sep 2024
                WHEN v.t LIKE N'[A-Z][A-Z][A-Z] [0-3][0-9], [12][0-9][0-9][0-9]'    THEN TRY_CONVERT(DATE, v.t, 107)                   -- Sep 30, 2024
                WHEN v.t LIKE N'[0-3][0-9]-[01][0-9]-[12][0-9][0-9][0-9]'           THEN TRY_CONVERT(DATE, v.t, 105)                   -- 30-09-2024
            END,
            us_date = CASE WHEN v.t LIKE N'[0-9]%/%[0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, v.t, 101) END,  -- MM/DD/YYYY
            dm_date = CASE WHEN v.t LIKE N'[0-9]%/%[0-9]/[12][0-9][0-9][0-9]' THEN TRY_CONVERT(DATE, v.t, 103) END   -- DD/MM/YYYY
    ) p;
GO

/* =====================================================================
   util.fn_parse_amount
   ---------------------------------------------------------------------
   Reads a money amount written as text and returns it as a number.
     * '$' and spaces removed
     * '(0.99)' read as negative (accounting style)
     * Comma: a decimal comma when it is the only separator and is followed
       by exactly two digits ('9,00' -> 9.00, '4,43' -> 4.43); otherwise a
       thousands separator ('1,671.14' -> 1671.14, '1,000' -> 1000)
   Returns NULL for anything that is not a number.

   Usage:  CROSS APPLY util.fn_parse_amount(b.amount) a   -- a.amount
   ===================================================================== */
CREATE OR ALTER FUNCTION util.fn_parse_amount (@value NVARCHAR(100))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT amount = TRY_CAST(
               CASE WHEN c.t LIKE N'%,%' AND c.t NOT LIKE N'%.%' AND c.t LIKE N'%,[0-9][0-9]'
                    THEN REPLACE(c.t, N',', N'.')        -- decimal comma
                    ELSE REPLACE(c.t, N',', N'')         -- thousands separator
               END AS DECIMAL(19,4))
    FROM (
        -- '$' and spaces removed; '(x)' -> '-x'
        SELECT t = CASE WHEN s.t LIKE N'(%)' THEN N'-' + SUBSTRING(s.t, 2, LEN(s.t) - 2) ELSE s.t END
        FROM (SELECT t = NULLIF(REPLACE(REPLACE(TRIM(@value), N'$', N''), N' ', N''), N'')) s
    ) c;
GO

/* =====================================================================
   util.fn_parse_flag
   ---------------------------------------------------------------------
   Reads a yes/no value and returns a BIT:
     1 : TRUE, T, Y, YES, 1
     0 : FALSE, F, N, NO, 0
     NULL : anything else (missing or unrecognized)

   Usage:  CROSS APPLY util.fn_parse_flag(b.is_test) f   -- f.flag
   ===================================================================== */
CREATE OR ALTER FUNCTION util.fn_parse_flag (@value NVARCHAR(50))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT flag = CAST(CASE UPPER(TRIM(@value))
                           WHEN N'TRUE' THEN 1 WHEN N'T' THEN 1 WHEN N'Y' THEN 1 WHEN N'YES' THEN 1 WHEN N'1' THEN 1
                           WHEN N'FALSE' THEN 0 WHEN N'F' THEN 0 WHEN N'N' THEN 0 WHEN N'NO' THEN 0 WHEN N'0' THEN 0
                       END AS BIT);
GO

/* =====================================================================
   util.fn_clean_text
   ---------------------------------------------------------------------
   Trims a text value and turns the placeholders source systems use for
   "no value" into NULL: '', 'N/A', 'NA', 'NULL', 'NONE', '-' (any casing).
   Example: the CRM export writes the literal text 'N/A' as an email.

   Usage:  CROSS APPLY util.fn_clean_text(b.contact_email) e   -- e.txt
   ===================================================================== */
CREATE OR ALTER FUNCTION util.fn_clean_text (@value NVARCHAR(4000))
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT txt = CASE WHEN UPPER(TRIM(@value)) IN (N'', N'N/A', N'NA', N'NULL', N'NONE', N'-')
                      THEN NULL ELSE TRIM(@value) END;
GO

/* =====================================================================
   ref.country_alias
   ---------------------------------------------------------------------
   Country names and 3-letter codes found in the source files, mapped to
   2-letter ISO codes. Look up with UPPER(TRIM(value)) with '.' removed
   ('U.S.A.' -> 'USA'). Values already 2 letters are used as they are.
   Add a row here when a new spelling appears.
   ===================================================================== */
IF OBJECT_ID(N'ref.country_alias', N'U') IS NULL
    CREATE TABLE ref.country_alias (
        alias         VARCHAR(60)  NOT NULL CONSTRAINT PK_ref_country_alias PRIMARY KEY,  -- uppercase, no dots
        country_code  CHAR(2)      NOT NULL                                              -- ISO 3166-1 alpha-2
    );
GO
MERGE ref.country_alias AS t
USING (VALUES
    ('AUS','AU'), ('AUSTRALIA','AU'),
    ('BRA','BR'), ('BRAZIL','BR'),
    ('CAN','CA'), ('CANADA','CA'),
    ('CYP','CY'), ('CYPRUS','CY'),
    ('CZE','CZ'), ('CZECHIA','CZ'), ('CZECH REPUBLIC','CZ'),
    ('DEU','DE'), ('GERMANY','DE'), ('DEUTSCHLAND','DE'),
    ('ESP','ES'), ('SPAIN','ES'),
    ('FRA','FR'), ('FRANCE','FR'),
    ('GBR','GB'), ('UK','GB'), ('UNITED KINGDOM','GB'), ('GREAT BRITAIN','GB'),
    ('HKG','HK'), ('HONG KONG','HK'),
    ('IRL','IE'), ('IRELAND','IE'),
    ('IND','IN'), ('INDIA','IN'),
    ('ITA','IT'), ('ITALY','IT'),
    ('JPN','JP'), ('JAPAN','JP'),
    ('MEX','MX'), ('MEXICO','MX'),
    ('MLT','MT'), ('MALTA','MT'),
    ('NLD','NL'), ('NETHERLANDS','NL'), ('THE NETHERLANDS','NL'), ('HOLLAND','NL'),
    ('NOR','NO'), ('NORWAY','NO'),
    ('POL','PL'), ('POLAND','PL'),
    ('SWE','SE'), ('SWEDEN','SE'),
    ('ZAF','ZA'), ('SOUTH AFRICA','ZA'),
    ('USA','US'), ('UNITED STATES','US'), ('UNITED STATES OF AMERICA','US')
) AS s (alias, country_code)
ON t.alias = s.alias
WHEN MATCHED AND t.country_code <> s.country_code THEN UPDATE SET country_code = s.country_code
WHEN NOT MATCHED THEN INSERT (alias, country_code) VALUES (s.alias, s.country_code);
GO

/* =====================================================================
   ref.card_brand_alias
   ---------------------------------------------------------------------
   Card brand / network spellings mapped to one name. Used for card_brand
   (bin_reference, transactions) and network (chargebacks, reason codes).
   Look up with UPPER(TRIM(value)).
   ===================================================================== */
IF OBJECT_ID(N'ref.card_brand_alias', N'U') IS NULL
    CREATE TABLE ref.card_brand_alias (
        alias       VARCHAR(30)  NOT NULL CONSTRAINT PK_ref_card_brand_alias PRIMARY KEY,  -- uppercase
        card_brand  VARCHAR(20)  NOT NULL
    );
GO
MERGE ref.card_brand_alias AS t
USING (VALUES
    ('VISA','Visa'), ('VI','Visa'),
    ('MASTERCARD','Mastercard'), ('MC','Mastercard'),
    ('AMEX','American Express'), ('AX','American Express'), ('AMERICAN EXPRESS','American Express'),
    ('DISCOVER','Discover'), ('DISC','Discover'),
    ('UNIONPAY','UnionPay'), ('UP','UnionPay'),
    ('JCB','JCB')
) AS s (alias, card_brand)
ON t.alias = s.alias
WHEN MATCHED AND t.card_brand <> s.card_brand THEN UPDATE SET card_brand = s.card_brand
WHEN NOT MATCHED THEN INSERT (alias, card_brand) VALUES (s.alias, s.card_brand);
GO

/* =====================================================================
   ref.acquirer_alias
   ---------------------------------------------------------------------
   Acquirer spellings mapped to one name. Look up with
   UPPER(REPLACE(TRIM(value), ' ', '')) - spaces removed, so
   'NG ACQ' and 'NGACQ' match the same row.
   ===================================================================== */
IF OBJECT_ID(N'ref.acquirer_alias', N'U') IS NULL
    CREATE TABLE ref.acquirer_alias (
        alias     VARCHAR(50)  NOT NULL CONSTRAINT PK_ref_acquirer_alias PRIMARY KEY,  -- uppercase, no spaces
        acquirer  VARCHAR(50)  NOT NULL
    );
GO
MERGE ref.acquirer_alias AS t
USING (VALUES
    ('NORTHGATEACQUIRING','Northgate Acquiring'), ('NORTHGATE','Northgate Acquiring'), ('NGACQ','Northgate Acquiring'),
    ('PACIFICMERCHANTBANK','Pacific Merchant Bank'), ('PACIFICMERCHBANK','Pacific Merchant Bank'), ('PACMB','Pacific Merchant Bank'),
    ('EUROSETTLEPAYMENTS','EuroSettle Payments'), ('EUROSETTLE','EuroSettle Payments')
) AS s (alias, acquirer)
ON t.alias = s.alias
WHEN MATCHED AND t.acquirer <> s.acquirer THEN UPDATE SET acquirer = s.acquirer
WHEN NOT MATCHED THEN INSERT (alias, acquirer) VALUES (s.alias, s.acquirer);
GO

/* =====================================================================
   ref.test_merchant
   ---------------------------------------------------------------------
   Merchants used for testing. Their sites, packages, purchases,
   transactions, settlements etc. are excluded from silver.
   ===================================================================== */
IF OBJECT_ID(N'ref.test_merchant', N'U') IS NULL
    CREATE TABLE ref.test_merchant (
        merchant_id         VARCHAR(20)    NOT NULL CONSTRAINT PK_ref_test_merchant PRIMARY KEY,  -- new gateway ID
        legacy_merchant_id  INT            NULL,                                                 -- old gateway ID
        description         NVARCHAR(200)  NULL
    );
GO
MERGE ref.test_merchant AS t
USING (VALUES ('MRC-99999', 9999, N'QA sandbox merchant (sites 4001 / 4002)')) AS s (merchant_id, legacy_merchant_id, description)
ON t.merchant_id = s.merchant_id
WHEN MATCHED THEN UPDATE SET legacy_merchant_id = s.legacy_merchant_id, description = s.description
WHEN NOT MATCHED THEN INSERT (merchant_id, legacy_merchant_id, description) VALUES (s.merchant_id, s.legacy_merchant_id, s.description);
GO

/* =====================================================================
   ref.v_test_site
   ---------------------------------------------------------------------
   Test sites: category 'Test' in the sites file, or owned by a test
   merchant. Read from bronze so it works before silver.sites is loaded.
   ===================================================================== */
CREATE OR ALTER VIEW ref.v_test_site
AS
    SELECT DISTINCT TRY_CAST(TRIM(s.site_id) AS INT) AS site_id
    FROM bronze.sites s
    WHERE TRY_CAST(TRIM(s.site_id) AS INT) IS NOT NULL
      AND (   UPPER(TRIM(s.category)) = 'TEST'
           OR UPPER(TRIM(s.merchant_id)) IN (SELECT merchant_id FROM ref.test_merchant));
GO

/* =====================================================================
   audit.load_log
   ---------------------------------------------------------------------
   One row per load procedure run. run_id groups the steps of one
   silver.usp_load_all run. metrics holds the procedure's summary row as
   JSON (e.g. {"SilverRows":229389,"TestRowsExcluded":637,...}).
   ===================================================================== */
IF OBJECT_ID(N'audit.load_log', N'U') IS NULL
    CREATE TABLE audit.load_log (
        log_id          BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_audit_load_log PRIMARY KEY,
        run_id          UNIQUEIDENTIFIER NULL,          -- same for all steps of one usp_load_all run
        proc_name       SYSNAME          NOT NULL,      -- e.g. silver.usp_load_transactions
        target_table    SYSNAME          NULL,          -- e.g. silver.transactions
        started_at      DATETIME2(3)     NOT NULL,      -- UTC
        ended_at        DATETIME2(3)     NOT NULL,      -- UTC
        duration_ms     INT              NOT NULL,
        status          VARCHAR(10)      NOT NULL,      -- Succeeded / Failed
        rows_read       INT              NULL,          -- rows in the bronze source
        rows_loaded     INT              NULL,          -- rows written to silver
        rows_excluded   INT              NULL,          -- test data removed
        rows_dropped    INT              NULL,          -- duplicates / superseded versions / unkeyable rows
        metrics         NVARCHAR(MAX)    NULL,          -- full summary as JSON
        error_message   NVARCHAR(4000)   NULL,
        logged_by       NVARCHAR(128)    NOT NULL CONSTRAINT DF_audit_load_log_by DEFAULT SUSER_SNAME()
    );
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_audit_load_log_proc_started' AND object_id = OBJECT_ID(N'audit.load_log'))
    CREATE INDEX IX_audit_load_log_proc_started ON audit.load_log (proc_name, started_at DESC);
GO

/* =====================================================================
   audit.usp_log_load
   ---------------------------------------------------------------------
   Writes one row to audit.load_log. Called at the end of every silver
   load procedure (on success and on failure).
   ===================================================================== */
CREATE OR ALTER PROCEDURE audit.usp_log_load
    @run_id         UNIQUEIDENTIFIER = NULL,
    @proc_name      SYSNAME,
    @target_table   SYSNAME          = NULL,
    @started_at     DATETIME2(3),
    @status         VARCHAR(10),
    @rows_read      INT              = NULL,
    @rows_loaded    INT              = NULL,
    @rows_excluded  INT              = NULL,
    @rows_dropped   INT              = NULL,
    @metrics        NVARCHAR(MAX)    = NULL,
    @error_message  NVARCHAR(4000)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ended_at DATETIME2(3) = SYSUTCDATETIME();

    INSERT audit.load_log (run_id, proc_name, target_table, started_at, ended_at, duration_ms, status,
                           rows_read, rows_loaded, rows_excluded, rows_dropped, metrics, error_message)
    VALUES (@run_id, @proc_name, @target_table, @started_at, @ended_at,
            DATEDIFF(MILLISECOND, @started_at, @ended_at), @status,
            @rows_read, @rows_loaded, @rows_excluded, @rows_dropped, @metrics, @error_message);
END
GO
