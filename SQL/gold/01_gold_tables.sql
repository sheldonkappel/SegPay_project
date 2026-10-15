/* =====================================================================
   Script    : 01_gold_tables.sql
   Purpose   : Creates the gold star schema: dimensions and facts.

   Safe to re-run: every table is created only if it does not exist.
   Dimensions are never dropped because their surrogate keys must stay
   stable (a merchant keeps the same merchant_key run after run, and
   dim_merchant keeps its change history). To change a gold table's
   structure, write a migration script, as for bronze.

   Conventions
   -----------
   * Surrogate keys: <name>_key INT IDENTITY. Facts join to dimensions on
     these keys, never on the source IDs.
   * Unknown member: every dimension has a row with key -1 ('Unknown') so a
     fact whose reference is missing still appears in reports instead of
     dropping out of an inner join.
   * Dimensions are updated in place by MERGE (new rows inserted, changed
     rows updated, rows gone from the source flagged is_deleted = 1 -
     never deleted, because facts may still point at them).
   * dim_merchant keeps history (slowly changing dimension type 2): a
     change to status, risk tier, vertical, MCC or pricing closes the
     current version (valid_to) and opens a new one (valid_from).
   * Facts are rebuilt from silver on every run and stored as clustered
     columnstore indexes - compressed column storage built for scans and
     aggregations.
   * All amounts in USD (amount_usd); the original amount and currency are
     kept alongside.
   * Personal data stays in silver: no emails, IPs or postal codes in gold.

   Requires 00_gold_foundation.sql.
   ===================================================================== */
SET NOCOUNT ON;
GO

/* =====================================================================
   DIMENSIONS
   ===================================================================== */

IF OBJECT_ID(N'gold.dim_date', N'U') IS NULL
CREATE TABLE gold.dim_date (
    date_key            INT          NOT NULL CONSTRAINT PK_gold_dim_date PRIMARY KEY,  -- YYYYMMDD; -1 = Unknown
    full_date           DATE         NULL,
    year                SMALLINT     NULL,
    quarter             TINYINT      NULL,
    quarter_name        CHAR(7)      NULL,   -- 2026 Q1
    month               TINYINT      NULL,
    month_name          VARCHAR(10)  NULL,   -- March
    month_short         CHAR(3)      NULL,   -- Mar
    year_month          CHAR(7)      NULL,   -- 2026-03
    month_start_date    DATE         NULL,
    month_end_date      DATE         NULL,
    iso_week            TINYINT      NULL,
    day_of_month        TINYINT      NULL,
    day_of_week         TINYINT      NULL,   -- 1 = Monday ... 7 = Sunday (ISO)
    day_name            VARCHAR(10)  NULL,   -- Monday
    is_weekend          BIT          NULL,
    is_month_end        BIT          NULL
);
GO

