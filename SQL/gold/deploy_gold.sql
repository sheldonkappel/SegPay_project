/* =====================================================================
   Script    : deploy_gold.sql
   Purpose   : Deploys the gold layer (schema, reference rules, tables,
               views, procedures) and builds it from silver.

   Safe to re-run: tables are created only if missing (dimension keys and
   merchant history are never lost); views and procedures use
   CREATE OR ALTER.

   How to run (from the SQL\gold folder - :r paths are relative):
       sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -i deploy_gold.sql
   Requires the silver layer (SQL\silver\deploy_silver.sql).
   ===================================================================== */
:on error exit

PRINT N'1/5 Gold schema and reference rules';
GO
:r 00_gold_foundation.sql

PRINT N'2/5 Gold tables';
GO
:r 01_gold_tables.sql

PRINT N'3/5 Gold views';
GO
:r 02_gold_views.sql

PRINT N'4/5 Gold procedures';
GO
:r procedures\usp_load_dim_date.sql
:r procedures\usp_load_dim_merchant.sql
:r procedures\usp_load_dim_merchant_account.sql
:r procedures\usp_load_dim_site.sql
:r procedures\usp_load_dim_package.sql
:r procedures\usp_load_dim_customer.sql
:r procedures\usp_load_dim_affiliate.sql
:r procedures\usp_load_dim_card_bin.sql
:r procedures\usp_load_dim_response_code.sql
:r procedures\usp_load_dim_chargeback_reason.sql
:r procedures\usp_load_fact_transaction.sql
:r procedures\usp_load_fact_chargeback.sql
:r procedures\usp_load_all.sql

PRINT N'5/5 Build gold';
GO
EXEC gold.usp_load_all;
GO
