/* =====================================================================
   Script    : deploy_bronze.sql
   Purpose   : Deploys the bronze layer: schema, tables and load procedures.

   Safe to re-run: tables are only created if missing (existing bronze data
   is never touched) and procedures use CREATE OR ALTER.

   This script does NOT load any data. To load the files, run the
   PowerShell loader:
       ..\..\PowerShell scripts\Load-All.ps1            (bronze only)
       ..\..\PowerShell scripts\Load-All.ps1 -LoadSilver (bronze, then silver)

   How to run (from the SQL\bronze folder - :r paths are relative):
       sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_bronze.sql
   In SSMS, run 01_bronze_tables.sql, then each file in procedures\.
   ===================================================================== */
:on error exit

PRINT N'1/2 Bronze schema and tables';
GO
:r 01_bronze_tables.sql

PRINT N'2/2 Bronze load procedures';
GO
:r procedures\usp_load_affiliates.sql
:r procedures\usp_load_bin_reference.sql
:r procedures\usp_load_chargeback_reason_codes.sql
:r procedures\usp_load_chargebacks_acquirer_feed.sql
:r procedures\usp_load_clearing_transactions.sql
:r procedures\usp_load_clicks.sql
:r procedures\usp_load_conversions.sql
:r procedures\usp_load_customers.sql
:r procedures\usp_load_fx_rates_daily.sql
:r procedures\usp_load_helpdesk_tickets.sql
:r procedures\usp_load_merchant_accounts.sql
:r procedures\usp_load_merchant_xref.sql
:r procedures\usp_load_merchants_crm_export.sql
:r procedures\usp_load_packages.sql
:r procedures\usp_load_purchases_snapshot.sql
:r procedures\usp_load_response_codes.sql
:r procedures\usp_load_risk_events.sql
:r procedures\usp_load_settlements_weekly.sql
:r procedures\usp_load_sites.sql
:r procedures\usp_load_txn_post_migration.sql
:r procedures\usp_load_txn_pre_migration.sql

PRINT N'Bronze deployed. Load data with PowerShell scripts\Load-All.ps1';
GO
