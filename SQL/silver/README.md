# Silver layer – SegPay

The silver layer cleans the raw text in `bronze` into typed, de-duplicated tables, one per source. Every table is fully rebuilt from bronze on each run.

## Folder layout

| Path | What it is |
|---|---|
| `00_foundation.sql` | Shared objects: `util` parsing functions, `ref` mapping tables, `audit.load_log`. Safe to re-run. |
| `01_silver_tables.sql` | All silver tables: typed columns, indexes, data masking, sensitivity labels. **Drops and re-creates every silver table.** |
| `procedures\usp_load_*.sql` | One load procedure per table, plus `usp_load_all`. |
| `deploy_silver.sql` | Runs everything above in order, then loads silver. |
| `_archive\` | The procedures as they were before the 2026-10-15 refactor. |

## Deploy or rebuild everything

From this folder:

```
sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_silver.sql
```

## Reload silver (daily use)

```sql
EXEC silver.usp_load_all;
```

This runs all 20 load procedures in dependency order (about 1 minute) and returns a run log. Any procedure can also be run on its own, e.g. `EXEC silver.usp_load_sites;`. Load its dependencies first; they are listed in each procedure's header.

## Conventions

- **Real data types.** Dates are `DATE` / `DATETIME2` (UTC), amounts are `DECIMAL`, flags are `BIT`. Missing or unreadable values are `NULL`.
- **Shared cleaning rules.** All procedures parse values the same way:
  - `util.fn_parse_date`: every date format in the sources. Slash dates are read US month/day first, and day-first only when the US reading is impossible. Some procedures check ambiguous dates against another date first.
  - `util.fn_parse_amount`: handles `$`, thousands commas, decimal commas and `(0.99)`.
  - `util.fn_parse_flag`: handles Y/N, TRUE/FALSE and 1/0.
  - `util.fn_clean_text`: turns 'N/A', 'NULL', '-' and similar placeholders into NULL.
- **Mapping tables:**
  - `ref.country_alias`, `ref.card_brand_alias` and `ref.acquirer_alias`. Add a row when a new spelling appears.
  - `ref.test_merchant` and `ref.v_test_site` define the test data, which every procedure excludes.
  - Every insert, update and delete in a `ref` table is logged to `audit.data_change_log` by a trigger: who, when, and the row before and after (see `SQL\audit\README.md`).
- **Inferred values are flagged.** `transactions.merchant_id_inferred` marks old-gateway merchants mapped through the risk engine. `transactions.site_id_inferred` marks sites taken from the package.
- **Lineage.** Every row keeps `source_system`, `source_file_name`, `batch_id`, `bronze_ingested_at` and `ingested_by` from bronze. It also gets `load_run_id` (the silver run) and `silver_loaded_at`.
- **Personal data.** Emails, IPs and postal codes are masked for users without the `UNMASK` permission. Sensitive columns carry SQL Server sensitivity labels.

## Monitoring

Every procedure writes one row to `audit.load_log`, whether it succeeds or fails:

```sql
-- Latest runs
SELECT TOP 50 run_id, proc_name, status, rows_read, rows_loaded, rows_excluded, rows_dropped,
       duration_ms, error_message, metrics
FROM audit.load_log ORDER BY log_id DESC;
```

`metrics` holds each procedure's full summary as JSON (for example the count of missing dates or unmapped countries). Comparing it across runs shows when a new bronze file brings new problems.

## Adding a new silver table

1. Add the table to `01_silver_tables.sql`, following the column and lineage conventions.
2. Copy an existing procedure as a template. Keep the header, the TRY/CATCH block and the `audit.usp_log_load` calls.
3. Add the procedure to `deploy_silver.sql` and to the step list in `usp_load_all.sql`, in the stage that matches what it reads.
