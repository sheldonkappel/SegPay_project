/* =====================================================================
   Script    : 01_bronze_tables.sql
   Purpose   : Creates the bronze schema and every bronze table.
               Generated from the SegPay database on 2026-10-15.

   Safe to re-run: each table is created only if it does not exist, so
   existing bronze data is never touched. (To rebuild a table from
   scratch, drop it first, then run this script and reload its files.)

   Conventions
   -----------
   * Every source column is stored as text, exactly as received - no
     cleaning or type conversion happens in bronze (that is silver's job).
   * Load metadata on every table:
       source_system, source_file_name, source_file_path, batch_id
                      - written by the load procedure
       ingested_at, ingested_by
                      - filled by column defaults
   ===================================================================== */
SET NOCOUNT ON;
GO

IF SCHEMA_ID(N'bronze') IS NULL EXEC (N'CREATE SCHEMA bronze');
GO
IF OBJECT_ID(N'bronze.affiliates', N'U') IS NULL
CREATE TABLE bronze.[affiliates] (
    [affiliate_id]             VARCHAR(64)        NULL,
    [affiliate_name]           VARCHAR(255)       NULL,
    [affiliate_type]           VARCHAR(100)       NULL,
    [commission_pct]           VARCHAR(20)        NULL,
    [status]                   VARCHAR(50)        NULL,
    [join_date]                VARCHAR(50)        NULL,
    [country]                  VARCHAR(50)        NULL,
    [payout_method]            VARCHAR(100)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_affiliates_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_affiliates_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.bin_reference', N'U') IS NULL
CREATE TABLE bronze.[bin_reference] (
    [bin]                      VARCHAR(8)         NULL,
    [card_brand]               VARCHAR(50)        NULL,
    [card_type]                VARCHAR(50)        NULL,
    [card_category]            VARCHAR(50)        NULL,
    [issuer_name]              VARCHAR(255)       NULL,
    [issuer_country]           VARCHAR(50)        NULL,
    [last_updated]             VARCHAR(50)        NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_bin_reference_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_bin_reference_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.chargeback_reason_codes', N'U') IS NULL
CREATE TABLE bronze.[chargeback_reason_codes] (
    [network]                  VARCHAR(50)        NULL,
    [reason_code]              VARCHAR(20)        NULL,
    [description]              VARCHAR(500)       NULL,
    [category]                 VARCHAR(100)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_chargeback_reason_codes_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_chargeback_reason_codes_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.chargebacks_acquirer_feed', N'U') IS NULL
CREATE TABLE bronze.[chargebacks_acquirer_feed] (
    [case_id]                  VARCHAR(64)        NULL,
    [network]                  VARCHAR(50)        NULL,
    [reason_code]              VARCHAR(20)        NULL,
    [reason_desc]              VARCHAR(500)       NULL,
    [arn]                      VARCHAR(30)        NULL,
    [mid]                      VARCHAR(20)        NULL,
    [merchant_descriptor]      VARCHAR(255)       NULL,
    [txn_ref]                  VARCHAR(1000)      NULL,
    [card_bin]                 VARCHAR(8)         NULL,
    [card_last4]               CHAR(4)            NULL,
    [orig_txn_date]            VARCHAR(50)        NULL,
    [dispute_amount]           VARCHAR(50)        NULL,
    [dispute_ccy]              VARCHAR(10)        NULL,
    [received_date]            VARCHAR(50)        NULL,
    [respond_by]               VARCHAR(50)        NULL,
    [status]                   VARCHAR(50)        NULL,
    [resolution_date]          VARCHAR(50)        NULL,
    [outcome]                  VARCHAR(50)        NULL,
    [representment_sent]       VARCHAR(20)        NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_chargebacks_acquirer_feed_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_chargebacks_acquirer_feed_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.clearing_transactions', N'U') IS NULL
CREATE TABLE bronze.[clearing_transactions] (
    [acquirer]                 NVARCHAR(100)      NOT NULL,
    [batch_period]             NVARCHAR(50)       NULL,
    [batch_item_count]         NVARCHAR(50)       NULL,
    [mid]                      NVARCHAR(100)      NULL,
    [arn]                      NVARCHAR(100)      NULL,
    [auth_date]                NVARCHAR(100)      NULL,
    [clear_date]               NVARCHAR(100)      NULL,
    [bin]                      NVARCHAR(100)      NULL,
    [last4]                    NVARCHAR(100)      NULL,
    [amount]                   NVARCHAR(100)      NULL,
    [currency_code]            NVARCHAR(100)      NULL,
    [is_minor_unit]            NVARCHAR(100)      NULL,
    [interchange]              NVARCHAR(100)      NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_clearing_transactions_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_clearing_transactions_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.clicks', N'U') IS NULL
CREATE TABLE bronze.[clicks] (
    [click_id]                 VARCHAR(64)        NULL,
    [click_ts_ms]              VARCHAR(1000)      NULL,
    [publisher_id]             VARCHAR(1000)      NULL,
    [offer_id]                 VARCHAR(1000)      NULL,
    [sub_id]                   VARCHAR(255)       NULL,
    [ip]                       VARCHAR(45)        NULL,
    [ua_family]                VARCHAR(100)       NULL,
    [geo]                      VARCHAR(50)        NULL,
    [landing_variant]          VARCHAR(100)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_clicks_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_clicks_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.conversions', N'U') IS NULL
CREATE TABLE bronze.[conversions] (
    [conversion_id]            VARCHAR(64)        NULL,
    [click_id]                 VARCHAR(64)        NULL,
    [conversion_ts_ms]         VARCHAR(1000)      NULL,
    [order_id]                 VARCHAR(1000)      NULL,
    [event]                    VARCHAR(100)       NULL,
    [payout_usd]               VARCHAR(1000)      NULL,
    [status]                   VARCHAR(50)        NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_conversions_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_conversions_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.customers', N'U') IS NULL
CREATE TABLE bronze.[customers] (
    [customer_id]              VARCHAR(64)        NULL,
    [email]                    VARCHAR(320)       NULL,
    [country]                  VARCHAR(50)        NULL,
    [postal_code]              VARCHAR(20)        NULL,
    [created_at]               VARCHAR(50)        NULL,
    [marketing_opt_in]         VARCHAR(20)        NULL,
    [last_updated]             VARCHAR(1000)      NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_customers_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_customers_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.fx_rates_daily', N'U') IS NULL
CREATE TABLE bronze.[fx_rates_daily] (
    [rate_date]                VARCHAR(50)        NULL,
    [pair]                     VARCHAR(20)        NULL,
    [rate]                     VARCHAR(50)        NULL,
    [source]                   VARCHAR(100)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_fx_rates_daily_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_fx_rates_daily_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.helpdesk_tickets', N'U') IS NULL
CREATE TABLE bronze.[helpdesk_tickets] (
    [ticket_id]                VARCHAR(20)        NULL,
    [requester_email]          VARCHAR(320)       NULL,
    [order_ref]                VARCHAR(50)        NULL,
    [brand_domain]             VARCHAR(255)       NULL,
    [category]                 VARCHAR(100)       NULL,
    [priority]                 VARCHAR(20)        NULL,
    [status]                   VARCHAR(20)        NULL,
    [created_at]               VARCHAR(20)        NULL,
    [solved_at]                VARCHAR(20)        NULL,
    [first_reply_minutes]      VARCHAR(1000)      NULL,
    [csat]                     VARCHAR(20)        NULL,
    [assignee]                 VARCHAR(100)       NULL,
    [channel]                  VARCHAR(50)        NULL,
    [tags]                     VARCHAR(255)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_helpdesk_tickets_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_helpdesk_tickets_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.merchant_accounts', N'U') IS NULL
CREATE TABLE bronze.[merchant_accounts] (
    [merchant_id]              VARCHAR(64)        NULL,
    [acquirer_name]            VARCHAR(100)       NULL,
    [mid]                      VARCHAR(1000)      NULL,
    [currency_group]           VARCHAR(50)        NULL,
    [mcc]                      VARCHAR(1000)      NULL,
    [effective_from]           VARCHAR(1000)      NULL,
    [status]                   VARCHAR(50)        NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_merchant_accounts_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_merchant_accounts_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.merchant_xref', N'U') IS NULL
CREATE TABLE bronze.[merchant_xref] (
    [legacy_merchant_id]       VARCHAR(1000)      NULL,
    [merchant_id]              VARCHAR(64)        NULL,
    [effective_from]           VARCHAR(1000)      NULL,
    [effective_to]             VARCHAR(50)        NULL,
    [notes]                    VARCHAR(500)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_merchant_xref_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_merchant_xref_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.merchants_crm_export', N'U') IS NULL
CREATE TABLE bronze.[merchants_crm_export] (
    [merchant_id]              VARCHAR(64)        NULL,
    [legal_name]               VARCHAR(255)       NULL,
    [dba_name]                 VARCHAR(255)       NULL,
    [vertical]                 VARCHAR(100)       NULL,
    [country]                  VARCHAR(50)        NULL,
    [onboard_date]             VARCHAR(50)        NULL,
    [status]                   VARCHAR(50)        NULL,
    [risk_tier]                VARCHAR(50)        NULL,
    [reserve_pct]              VARCHAR(20)        NULL,
    [processing_fee_pct]       VARCHAR(20)        NULL,
    [per_txn_fee]              VARCHAR(1000)      NULL,
    [chargeback_fee]           VARCHAR(1000)      NULL,
    [mcc]                      VARCHAR(1000)      NULL,
    [account_manager]          VARCHAR(255)       NULL,
    [contact_email]            VARCHAR(320)       NULL,
    [last_modified]            VARCHAR(50)        NULL,
    [modified_by]              VARCHAR(255)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_merchants_crm_export_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_merchants_crm_export_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.packages', N'U') IS NULL
CREATE TABLE bronze.[packages] (
    [package_id]               VARCHAR(1000)      NULL,
    [site_id]                  VARCHAR(1000)      NULL,
    [package_name]             VARCHAR(255)       NULL,
    [billing_model]            VARCHAR(50)        NULL,
    [initial_price]            VARCHAR(50)        NULL,
    [currency]                 VARCHAR(10)        NULL,
    [trial_days]               VARCHAR(1000)      NULL,
    [rebill_price]             VARCHAR(50)        NULL,
    [rebill_period]            VARCHAR(50)        NULL,
    [status]                   VARCHAR(50)        NULL,
    [created_date]             VARCHAR(50)        NULL,
    [updated_date]             VARCHAR(50)        NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_packages_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_packages_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.purchases_snapshot', N'U') IS NULL
CREATE TABLE bronze.[purchases_snapshot] (
    [purchase_id]              VARCHAR(1000)      NULL,
    [customer_id]              VARCHAR(64)        NULL,
    [merchant_id]              VARCHAR(64)        NULL,
    [site_id]                  VARCHAR(1000)      NULL,
    [package_id]               VARCHAR(1000)      NULL,
    [purchase_date]            VARCHAR(50)        NULL,
    [purchase_status]          VARCHAR(50)        NULL,
    [cancel_date]              VARCHAR(50)        NULL,
    [cancel_reason]            VARCHAR(255)       NULL,
    [cancel_initiated_by]      VARCHAR(100)       NULL,
    [next_rebill_date]         VARCHAR(50)        NULL,
    [rebill_count]             VARCHAR(20)        NULL,
    [affiliate_id]             VARCHAR(64)        NULL,
    [traffic_source]           VARCHAR(100)       NULL,
    [promo_code]               VARCHAR(100)       NULL,
    [is_trial]                 VARCHAR(20)        NULL,
    [last_updated]             VARCHAR(1000)      NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_purchases_snapshot_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_purchases_snapshot_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.response_codes', N'U') IS NULL
CREATE TABLE bronze.[response_codes] (
    [response_code]            VARCHAR(10)        NULL,
    [description]              VARCHAR(500)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_response_codes_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_response_codes_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.risk_events', N'U') IS NULL
CREATE TABLE bronze.[risk_events] (
    [event_id]                 NVARCHAR(400)      NULL,
    [txn_id]                   NVARCHAR(400)      NULL,
    [purchase_id]              NVARCHAR(400)      NULL,
    [merchant]                 NVARCHAR(400)      NULL,
    [event_ts]                 NVARCHAR(400)      NULL,
    [engine_version]           NVARCHAR(400)      NULL,
    [score]                    NVARCHAR(400)      NULL,
    [decision]                 NVARCHAR(400)      NULL,
    [rules_triggered]          NVARCHAR(MAX)      NULL,
    [signal_ip_country]        NVARCHAR(400)      NULL,
    [signal_bin_country]       NVARCHAR(400)      NULL,
    [signal_email_age_days]    NVARCHAR(400)      NULL,
    [signal_velocity_1h]       NVARCHAR(400)      NULL,
    [signal_proxy]             NVARCHAR(400)      NULL,
    [signal_device_id]         NVARCHAR(400)      NULL,
    [raw_json]                 NVARCHAR(MAX)      NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_risk_events_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_risk_events_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.settlements_weekly', N'U') IS NULL
CREATE TABLE bronze.[settlements_weekly] (
    [settlement_id]            VARCHAR(64)        NULL,
    [merchant_id]              VARCHAR(64)        NULL,
    [period_start]             VARCHAR(50)        NULL,
    [period_end]               VARCHAR(50)        NULL,
    [currency]                 VARCHAR(10)        NULL,
    [gross_sales]              VARCHAR(50)        NULL,
    [refunds]                  VARCHAR(50)        NULL,
    [chargebacks]              VARCHAR(50)        NULL,
    [fees_total]               VARCHAR(50)        NULL,
    [reserve_held]             VARCHAR(50)        NULL,
    [reserve_released]         VARCHAR(50)        NULL,
    [adjustments]              VARCHAR(50)        NULL,
    [adjustment_note]          VARCHAR(500)       NULL,
    [net_payout]               VARCHAR(50)        NULL,
    [payout_date]              VARCHAR(50)        NULL,
    [payout_status]            VARCHAR(50)        NULL,
    [bank_ref]                 VARCHAR(100)       NULL,
    [version]                  VARCHAR(1000)      NULL,
    [created_ts]               VARCHAR(1000)      NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_settlements_weekly_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_settlements_weekly_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.sites', N'U') IS NULL
CREATE TABLE bronze.[sites] (
    [site_id]                  VARCHAR(1000)      NULL,
    [merchant_id]              VARCHAR(64)        NULL,
    [site_name]                VARCHAR(255)       NULL,
    [site_url]                 VARCHAR(500)       NULL,
    [category]                 VARCHAR(100)       NULL,
    [launch_date]              VARCHAR(50)        NULL,
    [status]                   VARCHAR(50)        NULL,
    [billing_descriptor]       VARCHAR(255)       NULL,
    [support_email]            VARCHAR(320)       NULL,
    [source_system]            VARCHAR(50)        NULL,
    [source_file_name]         NVARCHAR(260)      NULL,
    [source_file_path]         NVARCHAR(500)      NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_sites_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_sites_ingested_by] DEFAULT (suser_sname())
);
GO

IF OBJECT_ID(N'bronze.txn_post_migration', N'U') IS NULL
CREATE TABLE bronze.[txn_post_migration] (
    [bronze_id]                BIGINT             IDENTITY(1,1) NOT NULL,
    [txn_id]                   VARCHAR(1000)      NULL,
    [purchase_id]              VARCHAR(1000)      NULL,
    [parent_txn_id]            VARCHAR(1000)      NULL,
    [merchant_id]              VARCHAR(1000)      NULL,
    [site_id]                  VARCHAR(1000)      NULL,
    [package_id]               VARCHAR(1000)      NULL,
    [customer_id]              VARCHAR(1000)      NULL,
    [txn_type]                 VARCHAR(1000)      NULL,
    [amount]                   VARCHAR(1000)      NULL,
    [ccy]                      VARCHAR(1000)      NULL,
    [card_brand]               VARCHAR(1000)      NULL,
    [card_bin]                 VARCHAR(1000)      NULL,
    [card_last4]               VARCHAR(1000)      NULL,
    [payment_method]           VARCHAR(1000)      NULL,
    [response_code]            VARCHAR(1000)      NULL,
    [response_text]            VARCHAR(1000)      NULL,
    [status]                   VARCHAR(1000)      NULL,
    [txn_ts_utc]               VARCHAR(1000)      NULL,
    [settle_date]              VARCHAR(1000)      NULL,
    [acquirer]                 VARCHAR(1000)      NULL,
    [mid]                      VARCHAR(1000)      NULL,
    [three_ds]                 VARCHAR(1000)      NULL,
    [device_type]              VARCHAR(1000)      NULL,
    [ip_address]               VARCHAR(1000)      NULL,
    [ip_country]               VARCHAR(1000)      NULL,
    [affiliate_id]             VARCHAR(1000)      NULL,
    [is_test]                  VARCHAR(1000)      NULL,
    [network_txn_id]           VARCHAR(1000)      NULL,
    [batch_id_source]          VARCHAR(1000)      NULL,
    [load_ts]                  VARCHAR(1000)      NULL,
    [source_system]            VARCHAR(50)        NOT NULL,
    [source_file_name]         NVARCHAR(260)      NOT NULL,
    [source_file_path]         NVARCHAR(500)      NOT NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NOT NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_txn_post_migration_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_txn_post_migration_ingested_by] DEFAULT (suser_sname()),
    CONSTRAINT [PK_bronze_txn_post_migration] PRIMARY KEY CLUSTERED ([bronze_id])
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_bronze_txn_post_migration_file' AND object_id = OBJECT_ID(N'bronze.txn_post_migration'))
    CREATE NONCLUSTERED INDEX [IX_bronze_txn_post_migration_file] ON bronze.[txn_post_migration] ([source_file_name]);
GO

IF OBJECT_ID(N'bronze.txn_pre_migration', N'U') IS NULL
CREATE TABLE bronze.[txn_pre_migration] (
    [bronze_id]                BIGINT             IDENTITY(1,1) NOT NULL,
    [txn_id]                   VARCHAR(1000)      NULL,
    [purchase_id]              VARCHAR(1000)      NULL,
    [parent_txn_id]            VARCHAR(1000)      NULL,
    [merchant_id]              VARCHAR(1000)      NULL,
    [site_id]                  VARCHAR(1000)      NULL,
    [package_id]               VARCHAR(1000)      NULL,
    [customer_id]              VARCHAR(1000)      NULL,
    [txn_type]                 VARCHAR(1000)      NULL,
    [amount]                   VARCHAR(1000)      NULL,
    [currency]                 VARCHAR(1000)      NULL,
    [card_brand]               VARCHAR(1000)      NULL,
    [card_bin]                 VARCHAR(1000)      NULL,
    [card_last4]               VARCHAR(1000)      NULL,
    [payment_method]           VARCHAR(1000)      NULL,
    [response_code]            VARCHAR(1000)      NULL,
    [response_text]            VARCHAR(1000)      NULL,
    [status]                   VARCHAR(1000)      NULL,
    [auth_timestamp]           VARCHAR(1000)      NULL,
    [settle_date]              VARCHAR(1000)      NULL,
    [acquirer]                 VARCHAR(1000)      NULL,
    [mid]                      VARCHAR(1000)      NULL,
    [three_ds]                 VARCHAR(1000)      NULL,
    [device_type]              VARCHAR(1000)      NULL,
    [ip_address]               VARCHAR(1000)      NULL,
    [ip_country]               VARCHAR(1000)      NULL,
    [affiliate_id]             VARCHAR(1000)      NULL,
    [is_test]                  VARCHAR(1000)      NULL,
    [batch_id_source]          VARCHAR(1000)      NULL,
    [load_ts]                  VARCHAR(1000)      NULL,
    [source_system]            VARCHAR(50)        NOT NULL,
    [source_file_name]         NVARCHAR(260)      NOT NULL,
    [source_file_path]         NVARCHAR(500)      NOT NULL,
    [batch_id]                 UNIQUEIDENTIFIER   NOT NULL,
    [ingested_at]              DATETIME2(3)       NOT NULL CONSTRAINT [DF_bronze_txn_pre_migration_ingested_at] DEFAULT (sysutcdatetime()),
    [ingested_by]              NVARCHAR(128)      NOT NULL CONSTRAINT [DF_bronze_txn_pre_migration_ingested_by] DEFAULT (suser_sname()),
    CONSTRAINT [PK_bronze_txn_pre_migration] PRIMARY KEY CLUSTERED ([bronze_id])
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_bronze_txn_pre_migration_file' AND object_id = OBJECT_ID(N'bronze.txn_pre_migration'))
    CREATE NONCLUSTERED INDEX [IX_bronze_txn_pre_migration_file] ON bronze.[txn_pre_migration] ([source_file_name]);
GO

