<#
.SYNOPSIS
    Loads the OLD-gateway transaction files (header has "currency", not "ccy")
    into bronze.txn_pre_migration via bronze.usp_load_txn_pre_migration.
    Post-migration files in the same folder are skipped.

.EXAMPLE
    .\Import-TxnPreMigration.ps1
.EXAMPLE
    .\Import-TxnPreMigration.ps1 -FullRefresh       # empty the bronze table first
#>
[CmdletBinding()]
param(
    [string] $ServerInstance = 'localhost\SQLEXPRESS10',
    [string] $Database       = 'SegPay',
    [string] $Folder         = 'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\txn',
    [string] $Filter         = 'transactions_*.csv',
    [string] $SqlUser,            # omit both to use Windows authentication
    [string] $SqlPassword,
    [switch] $FullRefresh,        # empty the bronze table before loading
    [switch] $StopOnError
)

$ErrorActionPreference = 'Stop'
$Proc  = 'bronze.usp_load_txn_pre_migration'
$Table = 'bronze.txn_pre_migration'

if (-not (Test-Path -LiteralPath $Folder)) { throw "Folder not found: $Folder" }

# transactions_YYYYMM.csv -> name order is date order; keep only pre-migration layout
$files = Get-ChildItem -LiteralPath $Folder -Filter $Filter -File | Sort-Object Name |
         Where-Object { (Get-Content -LiteralPath $_.FullName -TotalCount 1) -notmatch '(^|,)ccy(,|$)' }
if (-not $files) { Write-Warning "No pre-migration files matching '$Filter' in $Folder"; return }

$connStr = if ($SqlUser) {
    "Server=$ServerInstance;Database=$Database;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True"
} else {
    "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True"
}
$conn = New-Object System.Data.SqlClient.SqlConnection $connStr
$conn.Open()

$results = New-Object System.Collections.Generic.List[object]
$sw = [Diagnostics.Stopwatch]::StartNew()

try {
    if ($FullRefresh) {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "TRUNCATE TABLE $Table;"
        [void]$cmd.ExecuteNonQuery()
        Write-Host "Truncated $Table."
    }

    foreach ($f in $files) {
        $fileSw = [Diagnostics.Stopwatch]::StartNew()
        Write-Host ("[Pre] {0} ..." -f $f.Name) -NoNewline

        $cmd = $conn.CreateCommand()
        $cmd.CommandText    = $Proc
        $cmd.CommandType    = [System.Data.CommandType]::StoredProcedure
        $cmd.CommandTimeout = 0
        [void]$cmd.Parameters.Add('@file_path', [System.Data.SqlDbType]::NVarChar, 500)
        $cmd.Parameters['@file_path'].Value = $f.FullName

        try {
            $dt  = New-Object System.Data.DataTable
            $rdr = $cmd.ExecuteReader(); $dt.Load($rdr); $rdr.Close()
            $r = $dt.Rows[0]
            $results.Add([pscustomobject]@{
                File = $f.Name; Status = 'OK'; Loaded = $r.RowsLoaded
                Seconds = [math]::Round($fileSw.Elapsed.TotalSeconds, 1); Error = ''
            })
            Write-Host (" OK ({0} rows, {1:N1}s)" -f $r.RowsLoaded, $fileSw.Elapsed.TotalSeconds) -ForegroundColor Green
        }
        catch {
            $msg = $_.Exception.InnerException.Message
            if (-not $msg) { $msg = $_.Exception.Message }
            $results.Add([pscustomobject]@{
                File = $f.Name; Status = 'Failed'; Loaded = $null
                Seconds = [math]::Round($fileSw.Elapsed.TotalSeconds, 1); Error = $msg
            })
            Write-Host " FAILED: $msg" -ForegroundColor Red
            if ($StopOnError) { break }
        }
    }
}
finally { $conn.Close() }

Write-Host ""
$results | Format-Table File, Status, Loaded, Seconds -AutoSize

$failed = @($results | Where-Object Status -eq 'Failed')
Write-Host ("{0} pre-migration file(s) processed in {1:N1}s, {2} failed." -f $results.Count, $sw.Elapsed.TotalSeconds, $failed.Count)
if ($failed) { $failed | Format-List File, Error; exit 1 }
