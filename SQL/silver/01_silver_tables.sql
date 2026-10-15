/* =====================================================================
   Script    : 01_silver_tables.sql
   Purpose   : Creates every silver table with proper data types, indexes
               on the join keys, masking and sensitivity labels on personal
               data.

   !! DESTRUCTIVE: drops and re-creates all silver tables. !!
   Silver is fully rebuildable from bronze - after running this, run
   EXEC silver.usp_load_all to reload.

   Conventions
   -----------
   * Real data types: DATE, DATETIME2, DECIMAL, INT/BIGINT, BIT. Missing or
     unreadable values are NULL (not 'N/A' text), so numbers and dates can
     be summed, compared and sorted directly.
   * Text codes that can have leading zeros stay text (response_code '05',
     mcc '0742', card BINs, MIDs).
   * Every table ends with the same lineage columns:
       source_system, source_file_name, batch_id (bronze load batch),
       bronze_ingested_at, ingested_by  - where the row came from
       load_run_id                      - the silver run (audit.load_log)
       silver_loaded_at                 - when silver wrote the row (UTC)
   * No foreign keys: tables are emptied and reloaded each run (TRUNCATE is
     not allowed on a table referenced by a foreign key). Relationships are
     checked by the load procedures' data-quality counts instead.
   * Personal data: Dynamic Data Masking hides email / IP / postal code from
     users without the UNMASK permission (the database owner still sees
     them), and sensitivity labels record what each column holds.

   Requires 00_foundation.sql.
   ===================================================================== */

SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   Drop existing silver tables
   --------------------------------------------------------------------- */
DECLARE @drop NVARCHAR(MAX) = N'';
SELECT @drop += N'DROP TABLE silver.' + QUOTENAME(name) + N';' + CHAR(10)
FROM sys.tables WHERE schema_id = SCHEMA_ID(N'silver');
EXEC sys.sp_executesql @drop;
GO

/* =====================================================================
   Reference / master data
   ===================================================================== */

