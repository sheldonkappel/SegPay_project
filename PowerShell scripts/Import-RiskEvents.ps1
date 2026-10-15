# Run in PowerShell:
#   .\Import-RiskEvents.ps1 -FullRefresh
# Loads every .jsonl file in the risk folder into bronze.risk_events
# using bronze.usp_load_risk_events (one call per file).
# -FullRefresh empties bronze.risk_events before loading.

param(
    [string]$FolderPath = 'C:\Users\Sheldon\Desktop\Segpay Project\AI generated data\risk',
    [string]$ServerInstance = 'localhost\SQLEXPRESS10',
    [string]$Database = 'SegPay',
    [switch]$FullRefresh                            # empty the bronze table before loading
)

$ErrorActionPreference = 'Stop'

$connString = "Server=$ServerInstance;Database=$Database;Integrated Security=True;TrustServerCertificate=True"
$conn = New-Object System.Data.SqlClient.SqlConnection $connString
$conn.Open()

try {
    if ($FullRefresh) {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = 'TRUNCATE TABLE bronze.risk_events;'
        [void]$cmd.ExecuteNonQuery()
        Write-Host 'Truncated bronze.risk_events.'
    }

    $files = Get-ChildItem -Path $FolderPath -Filter *.jsonl -File | Sort-Object Name
    if (-not $files) {
        Write-Warning "No .jsonl files found in $FolderPath"
        return
    }

    $ok = 0
    $failed = @()

    foreach ($file in $files) {
        try {
            $cmd = $conn.CreateCommand()
            $cmd.CommandType    = [System.Data.CommandType]::StoredProcedure
            $cmd.CommandText    = 'bronze.usp_load_risk_events'
            $cmd.CommandTimeout = 300
            [void]$cmd.Parameters.Add('@file_path', [System.Data.SqlDbType]::NVarChar, 500)
            $cmd.Parameters['@file_path'].Value = $file.FullName
            [void]$cmd.ExecuteNonQuery()

            Write-Host "OK     $($file.Name)"
            $ok++
        }
        catch {
            Write-Host "FAILED $($file.Name): $($_.Exception.Message)" -ForegroundColor Red
            $failed += $file.Name
        }
    }

    Write-Host ""
    Write-Host "Done. $ok succeeded, $($failed.Count) failed."
    if ($failed.Count -gt 0) { exit 1 }
}
finally {
    $conn.Close()
}
