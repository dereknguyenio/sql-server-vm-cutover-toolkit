<#
.SYNOPSIS
    Backs up databases from source and restores to a new Always On AG primary,
    then adds them to the AG with automatic seeding to the secondary.

.DESCRIPTION
    Database refresh/migration workflow for SQL Server on Azure VMs:
      1. Full backup from source instance
      2. Transaction log backup from source (minimize data loss window)
      3. Restore full + log WITH NORECOVERY on new primary
      4. RESTORE WITH RECOVERY on new primary
      5. Add database to Availability Group (automatic seeding)
      6. Wait for secondary to finish seeding and synchronize

    Produces CSV/HTML/JSON execution reports.

.NOTES
    Requires:
      - PowerShell 5.1+
      - dbatools
      - SQL Server 2016+ on target (automatic seeding support)
      - Shared backup path accessible from source and target primary
      - AG must already exist with SEEDING_MODE = AUTOMATIC on the secondary replica

.EXAMPLE
    .\DatabaseRefresh.ps1 `
      -SourceInstance "oldsql01" `
      -PrimaryInstance "newsql01" `
      -AgName "ProdAG" `
      -Databases "HFM","APPDB" `
      -BackupPath "\\fileserver\sqlbackups\cutover"

.EXAMPLE
    $src = Get-Credential
    $tgt = Get-Credential
    .\DatabaseRefresh.ps1 `
      -SourceInstance "oldsql01" `
      -PrimaryInstance "newsql01" `
      -AgName "ProdAG" `
      -Databases "HFM","APPDB" `
      -BackupPath "\\fileserver\sqlbackups\cutover" `
      -SourceSqlCredential $src `
      -TargetSqlCredential $tgt `
      -SeedingWaitSeconds 600
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$SourceInstance,

    [Parameter(Mandatory)]
    [string]$PrimaryInstance,

    [Parameter(Mandatory)]
    [string]$AgName,

    [Parameter(Mandatory)]
    [string[]]$Databases,

    [Parameter(Mandatory)]
    [string]$BackupPath,

    [Parameter()]
    [pscredential]$SourceSqlCredential,

    [Parameter()]
    [pscredential]$TargetSqlCredential,

    [Parameter()]
    [int]$SeedingWaitSeconds = 300,

    [Parameter()]
    [int]$SeedingPollIntervalSeconds = 10,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$OutputFolder = ".\DatabaseRefreshOutput"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Category,
        [string]$ObjectType,
        [string]$ObjectName,
        [ValidateSet('PASS','WARN','FAIL','INFO','SKIP')]
        [string]$Status,
        [string]$Details,
        [string]$ActionTaken = ''
    )

    $script:Results.Add([pscustomobject]@{
        Timestamp   = (Get-Date).ToString("s")
        Category    = $Category
        ObjectType  = $ObjectType
        ObjectName  = $ObjectName
        Status      = $Status
        Details     = $Details
        ActionTaken = $ActionTaken
    })
}

function New-OutputFolder {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Invoke-SqlSafe {
    param(
        [string]$SqlInstance,
        [pscredential]$Credential,
        [string]$Database = 'master',
        [string]$Query
    )

    $params = @{
        SqlInstance     = $SqlInstance
        Database        = $Database
        Query           = $Query
        EnableException = $true
    }
    if ($Credential) {
        $params.SqlCredential = $Credential
    }

    Invoke-DbaQuery @params
}

function Export-Report {
    param([string]$Folder)

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath   = Join-Path $Folder "DatabaseRefresh_$timestamp.csv"
    $jsonPath  = Join-Path $Folder "DatabaseRefresh_$timestamp.json"
    $htmlPath  = Join-Path $Folder "DatabaseRefresh_$timestamp.html"

    $script:Results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $script:Results | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

    $style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
table { border-collapse: collapse; width: 100%; font-size: 12px; }
th, td { border: 1px solid #d9d9d9; padding: 6px; text-align: left; vertical-align: top; }
th { background-color: #f2f2f2; }
.pass { background-color: #e2f0d9; }
.warn { background-color: #fff2cc; }
.fail { background-color: #f4cccc; }
.info { background-color: #ddebf7; }
.skip { background-color: #f3f3f3; }
</style>
"@

    $rows = foreach ($r in $script:Results) {
        $cls = switch ($r.Status) {
            'PASS' { 'pass' }
            'WARN' { 'warn' }
            'FAIL' { 'fail' }
            'SKIP' { 'skip' }
            default { 'info' }
        }

@"
<tr class="$cls">
  <td>$($r.Timestamp)</td>
  <td>$($r.Category)</td>
  <td>$($r.ObjectType)</td>
  <td>$($r.ObjectName)</td>
  <td>$($r.Status)</td>
  <td>$($r.Details)</td>
  <td>$($r.ActionTaken)</td>
</tr>
"@
    }

    $summaryHtml = ($script:Results | Group-Object Status | Sort-Object Name | ForEach-Object {
        "<li><strong>$($_.Name)</strong>: $($_.Count)</li>"
    }) -join "`n"

    $html = @"
