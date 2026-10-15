/* =====================================================================
   Script    : 02_gold_views.sql
   Purpose   : Gold views - summaries calculated on read from the facts,
               so they are always in step with the latest gold load and
               with the current rules in the ref tables.
               Safe to re-run (CREATE OR ALTER).

   Views
   -----
     gold.agg_chargeback_monitoring  - chargeback ratio per merchant,
                                       card network and month
   ===================================================================== */
SET NOCOUNT ON;
GO

-- Until 2026-10-15 this summary was a table rebuilt by
-- gold.usp_load_agg_chargeback_monitoring. It holds no history of its own
-- (fully derived from the facts), so the table and procedure are simply dropped.
IF OBJECT_ID(N'gold.agg_chargeback_monitoring', N'U') IS NOT NULL
    DROP TABLE gold.agg_chargeback_monitoring;
DROP PROCEDURE IF EXISTS gold.usp_load_agg_chargeback_monitoring;
GO

/* =====================================================================
   View      : gold.agg_chargeback_monitoring
   Grain     : one row per merchant, card network and month
   Source    : gold.fact_transaction, gold.fact_chargeback,
               ref.chargeback_monitoring_program

   Card networks put merchants into monitoring programs - with fines and,
   eventually, termination - when their chargebacks exceed a ratio and a
   minimum count in a month. This view shows every merchant's ratio per
   network per month and which program (if any) it falls into, so risk
   teams can act before the network does.

   Columns
   -------
     sales_count            approved Sales + Rebills on the network that month
     chargeback_count       disputes RECEIVED that month on the network
     cb_ratio_same_month    chargebacks / sales the same month   (Visa style)
     cb_ratio_prior_month   chargebacks / sales the previous month (Mastercard style)
     program_name           most severe program in ref.chargeback_monitoring_program
                            whose ratio AND count thresholds are both met,
                            using the ratio basis that program specifies
     ratio_over_threshold   early warning: the ratio alone exceeds the network's
                            lowest program ratio, and the sales it divides by
                            reach that program's min_sales_for_warning (20) -
                            1 chargeback on 1 sale is 100% but means nothing
     merchant_key           the merchant's CURRENT version (slice by today's
                            risk tier, status, etc.)
   A month with sales but no chargebacks (or the reverse) still gets a row.

   !! Thresholds in ref.chargeback_monitoring_program are illustrative -
      confirm the current network rules and update that table. !!

   For heavy dashboard use, filter on month_start_date / merchant_id;
   if it ever gets slow, materialize it again as a table.
   ===================================================================== */