IF OBJECT_ID(N'gold.dim_merchant', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_merchant (
    merchant_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_merchant PRIMARY KEY,
    merchant_id         VARCHAR(20)    NOT NULL,          -- MRC-nnnnn (business key)
    legal_name          NVARCHAR(200)  NULL,
    dba_name            NVARCHAR(200)  NULL,
    vertical            VARCHAR(50)    NULL,              -- history tracked
    country             CHAR(2)        NULL,
    onboard_date        DATE           NULL,
    status              VARCHAR(30)    NULL,              -- history tracked
    risk_tier           VARCHAR(20)    NULL,              -- history tracked
    reserve_pct         DECIMAL(6,4)   NULL,              -- history tracked
    processing_fee_pct  DECIMAL(6,4)   NULL,              -- history tracked
    per_txn_fee         DECIMAL(10,2)  NULL,              -- history tracked
    chargeback_fee      DECIMAL(10,2)  NULL,              -- history tracked
    mcc                 CHAR(4)        NULL,              -- history tracked
    account_manager     NVARCHAR(100)  NULL,
    valid_from          DATE           NOT NULL,          -- first day this version applies
    valid_to            DATE           NOT NULL,          -- last day (9999-12-31 for the current version)
    is_current          BIT            NOT NULL,
    is_inferred         BIT            NOT NULL CONSTRAINT DF_gold_dim_merchant_inferred DEFAULT 0,  -- referenced by data but not in the CRM yet
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_merchant_deleted  DEFAULT 0,  -- no longer in the CRM export
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_merchant_created  DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_merchant_updated  DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_merchant_version ON gold.dim_merchant (merchant_id, valid_from);
END
GO

IF OBJECT_ID(N'gold.dim_merchant_account', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_merchant_account (
    merchant_account_key INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_merchant_account PRIMARY KEY,
    mid                 VARCHAR(20)    NOT NULL,          -- acquirer's merchant account ID (business key)
    merchant_id         VARCHAR(20)    NULL,
    acquirer_name       VARCHAR(50)    NULL,
    currency_group      VARCHAR(50)    NULL,
    mcc                 CHAR(4)        NULL,
    effective_from      DATE           NULL,
    status              VARCHAR(20)    NULL,
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_merchant_account_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_merchant_account_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_merchant_account_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_merchant_account_mid ON gold.dim_merchant_account (mid);
END
GO

IF OBJECT_ID(N'gold.dim_site', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_site (
    site_key            INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_site PRIMARY KEY,
    site_id             INT            NOT NULL,
    site_name           NVARCHAR(255)  NULL,
    site_url            VARCHAR(255)   NULL,
    category            VARCHAR(100)   NULL,
    status              VARCHAR(20)    NULL,
    launch_date         DATE           NULL,
    billing_descriptor  VARCHAR(50)    NULL,
    merchant_id         VARCHAR(20)    NULL,              -- owner per the sites file
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_site_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_site_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_site_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_site_id ON gold.dim_site (site_id);
END
GO

IF OBJECT_ID(N'gold.dim_package', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_package (
    package_key         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_package PRIMARY KEY,
    package_id          INT            NOT NULL,
    package_name        NVARCHAR(255)  NULL,
    site_id             INT            NULL,
    billing_model       VARCHAR(10)    NULL,              -- One-Time / Recurring / Trial
    initial_price       DECIMAL(12,2)  NULL,
    rebill_price        DECIMAL(12,2)  NULL,
    currency            CHAR(3)        NULL,
    trial_days          INT            NULL,
    rebill_period_days  INT            NULL,
    status              VARCHAR(20)    NULL,
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_package_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_package_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_package_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_package_id ON gold.dim_package (package_id);
END
GO

IF OBJECT_ID(N'gold.dim_customer', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_customer (
    customer_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_customer PRIMARY KEY,
    customer_id         VARCHAR(20)    NOT NULL,
    country             CHAR(2)        NULL,
    created_date        DATE           NULL,
    marketing_opt_in    BIT            NULL,              -- no email / postal code in gold
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_customer_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_customer_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_customer_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_customer_id ON gold.dim_customer (customer_id);
END
GO

IF OBJECT_ID(N'gold.dim_affiliate', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_affiliate (
    affiliate_key       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_affiliate PRIMARY KEY,
    affiliate_id        VARCHAR(20)    NOT NULL,
    affiliate_name      NVARCHAR(100)  NULL,
    affiliate_type      VARCHAR(30)    NULL,
    commission_pct      DECIMAL(7,4)   NULL,
    status              VARCHAR(20)    NULL,
    join_date           DATE           NULL,
    country             CHAR(2)        NULL,
    payout_method       VARCHAR(20)    NULL,
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_affiliate_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_affiliate_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_affiliate_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_affiliate_id ON gold.dim_affiliate (affiliate_id);
END
GO

IF OBJECT_ID(N'gold.dim_card_bin', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_card_bin (
    card_bin_key        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_card_bin PRIMARY KEY,
    bin                 VARCHAR(8)     NOT NULL,          -- first 6 card digits
    card_brand          VARCHAR(20)    NULL,
    card_type           VARCHAR(10)    NULL,              -- Credit / Debit / Prepaid
    card_category       VARCHAR(20)    NULL,
    issuer_name         NVARCHAR(200)  NULL,
    issuer_country      CHAR(2)        NULL,
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_card_bin_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_card_bin_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_card_bin_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_card_bin_bin ON gold.dim_card_bin (bin);
END
GO

IF OBJECT_ID(N'gold.dim_response_code', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_response_code (
    response_code_key   INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_response_code PRIMARY KEY,
    response_code       VARCHAR(10)    NOT NULL,
    description         VARCHAR(200)   NULL,
    response_group      VARCHAR(10)    NULL,              -- Approved / Declined
    decline_type        VARCHAR(10)    NULL,              -- Soft / Hard (ref.response_code_class)
    is_approved         BIT            NULL,
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_response_code_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_response_code_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_response_code_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_response_code_code ON gold.dim_response_code (response_code);
END
GO

IF OBJECT_ID(N'gold.dim_chargeback_reason', N'U') IS NULL
BEGIN
CREATE TABLE gold.dim_chargeback_reason (
    chargeback_reason_key INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_gold_dim_chargeback_reason PRIMARY KEY,
    network             VARCHAR(20)    NOT NULL,
    reason_code         VARCHAR(20)    NOT NULL,
    description         NVARCHAR(200)  NULL,
    category            VARCHAR(30)    NULL,              -- Fraud / Authorization / Processing Error / Consumer Dispute
    is_deleted          BIT            NOT NULL CONSTRAINT DF_gold_dim_chargeback_reason_deleted DEFAULT 0,
    created_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_chargeback_reason_created DEFAULT SYSUTCDATETIME(),
    updated_at          DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_dim_chargeback_reason_updated DEFAULT SYSUTCDATETIME(),
    load_run_id         UNIQUEIDENTIFIER NULL
);
CREATE UNIQUE INDEX UX_gold_dim_chargeback_reason_code ON gold.dim_chargeback_reason (network, reason_code);
END
GO

/* =====================================================================
   FACTS
   ===================================================================== */

-- One row per payment event (sale, rebill, auth, refund, void, chargeback)
IF OBJECT_ID(N'gold.fact_transaction', N'U') IS NULL
BEGIN
CREATE TABLE gold.fact_transaction (
    txn_id                 BIGINT         NOT NULL,       -- degenerate dimension (source ID)
    date_key               INT            NOT NULL,       -- transaction date (UTC)
    merchant_key           INT            NOT NULL,       -- merchant version in effect on the transaction date
    merchant_account_key   INT            NOT NULL,
    site_key               INT            NOT NULL,
    package_key            INT            NOT NULL,
    customer_key           INT            NOT NULL,
    affiliate_key          INT            NOT NULL,
    card_bin_key           INT            NOT NULL,
    response_code_key      INT            NOT NULL,
    txn_ts_utc             DATETIME2(0)   NULL,
    purchase_id            BIGINT         NULL,
    parent_txn_id          BIGINT         NULL,
    txn_type               VARCHAR(12)    NULL,           -- Sale / Rebill / Auth / Zero Auth / Refund / Void / Chargeback
    status                 VARCHAR(10)    NULL,           -- Approved / Declined / Error
    payment_method         VARCHAR(20)    NULL,
    card_brand             VARCHAR(20)    NULL,
    currency               CHAR(3)        NULL,
    migration_phase        VARCHAR(15)    NULL,
    device_type            VARCHAR(10)    NULL,
    ip_country             CHAR(2)        NULL,
    three_ds               BIT            NULL,
    risk_score             SMALLINT       NULL,           -- fraud engine score (1-99)
    risk_decision          VARCHAR(10)    NULL,           -- Approve / Review / Decline
    amount                 DECIMAL(18,2)  NULL,           -- original currency; negative for refunds / voids / chargebacks
    amount_usd             DECIMAL(18,2)  NULL,
    is_approved            BIT            NOT NULL,       -- status = Approved
    is_revenue             BIT            NOT NULL,       -- approved Sale or Rebill
    revenue_usd            DECIMAL(18,2)  NULL,           -- amount_usd when is_revenue = 1, else 0
    merchant_id_inferred   BIT            NOT NULL,       -- from silver (old-gateway merchant mapped via risk events)
    site_id_inferred       BIT            NOT NULL,       -- from silver (site taken from the package)
    load_run_id            UNIQUEIDENTIFIER NULL,
    gold_loaded_at         DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_fact_transaction_loaded DEFAULT SYSUTCDATETIME()
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_gold_fact_transaction ON gold.fact_transaction;
ALTER TABLE gold.fact_transaction ADD CONSTRAINT PK_gold_fact_transaction PRIMARY KEY NONCLUSTERED (txn_id);
END
GO

-- One row per chargeback (dispute) case
IF OBJECT_ID(N'gold.fact_chargeback', N'U') IS NULL
BEGIN
CREATE TABLE gold.fact_chargeback (
    case_id                VARCHAR(50)    NOT NULL,
    received_date_key      INT            NOT NULL,       -- dispute received
    orig_txn_date_key      INT            NOT NULL,       -- original sale
    resolution_date_key    INT            NOT NULL,
    merchant_key           INT            NOT NULL,       -- merchant version on the original sale date
    merchant_account_key   INT            NOT NULL,
    chargeback_reason_key  INT            NOT NULL,
    card_bin_key           INT            NOT NULL,
    site_key               INT            NOT NULL,       -- from the linked transaction
    package_key            INT            NOT NULL,
    customer_key           INT            NOT NULL,
    affiliate_key          INT            NOT NULL,
    txn_id                 BIGINT         NULL,           -- disputed transaction (NULL if not found)
    arn                    VARCHAR(30)    NULL,
    network                VARCHAR(20)    NULL,
    reason_code            VARCHAR(20)    NULL,
    status                 VARCHAR(30)    NULL,
    outcome                VARCHAR(30)    NULL,           -- Won / Lost / Accepted; NULL while open
    dispute_amount         DECIMAL(18,2)  NULL,
    dispute_ccy            CHAR(3)        NULL,
    dispute_amount_usd     DECIMAL(18,2)  NULL,
    is_open                BIT            NOT NULL,
    is_won                 BIT            NOT NULL,
    is_lost                BIT            NOT NULL,       -- Lost or Accepted (merchant bears the loss)
    is_representment_sent  BIT            NULL,
    is_linked_to_txn       BIT            NOT NULL,
    days_sale_to_dispute   INT            NULL,
    days_to_respond        INT            NULL,           -- received -> respond_by deadline
    days_to_resolution     INT            NULL,           -- received -> resolution
    load_run_id            UNIQUEIDENTIFIER NULL,
    gold_loaded_at         DATETIME2(0)   NOT NULL CONSTRAINT DF_gold_fact_chargeback_loaded DEFAULT SYSUTCDATETIME()
);
CREATE CLUSTERED COLUMNSTORE INDEX CCI_gold_fact_chargeback ON gold.fact_chargeback;
ALTER TABLE gold.fact_chargeback ADD CONSTRAINT PK_gold_fact_chargeback PRIMARY KEY NONCLUSTERED (case_id);
END
GO
