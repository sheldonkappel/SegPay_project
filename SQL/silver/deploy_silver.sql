/* =====================================================================
   Script    : deploy_silver.sql
   Purpose   : Deploys the whole silver layer in the right order.

   !! Step 2 drops and re-creates every silver table. Silver is rebuilt
      from bronze by step 4 (silver.usp_load_all). !!

   How to run
   ----------
     Command line (from the SQL\silver folder):
       sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_silver.sql

     SSMS: SSMS resolves :r paths from its own folder, so in SSMS run the
     files one at a time in the order below (00, 01, each procedure, then
     EXEC silver.usp_load_all).
     (:r includes the other files; paths are relative to the SQL\silver folder.)

   Order
   -----
     1. 00_foundation.sql     util functions, ref tables, audit.load_log
     2. 01_silver_tables.sql  silver tables (typed), indexes, masking, labels
     3. procedures\*.sql      all load procedures
     4. EXEC silver.usp_load_all
   ===================================================================== */
:on error exit

PRINT N'1/4 Foundation objects';
GO
:r 00_foundation.sql
PRINT N'2/4 Silver tables';
GO
:r 01_silver_tables.sql
PRINT N'3/4 Load procedures';
GO
:r procedures\usp_load_affiliates.sql
:r procedures\usp_load_bin_reference.sql
:r procedures\usp_load_chargeback_reason_codes.sql
:r procedures\usp_load_response_codes.sql
:r procedures\usp_load_fx_rates_daily.sql
:r procedures\usp_load_merchant_accounts.sql
:r procedures\usp_load_merchants_crm_export.sql
:r procedures\usp_load_merchant_xref.sql
:r procedures\usp_load_sites.sql
:r procedures\usp_load_packages.sql
:r procedures\usp_load_customers.sql
:r procedures\usp_load_clicks.sql
:r procedures\usp_load_conversions.sql
:r procedures\usp_load_helpdesk_tickets.sql
:r procedures\usp_load_risk_events.sql
:r procedures\usp_load_settlements_weekly.sql
:r procedures\usp_load_transactions.sql
:r procedures\usp_load_purchases_snapshot.sql
:r procedures\usp_load_chargebacks_acquirer_feed.sql
:r procedures\usp_load_clearing_transactions.sql
:r procedures\usp_load_all.sql
PRINT N'4/4 Load silver';
GO
EXEC silver.usp_load_all;
GO
