<#
.SYNOPSIS
    Loads every source file into the bronze layer (and optionally rebuilds silver).

.DESCRIPTION
    One command for the whole bronze load:

      1. Single-file sources (17 tables) - calls each bronze.usp_load_<table>
         procedure with the file's path under -DataRoot.
      2. Multi-file sources - runs the existing import scripts in this folder:
           Import-TxnPreMigration.ps1   transactions_*.csv (old gateway layout)
           Import-TxnPostMigration.ps1  transactions_*.csv (new gateway layout)
           Import-ClearingFiles.ps1     acquirer_clearing\*.xml
           Import-RiskEvents.ps1        risk\*.jsonl
      3. Optional (-LoadSilver): EXEC silver.usp_load_all.
      4. Optional (-LoadGold): silver, then EXEC gold.usp_load_all.

    Every bronze procedure replaces the rows of the file it loads (matched by
    file name), so re-running is safe and never duplicates data.

    A summary table is printed at the end and the whole run is written to a
    log file in ..\logs. The script exits with code 1 if anything failed, so
    it can be scheduled (e.g. Windows Task Scheduler) and monitored.

.PARAMETER DataRoot
    Folder holding the source files ("AI generated data"). The bronze
    procedures read files on the SQL Server machine, so this must be a path
    the SQL Server service can read.

.PARAMETER Only
    Load just these tables, e.g. -Only sites, packages, txn_pre_migration.

.PARAMETER FullRefresh
    Empty each multi-file bronze table before loading it (passed on to the
    import scripts). Single-file tables are always fully replaced anyway.

.PARAMETER LoadGold
    After bronze succeeds, rebuild silver and then gold (gold reads silver,
    so this implies -LoadSilver).

.PARAMETER LoadSilver
    After bronze succeeds, rebuild silver with silver.usp_load_all.

.PARAMETER StopOnError
    Stop at the first failed table instead of continuing with the rest.

.EXAMPLE
    .\Load-All.ps1                         # load all bronze tables
.EXAMPLE
    .\Load-All.ps1 -LoadSilver             # bronze, then silver
.EXAMPLE
    .\Load-All.ps1 -LoadGold               # bronze, silver, then gold (the full pipeline)
.EXAMPLE
    .\Load-All.ps1 -Only sites, packages   # just two tables
.EXAMPLE
    .\Load-All.ps1 -FullRefresh -LoadSilver
#>
[CmdletBinding()]
param(
    [string]   $ServerInstance = 'localhost\SQLEXPRESS10',
    [string]   $Database       = 'SegPay',
    [string]   $DataRoot       = 'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data',
    [string[]] $Only,
    [switch]   $FullRefresh,
    [switch]   $LoadSilver,
    [switch]   $LoadGold,
    [switch]   $StopOnError
)

$ErrorActionPreference = 'Stop'
$runStart = Get-Date