<html>
<head>
<title>Database Refresh Report</title>
$style
</head>
<body>
<h1>Database Refresh Report</h1>
<p><strong>Source:</strong> $SourceInstance<br/>
<strong>Primary:</strong> $PrimaryInstance<br/>
<strong>AG:</strong> $AgName<br/>
<strong>Generated:</strong> $(Get-Date)</p>
<h2>Summary</h2>
<ul>
$summaryHtml
</ul>
<table>
<thead>
<tr>
<th>Timestamp</th>
<th>Category</th>
<th>ObjectType</th>
<th>ObjectName</th>
<th>Status</th>
<th>Details</th>
<th>ActionTaken</th>
</tr>
</thead>
<tbody>
$($rows -join "`n")
</tbody>
</table>
</body>
</html>
"@

    $html | Out-File -FilePath $htmlPath -Encoding UTF8

    Write-Host ""
    Write-Host "Report files:" -ForegroundColor Green
    Write-Host "  CSV : $csvPath"
    Write-Host "  JSON: $jsonPath"
    Write-Host "  HTML: $htmlPath"
}

# -------------------------------------------------------------------
# Module check
# -------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name dbatools)) {
    throw "dbatools module is required. Install with: Install-Module dbatools -Scope CurrentUser"
}
Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true

New-OutputFolder -Path $OutputFolder
New-OutputFolder -Path $BackupPath

# -------------------------------------------------------------------
# Connectivity validation
# -------------------------------------------------------------------
foreach ($inst in @(
    @{ Name = $SourceInstance; Cred = $SourceSqlCredential; Role = 'Source' },
    @{ Name = $PrimaryInstance; Cred = $TargetSqlCredential; Role = 'Primary' }
)) {
    try {
        $connParams = @{ SqlInstance = $inst.Name; EnableException = $true }
        if ($inst.Cred) { $connParams.SqlCredential = $inst.Cred }
        Test-DbaConnection @connParams | Out-Null

        Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $inst.Name -Status "PASS" `
            -Details "Connected to $($inst.Role) instance."
    }
    catch {
        Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $inst.Name -Status "FAIL" `
            -Details $_.Exception.Message
        Export-Report -Folder $OutputFolder
        throw "Cannot connect to $($inst.Role) instance $($inst.Name). Aborting."
    }
}