CREATE OR ALTER VIEW gold.agg_chargeback_monitoring
AS
WITH sales AS (
    -- Approved sales + rebills per merchant, network, month
    SELECT dm.merchant_id, ft.card_brand AS network, dd.month_start_date,
           COUNT(*) AS sales_count, SUM(ft.revenue_usd) AS sales_usd
    FROM gold.fact_transaction ft
    JOIN gold.dim_merchant dm ON dm.merchant_key = ft.merchant_key
    JOIN gold.dim_date     dd ON dd.date_key     = ft.date_key
    WHERE ft.is_revenue = 1 AND ft.card_brand IS NOT NULL AND dm.merchant_key <> -1 AND dd.date_key <> -1
    GROUP BY dm.merchant_id, ft.card_brand, dd.month_start_date
),
cbs AS (
    -- Chargebacks per merchant, network, month received
    SELECT dm.merchant_id, fc.network, dd.month_start_date,
           COUNT(*) AS chargeback_count,
           SUM(COALESCE(fc.dispute_amount_usd, 0)) AS chargeback_usd,
           SUM(CASE WHEN cr.category = 'Fraud' THEN 1 ELSE 0 END) AS fraud_chargeback_count
    FROM gold.fact_chargeback fc
    JOIN gold.dim_merchant          dm ON dm.merchant_key = fc.merchant_key
    JOIN gold.dim_date              dd ON dd.date_key     = fc.received_date_key
    JOIN gold.dim_chargeback_reason cr ON cr.chargeback_reason_key = fc.chargeback_reason_key
    WHERE fc.network IS NOT NULL AND dm.merchant_key <> -1 AND dd.date_key <> -1
    GROUP BY dm.merchant_id, fc.network, dd.month_start_date
),
grid AS (
    SELECT COALESCE(s.merchant_id, c.merchant_id)           AS merchant_id,
           COALESCE(s.network, c.network)                   AS network,
           COALESCE(s.month_start_date, c.month_start_date) AS month_start_date,
           ISNULL(s.sales_count, 0)                         AS sales_count,
           ISNULL(s.sales_usd, 0)                           AS sales_usd,
           ISNULL(c.chargeback_count, 0)                    AS chargeback_count,
           ISNULL(c.chargeback_usd, 0)                      AS chargeback_usd,
           ISNULL(c.fraud_chargeback_count, 0)              AS fraud_chargeback_count
    FROM sales s
    FULL JOIN cbs c
      ON c.merchant_id = s.merchant_id AND c.network = s.network AND c.month_start_date = s.month_start_date
),
r AS (
    SELECT g.*,
           ISNULL(p.sales_count, 0) AS prior_month_sales_count,
           CAST(g.chargeback_count * 1.0 / NULLIF(g.sales_count, 0) AS DECIMAL(9,6))           AS cb_ratio_same_month,
           CAST(g.chargeback_count * 1.0 / NULLIF(ISNULL(p.sales_count, 0), 0) AS DECIMAL(9,6)) AS cb_ratio_prior_month
    FROM grid g
    LEFT JOIN sales p
      ON p.merchant_id = g.merchant_id AND p.network = g.network
     AND p.month_start_date = DATEADD(MONTH, -1, g.month_start_date)
)
SELECT
    r.merchant_id,
    r.network,
    r.month_start_date,
    CONVERT(CHAR(7), r.month_start_date, 23)  AS year_month,
    COALESCE(cur.merchant_key, -1)            AS merchant_key,
    r.sales_count,
    r.sales_usd,
    r.prior_month_sales_count,
    r.chargeback_count,
    r.chargeback_usd,
    r.fraud_chargeback_count,
    r.cb_ratio_same_month,
    r.cb_ratio_prior_month,
    pg.program_name,
    pg.severity                               AS program_severity,
    -- Early warning: ratio over the lowest threshold, backed by enough sales to mean something
    CAST(CASE WHEN lo.min_ratio IS NOT NULL
               AND CASE lo.ratio_basis WHEN 'same_month' THEN r.cb_ratio_same_month ELSE r.cb_ratio_prior_month END >= lo.min_ratio
               AND CASE lo.ratio_basis WHEN 'same_month' THEN r.sales_count ELSE r.prior_month_sales_count END >= lo.min_sales_for_warning
              THEN 1 ELSE 0 END AS BIT)       AS ratio_over_threshold
FROM r
LEFT JOIN gold.dim_merchant cur ON cur.merchant_id = r.merchant_id AND cur.is_current = 1
-- Most severe program breached (ratio AND count)
OUTER APPLY (
    SELECT TOP (1) p.program_name, p.severity
    FROM ref.chargeback_monitoring_program p
    WHERE p.network = r.network
      AND r.chargeback_count >= p.min_count
      AND CASE p.ratio_basis WHEN 'same_month' THEN r.cb_ratio_same_month ELSE r.cb_ratio_prior_month END >= p.min_ratio
    ORDER BY p.severity DESC
) pg
-- The network's lowest threshold, for the ratio-only early warning
OUTER APPLY (
    SELECT TOP (1) p.min_ratio, p.ratio_basis, p.min_sales_for_warning
    FROM ref.chargeback_monitoring_program p
    WHERE p.network = r.network
    ORDER BY p.severity ASC
) lo;
GO