# ----------------------------------------------------------------- logging
$logDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("load_all_{0:yyyyMMdd_HHmmss}.log" -f $runStart)
Start-Transcript -Path $logFile | Out-Null
$failed = @()
try {

# ----------------------------------------------------------------- sources
# Single-file sources: bronze table -> file under $DataRoot
$singleFile = [ordered]@{
    affiliates                = 'crm\affiliates.csv'
    merchant_accounts         = 'crm\merchant_accounts.csv'
    merchants_crm_export      = 'crm\merchants_crm_export.csv'
    merchant_xref             = 'crm\merchant_xref.csv'
    sites                     = 'crm\sites.csv'
    packages                  = 'pricing\packages.txt'
    customers                 = 'billing\customers.csv'
    purchases_snapshot        = 'billing\purchases_snapshot.csv'
    bin_reference             = 'reference\bin_reference.csv'
    chargeback_reason_codes   = 'reference\chargeback_reason_codes.csv'
    response_codes            = 'reference\response_codes.csv'
    fx_rates_daily            = 'finance\fx_rates_daily.csv'
    settlements_weekly        = 'finance\settlements_weekly.csv'
    chargebacks_acquirer_feed = 'disputes\chargebacks_acquirer_feed.csv'
    clicks                    = 'affiliate_tracker\clicks.csv'
    conversions               = 'affiliate_tracker\conversions.csv'
    helpdesk_tickets          = 'support\helpdesk_tickets.csv'
}

# Multi-file sources: bronze table -> import script in this folder (+ its folder parameter)
$multiFile = [ordered]@{
    txn_pre_migration     = @{ Script = 'Import-TxnPreMigration.ps1';  FolderParam = 'Folder';     Folder = 'txn' }
    txn_post_migration    = @{ Script = 'Import-TxnPostMigration.ps1'; FolderParam = 'Folder';     Folder = 'txn' }
    clearing_transactions = @{ Script = 'Import-ClearingFiles.ps1';    FolderParam = 'FolderPath'; Folder = 'acquirer_clearing' }
    risk_events           = @{ Script = 'Import-RiskEvents.ps1';       FolderParam = 'FolderPath'; Folder = 'risk' }
}

if ($Only) {
    $unknown = $Only | Where-Object { -not $singleFile.Contains($_) -and -not $multiFile.Contains($_) }
    if ($unknown) { throw "Unknown table(s) in -Only: $($unknown -join ', ')" }
}
function Test-Selected([string]$table) { -not $Only -or $Only -contains $table }

# ----------------------------------------------------------------- SQL helpers
$connStr = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True"

function Invoke-Sql([string]$sql, [hashtable]$params = @{}, [int]$timeout = 0) {
    $conn = New-Object System.Data.SqlClient.SqlConnection $connStr
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $sql
        $cmd.CommandTimeout = $timeout
        foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue($k, $params[$k]) }
        $dt  = New-Object System.Data.DataTable
        $rdr = $cmd.ExecuteReader()
        # Keep the last result set (procedures may return several).
        # DataTable.Load reads one result set and moves to the next; the reader
        # closes itself after the last one.
        while (-not $rdr.IsClosed) { $dt = New-Object System.Data.DataTable; $dt.Load($rdr) }
        return ,$dt
    }
    finally { $conn.Close() }
}

function Get-RowCount([string]$table) {
    (Invoke-Sql "SELECT COUNT_BIG(*) AS n FROM bronze.[$table];").Rows[0].n
}

$results = New-Object System.Collections.Generic.List[object]
function Add-Result($table, $source, $status, $rows, $seconds, $err) {
    $results.Add([pscustomobject]@{
        Table = $table; Source = $source; Status = $status; Rows = $rows
        Seconds = [math]::Round($seconds, 1); Error = $err
    })
}

Write-Host ("Bronze load started {0:yyyy-MM-dd HH:mm:ss} - server {1}, database {2}" -f $runStart, $ServerInstance, $Database)
Write-Host ("Data folder: {0}" -f $DataRoot)
if (-not (Test-Path -LiteralPath $DataRoot)) { throw "Data folder not found: $DataRoot" }

$stop = $false

# ----------------------------------------------------------------- 1. single-file sources
Write-Host "`n== Single-file sources ==" -ForegroundColor Cyan
foreach ($table in $singleFile.Keys) {
    if ($stop -or -not (Test-Selected $table)) { continue }
    $path = Join-Path $DataRoot $singleFile[$table]
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ("{0,-27}" -f $table) -NoNewline
    try {
        if (-not (Test-Path -LiteralPath $path)) { throw "File not found: $path" }
        [void](Invoke-Sql "EXEC bronze.usp_load_$table @file_path = @p;" @{ '@p' = $path })
        $rows = Get-RowCount $table
        Add-Result $table $singleFile[$table] 'OK' $rows $sw.Elapsed.TotalSeconds ''
        Write-Host (" OK  {0,10:N0} rows  {1,6:N1}s" -f $rows, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    }
    catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Add-Result $table $singleFile[$table] 'Failed' $null $sw.Elapsed.TotalSeconds $msg
        Write-Host " FAILED: $msg" -ForegroundColor Red
        if ($StopOnError) { $stop = $true }
    }
}

