# Gold layer – SegPay

Gold is the reporting layer: a **star schema** built from silver. Dimensions describe who, what and when; facts record the events and their amounts; summary views answer the main business questions directly. Point Power BI, Excel or SQL queries here, not at silver.

## Folder layout

| Path | What it is |
|---|---|
| `00_gold_foundation.sql` | `gold` schema and the business-rule tables `ref.response_code_class` and `ref.chargeback_monitoring_program`. |
| `01_gold_tables.sql` | All gold tables. Creates only missing tables, so dimension keys and merchant history are never lost. |
| `02_gold_views.sql` | Summary views, calculated from the facts when queried. |
| `procedures\` | One load procedure per table, plus `usp_load_all`. |
| `tools\New-Type1DimProcedures.ps1` | Generates the 8 type-1 dimension procedures from one template. Edit the spec there and regenerate; don't hand-edit those files. |
| `deploy_gold.sql` | Deploys everything above and builds gold. Run it from this folder. |

## Tables

### Dimensions

| Table | One row per | Notes |
|---|---|---|
| `dim_date` | calendar day, 2017–2030 | `date_key` = YYYYMMDD; ISO weekday and week |
| `dim_merchant` | **merchant version** | Keeps history (type 2): a change to status, risk tier, vertical, MCC or pricing adds a new version. History starts 2026-10-15. |
| `dim_merchant_account` | MID (acquirer account) | |
| `dim_site` | site | |
| `dim_package` | package | |
| `dim_customer` | customer | No email or postal code; personal data stays in silver. |
| `dim_affiliate` | affiliate | Key −1 = Unknown / Direct traffic |
| `dim_card_bin` | 6-digit BIN | Brand, credit/debit/prepaid, tier, issuer, issuer country |
| `dim_response_code` | authorization response code | Approved / soft decline / hard decline (`ref.response_code_class`) |
| `dim_chargeback_reason` | network + reason code | Category: Fraud / Consumer Dispute / … |

Every dimension has an **Unknown** row (key −1), so facts with a missing reference still appear in reports.

### Facts

| Table | One row per | Main measures |
|---|---|---|
| `fact_transaction` | payment event | `amount_usd` (signed), `revenue_usd`, `is_approved`, `is_revenue`, `risk_score` |
| `fact_chargeback` | dispute case | `dispute_amount_usd`, `is_won` / `is_lost` / `is_open`, days from sale to dispute, response window |

Facts point to the **merchant version in effect on the event date**, so a March sale shows the risk tier the merchant had in March.

### Summaries (views)

| View | One row per | Answers |
|---|---|---|
| `agg_chargeback_monitoring` | merchant × card network × month | Chargeback ratio, calculated both as this month's chargebacks over this month's sales (Visa style) and over last month's sales (Mastercard style). Shows the monitoring program breached (`ref.chargeback_monitoring_program`) and raises a ratio-only early warning once there are at least `min_sales_for_warning` sales (20). |

Summaries are views, so they are always in step with the facts and pick up a change to the rules in `ref.chargeback_monitoring_program` immediately, with no reload. The full view returns in under 0.1 s today; if it ever becomes slow, it can be turned back into a table.

**The thresholds in `ref.chargeback_monitoring_program` are illustrative.** Confirm the networks' current rules with the acquirers and update the rows.

## Loading

```powershell
.\Load-All.ps1 -LoadGold      # bronze -> silver -> gold (from PowerShell scripts\)
```
```sql
EXEC gold.usp_load_all;       -- gold only, from the current silver (about 8 seconds)
```

- **Dimensions** are updated in place (MERGE). Re-running changes nothing unless silver changed. Rows that disappear from silver are flagged `is_deleted = 1`, never deleted.
- **Facts** are rebuilt each run. **Summary views** need no load.
- **Logging:** every step writes to `audit.load_log` with its counts (e.g. how many transactions mapped to an Unknown dimension row).

## Example queries

```sql
-- Monthly revenue and approval rate by merchant risk tier (as it was at the time)
SELECT d.year_month, m.risk_tier,
       SUM(f.revenue_usd)                                  AS revenue_usd,
       AVG(CAST(f.is_approved AS DECIMAL(5,4)))            AS approval_rate
FROM gold.fact_transaction f
JOIN gold.dim_date d     ON d.date_key = f.date_key
JOIN gold.dim_merchant m ON m.merchant_key = f.merchant_key
WHERE f.txn_type IN ('Sale', 'Rebill')
GROUP BY d.year_month, m.risk_tier
ORDER BY d.year_month, m.risk_tier;

-- Merchants with a chargeback-ratio warning this year
SELECT m.dba_name, a.network, a.year_month, a.sales_count, a.chargeback_count,
       a.cb_ratio_same_month, a.program_name
FROM gold.agg_chargeback_monitoring a
JOIN gold.dim_merchant m ON m.merchant_key = a.merchant_key
WHERE a.ratio_over_threshold = 1 AND a.month_start_date >= '2026-01-01'
ORDER BY a.cb_ratio_same_month DESC;

-- Soft vs hard declines on rebills (retry opportunity)
SELECT r.decline_type, COUNT(*) AS declines, SUM(-f.amount_usd) AS usd_at_stake
FROM gold.fact_transaction f
JOIN gold.dim_response_code r ON r.response_code_key = f.response_code_key
WHERE f.txn_type = 'Rebill' AND f.status = 'Declined'
GROUP BY r.decline_type;
```

## Changing gold tables

Gold tables are never dropped by the scripts, so the merchant keys and history survive. To change a table's structure, add a dated script under `migrations\`, the same way as bronze.

## Planned next

`fact_purchase` (subscriptions), `fact_settlement` with reconciliation, affiliate performance, risk engine performance, support tickets.
