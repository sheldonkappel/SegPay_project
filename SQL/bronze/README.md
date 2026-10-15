# Bronze layer – SegPay

Bronze holds the source files exactly as received. Every column is text, and nothing is cleaned or converted (silver does that). Each row records the file it came from and when it was loaded.

## Folder layout

| Path | What it is |
|---|---|
| `01_bronze_tables.sql` | The `bronze` schema and all 21 tables. Creates only missing tables, so it never touches existing data. |
| `procedures\usp_load_*.sql` | One load procedure per table. Each reads one file from disk (CSV, TXT, XML or JSON Lines) into its table. |
| `deploy_bronze.sql` | Runs the two items above in order. Loads no data. |

## Loading data

Use the PowerShell loader in `Segpay Project\PowerShell scripts`:

```powershell
.\Load-All.ps1                          # all 21 bronze tables
.\Load-All.ps1 -LoadSilver              # bronze, then rebuild silver
.\Load-All.ps1 -LoadGold                # bronze, silver, gold, then the tests (SQL\tests)
.\Load-All.ps1 -Only sites, packages    # selected tables only
.\Load-All.ps1 -FullRefresh             # empty multi-file tables first
```

`Load-All.ps1` loads the 17 single-file sources itself and calls the existing import scripts for the four multi-file sources:

| Table | Files | Loaded by |
|---|---|---|
| txn_pre_migration | `txn\transactions_*.csv` (old layout: `currency`) | `Import-TxnPreMigration.ps1` |
| txn_post_migration | `txn\transactions_*.csv` (new layout: `ccy`) | `Import-TxnPostMigration.ps1` |
| clearing_transactions | `acquirer_clearing\*.xml` | `Import-ClearingFiles.ps1` |
| risk_events | `risk\*.jsonl` | `Import-RiskEvents.ps1` |

Each run prints a summary (rows and seconds per table) and writes a log to `Segpay Project\logs\`. The script exits with code 1 if anything failed, so it can be scheduled with Windows Task Scheduler.

A full load (about 280 files) takes about 45 seconds; with `-LoadSilver`, about 95 seconds.

## How the load procedures behave

- **Re-running is safe.** Before inserting, a procedure deletes any rows previously loaded from a file with the same name, so a file is replaced, not duplicated.
- **All or nothing per file.** The file is staged first, then the delete and insert happen in one transaction with a row-count check. Any error leaves bronze as it was.
- **Load metadata** on every row:
  - `source_system`, `source_file_name`, `source_file_path`
  - `batch_id`, a new GUID per load
  - `ingested_at` and `ingested_by`, filled by column defaults
- **Paths are server-side.** BULK INSERT and OPENROWSET read files as the SQL Server service, so the files must be on a path that service can read.

## Migrations

One-time changes to existing objects or data live in `migrations\`. They're named by date and run once, in order. Each one is safe to run again.

| Migration | What it did |
|---|---|
| `2026-10-15_01_ingested_at_utc.sql` | Converted the two transaction tables' `ingested_at` from US Eastern to UTC (231,399 rows) and switched their defaults to `SYSUTCDATETIME()`, so all bronze load times are UTC. Also gave every default constraint a standard name, `DF_bronze_<table>_<column>`. |

`01_bronze_tables.sql` always shows the current state, so a new environment built from it needs no migrations.