CREATE TABLE silver.affiliates (
    affiliate_id        VARCHAR(20)       NOT NULL CONSTRAINT PK_silver_affiliates PRIMARY KEY,  -- AFF-0000
    affiliate_name      NVARCHAR(100)     NULL,
    affiliate_type      VARCHAR(30)       NULL,
    commission_pct      DECIMAL(7,4)      NULL,   -- fraction: 0.3500 = 35%
    status              VARCHAR(20)       NULL,   -- Active / Inactive / Suspended
    join_date           DATE              NULL,
    country             CHAR(2)           NULL,   -- ISO 3166-1 alpha-2
    payout_method       VARCHAR(20)       NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_affiliates_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.bin_reference (
    bin                 VARCHAR(8)        NOT NULL CONSTRAINT PK_silver_bin_reference PRIMARY KEY,  -- first 6 card digits
    card_brand          VARCHAR(20)       NULL,   -- Visa / Mastercard / American Express / UnionPay / JCB
    card_type           VARCHAR(10)       NULL,   -- Credit / Debit / Prepaid
    card_category       VARCHAR(20)       NULL,   -- Standard / Classic / Gold / Platinum / Business
    issuer_name         NVARCHAR(200)     NULL,   -- issuing bank, country suffix removed
    issuer_country      CHAR(2)           NULL,
    last_updated        DATE              NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_bin_reference_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.chargeback_reason_codes (
    network             VARCHAR(20)       NOT NULL,  -- Visa / Mastercard / American Express / Discover
    reason_code         VARCHAR(10)       NOT NULL,  -- e.g. 10.4, 4837, F29
    description         NVARCHAR(200)     NULL,
    category            VARCHAR(30)       NULL,      -- Fraud / Authorization / Processing Error / Consumer Dispute
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_cb_reason_codes_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_silver_chargeback_reason_codes PRIMARY KEY (network, reason_code)
);

CREATE TABLE silver.response_codes (
    response_code       VARCHAR(10)       NOT NULL CONSTRAINT PK_silver_response_codes PRIMARY KEY,  -- '00', '51', 'N7'
    description         VARCHAR(200)      NULL,   -- title case, e.g. Insufficient Funds
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_response_codes_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.fx_rates_daily (
    rate_date           DATE              NOT NULL,
    currency            CHAR(3)           NOT NULL,  -- non-USD currency, e.g. GBP
    usd_per_unit        DECIMAL(18,8)     NOT NULL,  -- US Treasury rate: amount * usd_per_unit = USD
    units_per_usd       DECIMAL(18,8)     NOT NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_fx_rates_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_silver_fx_rates_daily PRIMARY KEY (currency, rate_date)
);

/* =====================================================================
   Merchants, sites, packages
   ===================================================================== */

CREATE TABLE silver.merchant_accounts (
    mid                 VARCHAR(20)       NOT NULL CONSTRAINT PK_silver_merchant_accounts PRIMARY KEY,  -- acquirer's merchant account ID
    merchant_id         VARCHAR(20)       NULL,   -- MRC-nnnnn
    acquirer_name       VARCHAR(50)       NULL,
    currency_group      VARCHAR(50)       NULL,   -- e.g. USD/CAD/AUD
    mcc                 CHAR(4)           NULL,   -- Merchant Category Code, leading zeros kept
    effective_from      DATE              NULL,
    status              VARCHAR(20)       NULL,   -- Active / Suspended / Closed / Terminated
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_merchant_accounts_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_merchant_accounts_merchant ON silver.merchant_accounts (merchant_id);

CREATE TABLE silver.merchants_crm_export (
    merchant_id         VARCHAR(20)       NOT NULL CONSTRAINT PK_silver_merchants_crm_export PRIMARY KEY,
    legal_name          NVARCHAR(200)     NULL,
    dba_name            NVARCHAR(200)     NULL,
    vertical            VARCHAR(50)       NULL,
    country             CHAR(2)           NULL,
    onboard_date        DATE              NULL,
    status              VARCHAR(30)       NULL,   -- Active / Pending Review / Suspended / Closed / Closed by merchant / Closed - terminated / Terminated
    risk_tier           VARCHAR(20)       NULL,   -- Tier 1 (lowest) - Tier 5 (highest)
    reserve_pct         DECIMAL(6,4)      NULL,   -- fraction: 0.1500 = 15%
    processing_fee_pct  DECIMAL(6,4)      NULL,   -- fraction
    per_txn_fee         DECIMAL(10,2)     NULL,
    chargeback_fee      DECIMAL(10,2)     NULL,
    mcc                 CHAR(4)           NULL,
    account_manager     NVARCHAR(100)     NULL,
    contact_email       NVARCHAR(254)     MASKED WITH (FUNCTION = 'email()') NULL,
    last_modified       DATETIME2(0)      NULL,
    modified_by         NVARCHAR(100)     NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_merchants_crm_export_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.merchant_xref (
    legacy_merchant_id  INT               NOT NULL CONSTRAINT PK_silver_merchant_xref PRIMARY KEY,  -- old gateway ID, e.g. 1005
    merchant_id         VARCHAR(20)       NULL,   -- new gateway ID, MRC-nnnnn
    effective_from      DATE              NULL,
    notes               NVARCHAR(500)     NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_merchant_xref_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.sites (
    site_id             INT               NOT NULL CONSTRAINT PK_silver_sites PRIMARY KEY,
    merchant_id         VARCHAR(20)       NULL,
    site_name           NVARCHAR(255)     NULL,
    site_url            VARCHAR(255)      NULL,   -- bare domain, e.g. emberpro.com
    category            VARCHAR(100)      NULL,
    launch_date         DATE              NULL,
    status              VARCHAR(20)       NULL,   -- Live / Active / Closed / Inactive / Paused / Under Review
    billing_descriptor  VARCHAR(50)       NULL,   -- SEGPAY*SITENAME
    support_email       NVARCHAR(320)     NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_sites_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_sites_merchant ON silver.sites (merchant_id);

CREATE TABLE silver.packages (
    package_id          INT               NOT NULL CONSTRAINT PK_silver_packages PRIMARY KEY,
    site_id             INT               NULL,
    package_name        NVARCHAR(255)     NULL,
    billing_model       VARCHAR(10)       NULL,   -- One-Time / Recurring / Trial
    initial_price       DECIMAL(12,2)     NULL,
    currency            CHAR(3)           NULL,
    trial_days          INT               NULL,
    rebill_price        DECIMAL(12,2)     NULL,
    rebill_period_days  INT               NULL,   -- 30 / 90 / 365
    status              VARCHAR(20)       NULL,   -- Active / Retired
    created_date        DATE              NULL,
    updated_date        DATE              NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_packages_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_packages_site ON silver.packages (site_id);

/* =====================================================================
   Customers and affiliates traffic
   ===================================================================== */

CREATE TABLE silver.customers (
    customer_id         VARCHAR(20)       NOT NULL CONSTRAINT PK_silver_customers PRIMARY KEY,
    email               NVARCHAR(320)     MASKED WITH (FUNCTION = 'email()') NULL,
    country             CHAR(2)           NULL,
    postal_code         VARCHAR(20)       MASKED WITH (FUNCTION = 'default()') NULL,
    created_at          DATE              NULL,   -- account creation date
    marketing_opt_in    BIT               NULL,   -- 1 = opted in, 0 = opted out, NULL = no answer (do not market)
    last_updated        DATE              NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_customers_loaded DEFAULT SYSUTCDATETIME()
);

CREATE TABLE silver.clicks (
    click_id            VARCHAR(50)       NOT NULL CONSTRAINT PK_silver_clicks PRIMARY KEY,
    click_ts_utc        DATETIME2(3)      NULL,
    publisher_id        INT               NULL,
    affiliate_id        VARCHAR(20)       NULL,   -- AFF-0000 (publisher 4 -> AFF-0004; matches purchases in every case)
    offer_id            INT               NULL,
    sub_id              NVARCHAR(100)     NULL,
    ip                  VARCHAR(45)       MASKED WITH (FUNCTION = 'default()') NULL,
    ua_family           VARCHAR(30)       NULL,
    device_category     VARCHAR(10)       NULL,   -- Mobile / Desktop
    is_bot              BIT               NULL,
    country             CHAR(2)           NULL,
    landing_variant     VARCHAR(20)       NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_clicks_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_clicks_affiliate ON silver.clicks (affiliate_id);

CREATE TABLE silver.conversions (
    conversion_id       VARCHAR(50)       NOT NULL CONSTRAINT PK_silver_conversions PRIMARY KEY,
    click_id            VARCHAR(50)       NULL,
    conversion_ts_utc   DATETIME2(3)      NULL,
    order_id            BIGINT            NULL,   -- = purchase_id
    event               VARCHAR(30)       NULL,
    payout_usd          DECIMAL(18,2)     NULL,
    status              VARCHAR(30)       NULL,   -- Approved / Pending / Rejected / Reversed
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_conversions_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_conversions_click ON silver.conversions (click_id);
CREATE INDEX IX_silver_conversions_order ON silver.conversions (order_id);

/* =====================================================================
   Purchases and transactions
   ===================================================================== */

CREATE TABLE silver.purchases_snapshot (
    purchase_id         BIGINT            NOT NULL CONSTRAINT PK_silver_purchases_snapshot PRIMARY KEY,
    customer_id         VARCHAR(20)       NULL,
    merchant_id         VARCHAR(20)       NULL,
    site_id             INT               NULL,
    package_id          INT               NULL,
    purchase_date       DATE              NULL,
    purchase_status     VARCHAR(20)       NULL,   -- Active / Past Due / Cancelled / Expired / Completed / Chargeback
    cancel_date         DATE              NULL,
    cancel_reason       VARCHAR(50)       NULL,
    cancel_initiated_by VARCHAR(50)       NULL,
    next_rebill_date    DATE              NULL,
    rebill_count        INT               NULL,
    affiliate_id        VARCHAR(20)       NULL,
    traffic_source      VARCHAR(50)       NULL,
    promo_code          VARCHAR(50)       NULL,
    is_trial            BIT               NULL,
    last_updated        DATE              NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_purchases_snapshot_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_purchases_customer ON silver.purchases_snapshot (customer_id);
CREATE INDEX IX_silver_purchases_merchant ON silver.purchases_snapshot (merchant_id);
CREATE INDEX IX_silver_purchases_site     ON silver.purchases_snapshot (site_id);

CREATE TABLE silver.transactions (
    txn_id                 BIGINT            NOT NULL CONSTRAINT PK_silver_transactions PRIMARY KEY,
    migration_phase        VARCHAR(15)       NOT NULL,  -- Pre-migration (old gateway) / Post-migration (new)
    purchase_id            BIGINT            NULL,
    parent_txn_id          BIGINT            NULL,      -- transaction reversed by a refund / void / chargeback
    merchant_id            VARCHAR(20)       NULL,      -- MRC-nnnnn
    merchant_id_inferred   BIT               NOT NULL,  -- 1 = old-gateway merchant mapped from risk events, not merchant_xref
    legacy_merchant_id     INT               NULL,      -- old gateway's merchant number
    site_id                INT               NULL,
    site_id_inferred       BIT               NOT NULL,  -- 1 = invalid site_id replaced by the package's site
    package_id             INT               NULL,
    customer_id            VARCHAR(20)       NULL,
    txn_type               VARCHAR(12)       NULL,      -- Sale / Rebill / Auth / Zero Auth / Refund / Void / Chargeback
    amount                 DECIMAL(18,2)     NULL,      -- negative for Refund / Void / Chargeback
    currency               CHAR(3)           NULL,
    amount_usd             DECIMAL(18,2)     NULL,
    fx_rate                DECIMAL(18,8)     NULL,      -- USD per 1 unit used; NULL for USD
    fx_rate_date           DATE              NULL,
    card_brand             VARCHAR(20)       NULL,
    card_bin               VARCHAR(8)        NULL,      -- as sent: 6 digits (old) or 8 (new)
    card_bin6              CHAR(6)           NULL,      -- joins to silver.bin_reference
    card_last4             CHAR(4)           NULL,
    payment_method         VARCHAR(20)       NULL,      -- Card / Apple Pay / Google Pay / SEPA Direct Debit
    response_code          VARCHAR(10)       NULL,
    response_text          VARCHAR(200)      NULL,      -- one description per code (silver.response_codes)
    gateway_response_text  VARCHAR(100)      NULL,      -- the gateway's own wording
    status                 VARCHAR(10)       NULL,      -- Approved / Declined / Error
    txn_ts_utc             DATETIME2(0)      NULL,
    settle_date            DATE              NULL,
    acquirer               VARCHAR(30)       NULL,
    mid                    VARCHAR(20)       NULL,
    three_ds               BIT               NULL,
    device_type            VARCHAR(10)       NULL,      -- Mobile / Desktop / Tablet
    ip_address             VARCHAR(45)       MASKED WITH (FUNCTION = 'default()') NULL,
    ip_country             CHAR(2)           NULL,
    affiliate_id           VARCHAR(20)       NULL,
    network_txn_id         VARCHAR(30)       NULL,      -- new gateway only
    gateway_batch_id       VARCHAR(50)       NULL,
    gateway_load_ts        DATETIME2(0)      NULL,
    source_system          VARCHAR(50)       NULL,
    source_file_name       NVARCHAR(260)     NULL,
    batch_id               UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at     DATETIME2(3)      NULL,
    ingested_by            NVARCHAR(128)     NULL,
    load_run_id            UNIQUEIDENTIFIER  NULL,
    silver_loaded_at       DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_transactions_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_transactions_purchase ON silver.transactions (purchase_id);
CREATE INDEX IX_silver_transactions_merchant ON silver.transactions (merchant_id, txn_ts_utc);
CREATE INDEX IX_silver_transactions_site     ON silver.transactions (site_id);
CREATE INDEX IX_silver_transactions_customer ON silver.transactions (customer_id);
CREATE INDEX IX_silver_transactions_ts       ON silver.transactions (txn_ts_utc);
CREATE INDEX IX_silver_transactions_bin6     ON silver.transactions (card_bin6);

/* =====================================================================
   Risk, chargebacks, clearing, settlements, support
   ===================================================================== */

CREATE TABLE silver.risk_events (
    event_id               VARCHAR(40)       NOT NULL CONSTRAINT PK_silver_risk_events PRIMARY KEY,
    txn_id                 BIGINT            NULL,
    purchase_id            BIGINT            NULL,
    merchant_id            VARCHAR(20)       NULL,
    event_ts_utc           DATETIME2(0)      NULL,
    engine_version         VARCHAR(10)       NULL,   -- 2.9.1 / 3.1.0
    risk_score             SMALLINT          NULL,   -- 1-99
    decision               VARCHAR(10)       NULL,   -- Approve / Review / Decline
    rules_triggered_count  INT               NOT NULL,
    rule_ids               VARCHAR(200)      NULL,   -- e.g. 'R104, R130'
    signal_ip_country      CHAR(2)           NULL,
    signal_bin_country     CHAR(2)           NULL,
    signal_email_age_days  INT               NULL,
    signal_velocity_1h     INT               NULL,
    signal_proxy           BIT               NULL,
    signal_device_id       VARCHAR(50)       NULL,
    source_system          VARCHAR(50)       NULL,
    source_file_name       NVARCHAR(260)     NULL,
    batch_id               UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at     DATETIME2(3)      NULL,
    ingested_by            NVARCHAR(128)     NULL,
    load_run_id            UNIQUEIDENTIFIER  NULL,
    silver_loaded_at       DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_risk_events_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_risk_events_txn      ON silver.risk_events (txn_id);
CREATE INDEX IX_silver_risk_events_purchase ON silver.risk_events (purchase_id);

CREATE TABLE silver.risk_event_rules (
    event_id            VARCHAR(40)       NOT NULL,
    rule_id             VARCHAR(10)       NOT NULL,
    rule_name           VARCHAR(100)      NULL,
    rule_weight         INT               NULL,   -- engine 2.9.1 only
    engine_version      VARCHAR(10)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_risk_event_rules_loaded DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_silver_risk_event_rules PRIMARY KEY (event_id, rule_id)
);
CREATE INDEX IX_silver_risk_event_rules_rule ON silver.risk_event_rules (rule_id);

CREATE TABLE silver.chargebacks_acquirer_feed (
    case_id                   VARCHAR(50)       NOT NULL CONSTRAINT PK_silver_chargebacks_acquirer_feed PRIMARY KEY,
    network                   VARCHAR(20)       NULL,
    reason_code               VARCHAR(20)       NULL,
    reason_category           VARCHAR(30)       NULL,
    reason_desc               NVARCHAR(200)     NULL,
    arn                       VARCHAR(30)       NULL,   -- Acquirer Reference Number
    mid                       VARCHAR(20)       NULL,
    merchant_id               VARCHAR(20)       NULL,   -- from silver.merchant_accounts via mid
    merchant_descriptor       NVARCHAR(200)     NULL,
    merchant_descriptor_name  NVARCHAR(200)     NULL,
    txn_ref                   BIGINT            NULL,   -- = silver.transactions.txn_id
    card_bin                  VARCHAR(10)       NULL,
    card_last4                VARCHAR(10)       NULL,
    orig_txn_date             DATE              NULL,
    dispute_amount            DECIMAL(18,2)     NULL,
    dispute_ccy               CHAR(3)           NULL,
    dispute_amount_usd        DECIMAL(18,2)     NULL,
    fx_rate                   DECIMAL(18,8)     NULL,
    fx_rate_date              DATE              NULL,
    received_date             DATE              NULL,
    respond_by                DATE              NULL,
    status                    VARCHAR(30)       NULL,
    resolution_date           DATE              NULL,
    outcome                   VARCHAR(30)       NULL,
    representment_sent_date   DATE              NULL,
    is_representment_sent     BIT               NULL,
    source_system             VARCHAR(50)       NULL,
    source_file_name          NVARCHAR(260)     NULL,
    batch_id                  UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at        DATETIME2(3)      NULL,
    ingested_by               NVARCHAR(128)     NULL,
    load_run_id               UNIQUEIDENTIFIER  NULL,
    silver_loaded_at          DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_chargebacks_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_chargebacks_txn      ON silver.chargebacks_acquirer_feed (txn_ref);
CREATE INDEX IX_silver_chargebacks_arn      ON silver.chargebacks_acquirer_feed (arn);
CREATE INDEX IX_silver_chargebacks_merchant ON silver.chargebacks_acquirer_feed (merchant_id);

CREATE TABLE silver.clearing_transactions (
    arn                 VARCHAR(30)       NOT NULL CONSTRAINT PK_silver_clearing_transactions PRIMARY KEY,
    acquirer            VARCHAR(50)       NULL,
    batch_period        CHAR(7)           NULL,   -- YYYY-MM
    batch_item_count    INT               NULL,
    mid                 VARCHAR(20)       NULL,
    merchant_id         VARCHAR(20)       NULL,   -- from silver.merchant_accounts via mid
    auth_date           DATE              NULL,
    clear_date          DATE              NULL,
    bin                 VARCHAR(10)       NULL,
    last4               VARCHAR(10)       NULL,
    currency_code       CHAR(3)           NULL,
    amount              DECIMAL(18,2)     NULL,   -- major units
    interchange         DECIMAL(18,4)     NULL,
    amount_usd          DECIMAL(18,2)     NULL,
    interchange_usd     DECIMAL(18,4)     NULL,
    fx_rate             DECIMAL(18,8)     NULL,
    fx_rate_date        DATE              NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_clearing_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_clearing_merchant ON silver.clearing_transactions (merchant_id, auth_date);

CREATE TABLE silver.settlements_weekly (
    settlement_id       VARCHAR(30)       NOT NULL CONSTRAINT PK_silver_settlements_weekly PRIMARY KEY,
    merchant_id         VARCHAR(20)       NULL,
    period_start        DATE              NULL,
    period_end          DATE              NULL,
    currency            CHAR(3)           NULL,
    gross_sales         DECIMAL(18,2)     NULL,
    refunds             DECIMAL(18,2)     NULL,   -- negative
    chargebacks         DECIMAL(18,2)     NULL,
    fees_total          DECIMAL(18,2)     NULL,
    reserve_held        DECIMAL(18,2)     NULL,
    reserve_released    DECIMAL(18,2)     NULL,
    adjustments         DECIMAL(18,2)     NULL,
    adjustment_note     NVARCHAR(500)     NULL,
    net_payout          DECIMAL(18,2)     NULL,
    payout_reconciles   BIT               NULL,   -- 1 = net_payout equals its components
    payout_date         DATE              NULL,
    payout_status       VARCHAR(20)       NULL,   -- Paid / Pending / Scheduled / Held / Failed / Returned
    bank_ref            VARCHAR(100)      NULL,
    version             INT               NULL,   -- 1 = original, 2 = reissued
    created_ts          DATETIME2(0)      NULL,
    source_system       VARCHAR(50)       NULL,
    source_file_name    NVARCHAR(260)     NULL,
    batch_id            UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at  DATETIME2(3)      NULL,
    ingested_by         NVARCHAR(128)     NULL,
    load_run_id         UNIQUEIDENTIFIER  NULL,
    silver_loaded_at    DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_settlements_weekly_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_settlements_merchant ON silver.settlements_weekly (merchant_id, period_start);

CREATE TABLE silver.helpdesk_tickets (
    ticket_id            VARCHAR(30)       NOT NULL CONSTRAINT PK_silver_helpdesk_tickets PRIMARY KEY,
    requester_email      NVARCHAR(320)     MASKED WITH (FUNCTION = 'email()') NULL,
    order_ref            VARCHAR(50)       NULL,   -- as written, e.g. SP-4140960
    order_id             BIGINT            NULL,   -- = purchase_id (matches in every case)
    brand_domain         VARCHAR(200)      NULL,
    category             NVARCHAR(100)     NULL,
    priority             VARCHAR(20)       NULL,
    status               VARCHAR(20)       NULL,
    created_at           DATETIME2(0)      NULL,
    solved_at            DATETIME2(0)      NULL,
    first_reply_minutes  INT               NULL,
    resolution_minutes   INT               NULL,
    csat                 VARCHAR(20)       NULL,
    assignee             VARCHAR(100)      NULL,
    channel              VARCHAR(20)       NULL,
    tags                 VARCHAR(500)      NULL,
    source_system        VARCHAR(50)       NULL,
    source_file_name     NVARCHAR(260)     NULL,
    batch_id             UNIQUEIDENTIFIER  NULL,
    bronze_ingested_at   DATETIME2(3)      NULL,
    ingested_by          NVARCHAR(128)     NULL,
    load_run_id          UNIQUEIDENTIFIER  NULL,
    silver_loaded_at     DATETIME2(0)      NOT NULL CONSTRAINT DF_silver_helpdesk_loaded DEFAULT SYSUTCDATETIME()
);
CREATE INDEX IX_silver_helpdesk_order ON silver.helpdesk_tickets (order_id);
GO

/* =====================================================================
   Sensitivity labels (metadata only - shown in SSMS and audit reports)
   ===================================================================== */
ADD SENSITIVITY CLASSIFICATION TO silver.customers.email, silver.helpdesk_tickets.requester_email
    WITH (LABEL = 'Confidential - GDPR', INFORMATION_TYPE = 'Contact Info', RANK = MEDIUM);
ADD SENSITIVITY CLASSIFICATION TO silver.customers.postal_code
    WITH (LABEL = 'Confidential - GDPR', INFORMATION_TYPE = 'Contact Info', RANK = MEDIUM);
ADD SENSITIVITY CLASSIFICATION TO silver.merchants_crm_export.contact_email, silver.sites.support_email
    WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Contact Info', RANK = LOW);
ADD SENSITIVITY CLASSIFICATION TO silver.transactions.ip_address, silver.clicks.ip
    WITH (LABEL = 'Confidential - GDPR', INFORMATION_TYPE = 'Networking', RANK = MEDIUM);
ADD SENSITIVITY CLASSIFICATION TO silver.transactions.card_last4, silver.transactions.card_bin,
                                  silver.chargebacks_acquirer_feed.card_last4, silver.chargebacks_acquirer_feed.card_bin,
                                  silver.clearing_transactions.last4, silver.clearing_transactions.bin
    WITH (LABEL = 'Confidential', INFORMATION_TYPE = 'Credit Card', RANK = MEDIUM);
GO
