# SegPay data warehouse – SQL source

All database code for the SegPay warehouse, kept as files. The files are the master copy; the database is where they run. To change an object, edit its file here, then run that file. Don't edit procedures only in SSMS.

```
Segpay Project\
├── AI generated data\     source files (CSV, TXT, XML, JSONL)
├── PowerShell scripts\    Load-All.ps1 + per-source import scripts
├── logs\                  one log file per Load-All.ps1 run
└── SQL\
    ├── bronze\            raw layer: files loaded as received (all text)
    ├── silver\            cleaned layer: typed, de-duplicated, one table per source
    ├── gold\              reporting layer: star schema (dimensions, facts, summaries)
    ├── audit\             change auditing: triggers that log hand-made changes
    └── tests\             automated tests, run after every full refresh
```

## Layers

| Layer | Schema | Built by | Holds |
|---|---|---|---|
| Bronze | `bronze` | `PowerShell scripts\Load-All.ps1` | Each source file as received, plus load metadata |
| Silver | `silver` (plus `util`, `ref`, `audit`) | `EXEC silver.usp_load_all` | Cleaned, typed, de-duplicated data, with test data removed |
| Gold | `gold` | `EXEC gold.usp_load_all` | Star schema for reporting: dimensions, facts, chargeback monitoring |

## What is logged

Every change to the database leaves a record. Each kind of change is recorded in one place:

| Change | Recorded by | Table |
|---|---|---|
| A load procedure run: rows read, loaded, removed and why | Each load procedure | `audit.load_log` |
| A row inserted, updated or deleted in a `ref` table (business rules edited by hand) | A trigger on each `ref` table | `audit.data_change_log` |
| A table, view, procedure, function, trigger, index or schema created, altered or dropped | A database-level trigger | `audit.schema_change_log` (read it through `audit.v_schema_change_log`) |
| A test run: each test's result and why it failed | `test.usp_run_all` | `audit.test_result` |

Bronze, silver and gold tables have no triggers: they're written only by the load procedures, which already log every run. See `audit\README.md` for the details and example queries.

## Everyday use

```powershell
# Load new files into bronze, rebuild silver and gold, then run the tests
& "C:\Users\Sheldon\Desktop\Segpay Project\PowerShell scripts\Load-All.ps1" -LoadGold

# Bronze + silver only
& "C:\Users\Sheldon\Desktop\Segpay Project\PowerShell scripts\Load-All.ps1" -LoadSilver
```

## Building a new environment from scratch

```
cd SQL\bronze
sqlcmd -S <server> -E -C -d SegPay -b -I -i deploy_bronze.sql  # bronze tables + procedures
<run PowerShell scripts\Load-All.ps1>                          # load the files
cd ..\silver
sqlcmd -S <server> -E -C -d SegPay -b -I -i deploy_silver.sql  # silver objects + first load
cd ..\gold
sqlcmd -S <server> -E -C -d SegPay -b -I -i deploy_gold.sql    # gold objects + first load
cd ..\audit
sqlcmd -S <server> -E -C -d SegPay -b -I -i deploy_audit.sql   # audit tables + triggers
cd ..\tests
sqlcmd -S <server> -E -C -d SegPay -b -I -i deploy_tests.sql   # tests, then run them
```

Deploy `audit` after silver and gold: its triggers attach to the `ref` tables, which the silver and gold foundation scripts create. Re-run it whenever a table is added to the `ref` schema. Deploy `tests` last; it fails if anything is wrong.

**Use `-I` with sqlcmd.** sqlcmd turns `QUOTED_IDENTIFIER` off unless `-I` is given, and a procedure keeps the setting it was created with. Procedures that use XML functions fail without it (this broke the clearing-file load once). Scripts that need it now set it themselves, and the `bronze_xml_settings` test checks it.

See `bronze\README.md`, `silver\README.md`, `gold\README.md`, `audit\README.md` and `tests\README.md` for details of each part.