# -------------------------------------------------------------------
# Validate AG exists and automatic seeding is configured
# -------------------------------------------------------------------
try {
    $agCheck = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential -Query @"
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ar.seeding_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
WHERE ag.name = N'$AgName';
"@

    if (-not $agCheck) {
        Add-Result -Category "Preflight" -ObjectType "AG" -ObjectName $AgName -Status "FAIL" `
            -Details "Availability Group not found on $PrimaryInstance."
        Export-Report -Folder $OutputFolder
        throw "AG '$AgName' not found."
    }

    foreach ($replica in $agCheck) {
        $seedStatus = if ($replica.seeding_mode_desc -eq 'AUTOMATIC') { 'PASS' } else { 'WARN' }
        Add-Result -Category "Preflight" -ObjectType "AG Replica" -ObjectName $replica.replica_server_name `
            -Status $seedStatus `
            -Details "SeedingMode=$($replica.seeding_mode_desc)" `
            -ActionTaken "Checked sys.availability_replicas"

        if ($replica.seeding_mode_desc -ne 'AUTOMATIC') {
            Write-Warning "Replica $($replica.replica_server_name) seeding mode is $($replica.seeding_mode_desc), not AUTOMATIC. Automatic seeding may fail for this replica."
        }
    }
}
catch [System.Management.Automation.RuntimeException] {
    if ($_.Exception.Message -notlike "*AG '$AgName' not found*") {
        Add-Result -Category "Preflight" -ObjectType "AG" -ObjectName $AgName -Status "FAIL" `
            -Details $_.Exception.Message
        Export-Report -Folder $OutputFolder
        throw
    }
    throw
}

# -------------------------------------------------------------------
# Process each database
# -------------------------------------------------------------------
foreach ($dbName in $Databases) {

    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Cyan
    Write-Host "Processing database: $dbName" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor Cyan

    # ------ Step 1: Full backup from source ------
    $fullBackupFile = $null
    try {
        if ($PSCmdlet.ShouldProcess($SourceInstance, "Full backup of $dbName")) {
            Write-Host "  Taking full backup of $dbName from $SourceInstance..." -ForegroundColor Yellow

            $backupParams = @{
                SqlInstance     = $SourceInstance
                Database        = $dbName
                Path            = $BackupPath
                Type            = 'Full'
                CopyOnly        = $true
                CompressBackup  = $true
                EnableException = $true
            }
            if ($SourceSqlCredential) { $backupParams.SqlCredential = $SourceSqlCredential }

            $fullBackup = Backup-DbaDatabase @backupParams
            $fullBackupFile = $fullBackup.BackupPath

            Add-Result -Category "Backup" -ObjectType "Full" -ObjectName $dbName -Status "PASS" `
                -Details "BackupFile=$fullBackupFile; Size=$([math]::Round($fullBackup.TotalSize / 1MB, 2)) MB" `
                -ActionTaken "Backup-DbaDatabase -Type Full -CopyOnly"
        }
    }
    catch {
        Add-Result -Category "Backup" -ObjectType "Full" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Backup-DbaDatabase"
        Write-Error "Full backup failed for $dbName. Skipping this database."
        continue
    }

    # ------ Step 2: Log backup from source ------
    $logBackupFile = $null
    try {
        if ($PSCmdlet.ShouldProcess($SourceInstance, "Log backup of $dbName")) {
            Write-Host "  Taking log backup of $dbName from $SourceInstance..." -ForegroundColor Yellow

            $logParams = @{
                SqlInstance     = $SourceInstance
                Database        = $dbName
                Path            = $BackupPath
                Type            = 'Log'
                CompressBackup  = $true
                EnableException = $true
            }
            if ($SourceSqlCredential) { $logParams.SqlCredential = $SourceSqlCredential }

            $logBackup = Backup-DbaDatabase @logParams
            $logBackupFile = $logBackup.BackupPath

            Add-Result -Category "Backup" -ObjectType "Log" -ObjectName $dbName -Status "PASS" `
                -Details "BackupFile=$logBackupFile" `
                -ActionTaken "Backup-DbaDatabase -Type Log"
        }
    }
    catch {
        Add-Result -Category "Backup" -ObjectType "Log" -ObjectName $dbName -Status "WARN" `
            -Details "Log backup failed: $($_.Exception.Message). Proceeding with full backup only." `
            -ActionTaken "Backup-DbaDatabase -Type Log"
    }

    # ------ Step 3: Drop database on primary if it exists and -Force ------
    try {
        $existingDb = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential `
            -Query "SELECT DB_ID(N'$dbName') AS dbid;"

        if ($null -ne $existingDb.dbid) {
            if ($Force) {
                if ($PSCmdlet.ShouldProcess($PrimaryInstance, "Drop existing database $dbName")) {
                    # Remove from AG first if present
                    try {
                        Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential `
                            -Query "ALTER AVAILABILITY GROUP [$AgName] REMOVE DATABASE [$dbName];"
                        Add-Result -Category "Prep" -ObjectType "AG Remove" -ObjectName $dbName -Status "INFO" `
                            -Details "Removed $dbName from AG before drop." `
                            -ActionTaken "ALTER AVAILABILITY GROUP REMOVE DATABASE"
                    }
                    catch {
                        # Database may not be in the AG yet
                    }

                    Remove-DbaDatabase -SqlInstance $PrimaryInstance -SqlCredential $TargetSqlCredential `
                        -Database $dbName -EnableException -Confirm:$false

                    Add-Result -Category "Prep" -ObjectType "Drop" -ObjectName $dbName -Status "INFO" `
                        -Details "Dropped existing database on primary." `
                        -ActionTaken "Remove-DbaDatabase"
                }
            }
            else {
                Add-Result -Category "Prep" -ObjectType "Exists" -ObjectName $dbName -Status "FAIL" `
                    -Details "Database already exists on $PrimaryInstance. Use -Force to overwrite."
                continue
            }
        }
    }
    catch {
        Add-Result -Category "Prep" -ObjectType "PreCheck" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message
        continue
    }

    # ------ Step 4: Restore full WITH NORECOVERY on primary ------
    try {
        if ($PSCmdlet.ShouldProcess($PrimaryInstance, "Restore full backup of $dbName WITH NORECOVERY")) {
            Write-Host "  Restoring full backup to $PrimaryInstance WITH NORECOVERY..." -ForegroundColor Yellow

            $restoreParams = @{
                SqlInstance     = $PrimaryInstance
                Database        = $dbName
                Path            = $fullBackupFile
                NoRecovery      = $true
                WithReplace     = $true
                EnableException = $true
            }
            if ($TargetSqlCredential) { $restoreParams.SqlCredential = $TargetSqlCredential }

            Restore-DbaDatabase @restoreParams

            Add-Result -Category "Restore" -ObjectType "Full" -ObjectName $dbName -Status "PASS" `
                -Details "Full backup restored WITH NORECOVERY on primary." `
                -ActionTaken "Restore-DbaDatabase -NoRecovery"
        }
    }
    catch {
        Add-Result -Category "Restore" -ObjectType "Full" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Restore-DbaDatabase"
        continue
    }

    # ------ Step 5: Restore log WITH NORECOVERY (if available) ------
    if ($logBackupFile) {
        try {
            if ($PSCmdlet.ShouldProcess($PrimaryInstance, "Restore log backup of $dbName WITH NORECOVERY")) {
                Write-Host "  Restoring log backup to $PrimaryInstance WITH NORECOVERY..." -ForegroundColor Yellow

                $logRestoreParams = @{
                    SqlInstance     = $PrimaryInstance
                    Database        = $dbName
                    Path            = $logBackupFile
                    NoRecovery      = $true
                    Continue        = $true
                    EnableException = $true
                }
                if ($TargetSqlCredential) { $logRestoreParams.SqlCredential = $TargetSqlCredential }

                Restore-DbaDatabase @logRestoreParams

                Add-Result -Category "Restore" -ObjectType "Log" -ObjectName $dbName -Status "PASS" `
                    -Details "Log backup restored WITH NORECOVERY on primary." `
                    -ActionTaken "Restore-DbaDatabase -NoRecovery -Continue"
            }
        }
        catch {
            Add-Result -Category "Restore" -ObjectType "Log" -ObjectName $dbName -Status "WARN" `
                -Details "Log restore failed: $($_.Exception.Message). Proceeding with recovery." `
                -ActionTaken "Restore-DbaDatabase"
        }
    }

    # ------ Step 6: RESTORE WITH RECOVERY on primary ------
    try {
        if ($PSCmdlet.ShouldProcess($PrimaryInstance, "RESTORE $dbName WITH RECOVERY")) {
            Write-Host "  Recovering database $dbName on primary..." -ForegroundColor Yellow

            Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential `
                -Query "RESTORE DATABASE [$dbName] WITH RECOVERY;"

            Add-Result -Category "Restore" -ObjectType "Recovery" -ObjectName $dbName -Status "PASS" `
                -Details "Database recovered and online on primary." `
                -ActionTaken "RESTORE DATABASE WITH RECOVERY"
        }
    }
    catch {
        Add-Result -Category "Restore" -ObjectType "Recovery" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "RESTORE WITH RECOVERY"
        continue
    }

    # ------ Step 7: Add database to AG (automatic seeding to secondary) ------
    try {
        if ($PSCmdlet.ShouldProcess($PrimaryInstance, "Add $dbName to AG $AgName")) {
            Write-Host "  Adding $dbName to Availability Group $AgName..." -ForegroundColor Yellow

            Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential `
                -Query "ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$dbName];"

            Add-Result -Category "AG" -ObjectType "Add Database" -ObjectName $dbName -Status "PASS" `
                -Details "Database added to AG. Automatic seeding will replicate to secondary." `
                -ActionTaken "ALTER AVAILABILITY GROUP ADD DATABASE"
        }
    }
    catch {
        Add-Result -Category "AG" -ObjectType "Add Database" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message `
            -ActionTaken "ALTER AVAILABILITY GROUP ADD DATABASE"
        continue
    }

    # ------ Step 8: Wait for automatic seeding / synchronization ------
    Write-Host "  Waiting for $dbName to synchronize (up to $SeedingWaitSeconds seconds)..." -ForegroundColor Yellow

    $deadline = (Get-Date).AddSeconds($SeedingWaitSeconds)
    $synced = $false

    while ((Get-Date) -lt $deadline) {
        try {
            $syncState = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential -Query @"
SELECT
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.is_local,
    ar.replica_server_name
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar
    ON drs.replica_id = ar.replica_id
WHERE DB_NAME(drs.database_id) = N'$dbName';
"@

            $secondaryReplicas = $syncState | Where-Object { -not $_.is_local }
            $allSynced = $true

            foreach ($rep in $secondaryReplicas) {
                if ($rep.synchronization_state_desc -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
                    $allSynced = $false
                    break
                }
            }

            if ($allSynced -and $secondaryReplicas) {
                $synced = $true
                foreach ($rep in $secondaryReplicas) {
                    Add-Result -Category "AG" -ObjectType "Seeding" -ObjectName "$dbName -> $($rep.replica_server_name)" `
                        -Status "PASS" `
                        -Details "SyncState=$($rep.synchronization_state_desc); SyncHealth=$($rep.synchronization_health_desc)" `
                        -ActionTaken "Automatic seeding completed"
                }
                break
            }
        }
        catch {
            # Seeding still in progress, DMV may not return rows yet
        }

        Start-Sleep -Seconds $SeedingPollIntervalSeconds
    }

    if (-not $synced) {
        Add-Result -Category "AG" -ObjectType "Seeding" -ObjectName $dbName -Status "WARN" `
            -Details "Seeding did not complete within $SeedingWaitSeconds seconds. Check AG dashboard." `
            -ActionTaken "Timeout waiting for synchronization"
    }

    # ------ Step 9: Verify database is online on primary ------
    try {
        $dbState = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Credential $TargetSqlCredential `
            -Query "SELECT state_desc, user_access_desc FROM sys.databases WHERE name = N'$dbName';"

        $status = if ($dbState.state_desc -eq 'ONLINE') { 'PASS' } else { 'FAIL' }
        Add-Result -Category "Validation" -ObjectType "Database State" -ObjectName $dbName -Status $status `
            -Details "State=$($dbState.state_desc); UserAccess=$($dbState.user_access_desc)"
    }
    catch {
        Add-Result -Category "Validation" -ObjectType "Database State" -ObjectName $dbName -Status "FAIL" `
            -Details $_.Exception.Message
    }
}

# -------------------------------------------------------------------
# Final report
# -------------------------------------------------------------------
Export-Report -Folder $OutputFolder

$failCount = ($script:Results | Where-Object Status -eq 'FAIL' | Measure-Object).Count
if ($failCount -gt 0) {
    Write-Error "Database refresh completed with $failCount FAIL result(s). Review report."
    exit 2
}
else {
    Write-Host "Database refresh completed with no FAIL results." -ForegroundColor Green
    exit 0
}