# ----------------------------------------------------------------- 2. multi-file sources
Write-Host "`n== Multi-file sources ==" -ForegroundColor Cyan
foreach ($table in $multiFile.Keys) {
    if ($stop -or -not (Test-Selected $table)) { continue }
    $m = $multiFile[$table]
    $script = Join-Path $PSScriptRoot $m.Script
    $folder = Join-Path $DataRoot $m.Folder
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "-- $table ($($m.Script))"
    try {
        if (-not (Test-Path -LiteralPath $script)) { throw "Import script not found: $script" }
        $scriptArgs = @{ ServerInstance = $ServerInstance; Database = $Database; $m.FolderParam = $folder }
        if ($FullRefresh) { $scriptArgs.FullRefresh = $true }
        $global:LASTEXITCODE = 0
        & $script @scriptArgs
        if ($LASTEXITCODE -ne 0) { throw "$($m.Script) reported failed files (exit code $LASTEXITCODE) - see the output above." }
        $rows = Get-RowCount $table
        Add-Result $table "$($m.Folder)\*" 'OK' $rows $sw.Elapsed.TotalSeconds ''
    }
    catch {
        Add-Result $table "$($m.Folder)\*" 'Failed' $null $sw.Elapsed.TotalSeconds $_.Exception.Message
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($StopOnError) { $stop = $true }
    }
}

# ----------------------------------------------------------------- 3 + 4. optional silver and gold
# Each layer runs only if everything before it succeeded (it reads the layer below).
function Invoke-Layer([string]$layer) {
    Write-Host "`n== $((Get-Culture).TextInfo.ToTitleCase($layer)) ==" -ForegroundColor Cyan
    $proc = "$layer.usp_load_all"
    if (@($results | Where-Object { $_.Status -in 'Failed', 'Skipped' })) {
        Write-Host "Skipped: an earlier step failed, so $layer was not rebuilt." -ForegroundColor Yellow
        Add-Result "$layer (all)" $proc 'Skipped' $null 0 'earlier failures'
        return
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $log = Invoke-Sql "EXEC $proc;"
        $total = $log.Rows | Where-Object { $_.proc_name -eq 'TOTAL' }
        Add-Result "$layer (all)" $proc $total.status $null $sw.Elapsed.TotalSeconds ''
        Write-Host ("{0}: {1} ({2:N1}s) - run_id {3}" -f $proc, $total.status, $sw.Elapsed.TotalSeconds, $total.run_id) -ForegroundColor Green
    }
    catch {
        $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Add-Result "$layer (all)" $proc 'Failed' $null $sw.Elapsed.TotalSeconds $msg
        Write-Host "FAILED: $msg" -ForegroundColor Red
    }
}

if ($LoadSilver -or $LoadGold) { Invoke-Layer 'silver' }   # gold reads silver, so -LoadGold rebuilds silver first
if ($LoadGold)                 { Invoke-Layer 'gold' }

# ----------------------------------------------------------------- summary
Write-Host "`n== Summary ==" -ForegroundColor Cyan
$results | Format-Table Table, Source, Status, @{n='Rows'; e={ if ($_.Rows -ne $null) { '{0:N0}' -f $_.Rows } }; a='right'}, Seconds -AutoSize | Out-Host

$failed = @($results | Where-Object Status -eq 'Failed')
$succeeded = @($results | Where-Object { $_.Status -in 'OK', 'Succeeded' })
Write-Host ("Finished in {0:N1}s - {1} succeeded, {2} failed. Log: {3}" -f ((Get-Date) - $runStart).TotalSeconds,
            $succeeded.Count, $failed.Count, $logFile)
if ($failed) { $failed | Format-List Table, Error | Out-Host }
}
finally {
    Stop-Transcript | Out-Null
}

if ($failed) { exit 1 }
