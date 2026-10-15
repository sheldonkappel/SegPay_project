# Automated tests – SegPay

22 tests that check the warehouse after every refresh: the shared cleaning functions, the silver data and load logs, the gold star schema, and the audit triggers. They're written in T-SQL with a small built-in framework, so nothing extra needs installing.

## Running them

```sql
EXEC test.usp_run_all;                         -- all tests
EXEC test.usp_run_all @area = 'gold';          -- one area: util, bronze, silver, gold, audit
EXEC test.usp_run_all @fail_on_error = 0;      -- report only, never raise an error
EXEC test.usp_test_gold_reconcile_transactions;  -- one test on its own
```

They also run automatically at the end of the full pipeline:

```powershell
.\Load-All.ps1 -LoadGold              # bronze, silver, gold, then tests
.\Load-All.ps1 -LoadSilver -RunTests  # tests after a partial load
.\Load-All.ps1 -LoadGold -SkipTests   # no tests
```

A failed test fails the `Load-All.ps1` run (exit code 1), and the summary lists each failed test and what it found. A full run of all tests takes about 15 seconds.

## Folder layout

| Path | What it is |
|---|---|
| `00_test_framework.sql` | The `test` schema, the results table `audit.test_result`, the asserts and the runner `test.usp_run_all` |
| `01_util_tests.sql` | Cleaning-function tests |
| `02_silver_tests.sql` | Silver tests, plus the bronze XML-settings test |
| `03_gold_tests.sql` | Gold tests |
| `04_audit_tests.sql` | Audit-trigger tests |
| `deploy_tests.sql` | Deploys everything above, then runs all tests |

## The tests

| Area | Test | Checks |
|---|---|---|
| util | `parse_date` | 19 date inputs from the sources (ISO, `20240930`, `30-Sep-24`, `Aug 24, 2026`, `03/04/2025`, `25/12/2024`, impossible dates, `N/A` …) give the right date; ambiguous slash dates read US first |
| util | `parse_amount` | `$79.95`, `1,671.14`, decimal comma `9,00`, accounting negative `(67.95)` and others |
| util | `parse_flag` | `TRUE` / `Y` / `yes` / `1` → 1, `FALSE` / `N` / `no` / `0` → 0, anything else → empty |
| util | `clean_text` | Trims; `N/A`, `NA`, `NULL`, `None`, `-` and blanks become empty; `Nancy` doesn't |
| bronze | `xml_settings` | Every procedure using XML functions was created with `QUOTED_IDENTIFIER ON` (see below) |
| silver | `load_counts_balance` | For each table's latest load: rows read = rows loaded + test rows excluded + rows dropped |
| silver | `row_counts_match_log` | Each table holds exactly the rows its latest load reported |
| silver | `no_test_merchants` | No test merchant in any silver table with a `merchant_id` (found automatically) |
| silver | `transaction_signs` | Refunds, voids and chargebacks negative; sales, rebills and auths not negative |
| silver | `usd_amounts` | USD amounts convert to themselves; conversion never flips the sign |
| silver | `no_placeholder_text` | No `N/A`, `NULL`, `NONE`, `-` or empty text in any silver text column (found automatically) |
| gold | `reconcile_transactions` | Fact row count, total USD and revenue equal silver to the cent |
| gold | `reconcile_chargebacks` | Fact row count and disputed USD equal silver |
| gold | `unknown_members` | Every dimension has its Unknown (−1) row |
| gold | `no_orphan_keys` | All 20 fact-to-dimension keys point at existing dimension rows |
| gold | `no_unknown_date_or_merchant` | No fact row has an Unknown date or merchant |
| gold | `merchant_history` | One current version per merchant; versions follow on with no gaps or overlaps |
| gold | `dim_date_continuous` | No missing days in `dim_date` |
| gold | `monitoring_view_totals` | `agg_chargeback_monitoring` totals equal the facts |
| audit | `ref_triggers` | Every `ref` table has its enabled audit trigger |
| audit | `schema_trigger` | The schema-change trigger exists and is enabled |
| audit | `change_is_logged` | An insert, update and delete on a `ref` table are each logged with before and after values |

Tests that say "found automatically" read the table and column list from the database, so a new table is covered without changing the test.

## How it works

- **A test is a stored procedure** named `test.usp_test_<area>_<name>`. The runner finds every procedure with that pattern, so adding a test only means creating the procedure.
- **A test passes if it finishes without an error.** It fails through `test.usp_assert_zero` (expects a count of 0) or `test.usp_assert_equal`, which raise errors 50100–50199 with a message saying what's wrong. Any other error (a typo, a missing table) is reported as **Error** rather than **Failed**.
- **Tests never change data.** The runner runs each test inside a transaction and always rolls it back. That's how `change_is_logged` can insert into a `ref` table safely.
- **Every result is kept** in `audit.test_result`: one row per test per run, with status, message, duration, time and who ran it.

```sql
-- Latest run
SELECT area, test_name, status, duration_ms, message
FROM audit.test_result
WHERE run_id = (SELECT TOP 1 run_id FROM audit.test_result ORDER BY result_id DESC)
ORDER BY result_id;
```

## Were the tests themselves tested?

Yes. Each data test was run against deliberately broken data, inside a transaction that was rolled back, and each one failed with a message pointing at the problem:

| Broken on purpose | Test that caught it | Message |
|---|---|---|
| One gold amount changed by 1 cent | `reconcile_transactions` | expected 7380258.25, found 7380258.26 |
| A transaction moved to test merchant MRC-99999 | `no_test_merchants` | silver.transactions: 1 |
| `N/A` written into a site name; an empty vertical | `no_placeholder_text` | silver.sites.site_name: 1 |
| A refund made positive | `transaction_signs` | found 1 |
| A second current version of a merchant | `merchant_history` | MRC-00001 (2) |
| A chargeback pointed at a missing site | `no_orphan_keys` | fact_chargeback.site_key: 1 |
| An audit trigger disabled | `ref_triggers` | ref.acquirer_alias |
| A load log that doesn't add up | `load_counts_balance` | read 231399 <> loaded 229389 + excluded 637 + dropped 1374 |

## A real problem the tests found

The first full pipeline run with tests (2026-10-15) found that the acquirer clearing XML files had stopped loading. Earlier that day the bronze procedures had been redeployed with sqlcmd, which turns `QUOTED_IDENTIFIER` off by default. A procedure keeps the setting it was created with, and SQL Server's XML functions refuse to run without it. The procedure file now sets the option itself, and the `bronze_xml_settings` test fails if any XML-using procedure is ever created without it again.

## Adding a test

1. Create `test.usp_test_<area>_<name>` in the matching file. Start from an existing test.
2. Count the problem rows and call `EXEC test.usp_assert_zero @count, N'<what was counted>', @examples;`, or compare two values with `test.usp_assert_equal`.
3. Run `deploy_tests.sql`. Then break the data on purpose, inside `BEGIN TRAN … ROLLBACK`, and check the new test fails.

## Deploying

From this folder, after the other layers:

```
sqlcmd -S "DESKTOP-G6OG89D\SQLEXPRESS10" -E -C -d SegPay -b -I -i deploy_tests.sql
```

This deploys the tests and runs them; it exits with an error if any test fails.
