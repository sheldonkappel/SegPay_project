# SegPay data warehouse – SQL source

All database code for the SegPay warehouse, kept as files. The files are the master copy; the database is where they run. To change an object, edit its file here, then run that file. Don't edit procedures only in SSMS.

```
Segpay Project\
├── AI generated data\     source files (CSV, TXT, XML, JSONL)
├── PowerShell scripts\    Load-All.ps1 + per-source import scripts
├── logs\                  one log file per Load-All.ps1 run
└── SQL\
    ├── bronze\            raw layer: files loaded as received (all text)
    └── silver\            cleaned layer: typed, de-duplicated, one table per source
```

## Layers

| Layer | Schema | Built by | Holds |
|---|---|---|---|
| Bronze | `bronze` | `PowerShell scripts\Load-All.ps1` | Each source file as received, plus load metadata |
| Silver | `silver` (plus `util`, `ref`, `audit`) | `EXEC silver.usp_load_all` | Cleaned, typed, de-duplicated data, with test data removed |

## Everyday use

```powershell
# Load new files into bronze, then rebuild silver
& "C:\Users\Sheldon\Desktop\Segpay Project\PowerShell scripts\Load-All.ps1" -LoadSilver
```

## Building a new environment from scratch

```
cd SQL\bronze
sqlcmd -S <server> -E -C -d SegPay -b -i deploy_bronze.sql     # bronze tables + procedures
<run PowerShell scripts\Load-All.ps1>                          # load the files
cd ..\silver
sqlcmd -S <server> -E -C -d SegPay -b -i deploy_silver.sql     # silver objects + first load
```

See `bronze\README.md` and `silver\README.md` for details of each layer.
