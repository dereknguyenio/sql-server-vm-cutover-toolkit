<#
.SYNOPSIS
    Post-cutover validation for SQL Server Always On AG on Azure VMs.

.DESCRIPTION
    Validates the new production state after cutover:
      - Listener DNS and SQL connectivity
      - New primary node verification
      - AG replica health
      - Database online / synchronization state
      - Log send and redo queue thresholds
      - SQL Agent job state validation
      - Backup recency validation
      - Linked server test
      - Optional smoke test queries
      - Optional WSFC checks

.EXAMPLE
    .\PostCutoverValidation.ps1 `
      -PrimaryInstance "newsql01" `
      -SecondaryInstance "newsql02" `
      -ListenerName "sql-prod-listener" `
      -ExpectedPrimary "newsql01" `
      -AgName "ProdAG" `
      -Databases "HFM","APPDB"

.EXAMPLE
    .\PostCutoverValidation.ps1 `
      -PrimaryInstance "newsql01" `
      -SecondaryInstance "newsql02" `
      -ListenerName "sql-prod-listener" `
      -ExpectedPrimary "newsql01" `
      -AgName "ProdAG" `
      -Databases "HFM","APPDB" `
      -SmokeTestFile ".\SmokeTests.json"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrimaryInstance,

    [Parameter(Mandatory)]
    [string]$SecondaryInstance,

    [Parameter(Mandatory)]
    [string]$ListenerName,

    [Parameter(Mandatory)]
    [string]$ExpectedPrimary,

    [Parameter(Mandatory)]
    [string]$AgName,

    [Parameter(Mandatory)]
    [string[]]$Databases,

    [Parameter()]
    [pscredential]$SqlCredential,

    [Parameter()]
    [string]$ClusterName,

    [Parameter()]
    [switch]$SkipClusterChecks,

    [Parameter()]
    [int]$ListenerPort = 1433,

    [Parameter()]
    [int]$MaxLogSendQueueKB = 10240,

    [Parameter()]
    [int]$MaxRedoQueueKB = 102400,

    [Parameter()]
    [int]$BackupMaxAgeHours = 24,

    [Parameter()]
    [string[]]$ExpectedEnabledJobs = @(),

    [Parameter()]
    [string[]]$ExpectedDisabledJobs = @(),

    [Parameter()]
    [switch]$TestLinkedServers,

    [Parameter()]
    [string]$SmokeTestFile,

    [Parameter()]
    [string]$OutputFolder = ".\PostCutoverValidationOutput"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Category,
        [string]$Check,
        [ValidateSet('PASS','WARN','FAIL','INFO')]
        [string]$Status,
        [string]$Target,
        [string]$Details,
        [string]$Remediation = ''
    )

    $script:Results.Add([pscustomobject]@{
        Timestamp   = (Get-Date).ToString("s")
        Category    = $Category
        Check       = $Check
        Status      = $Status
        Target      = $Target
        Details     = $Details
        Remediation = $Remediation
    })
}

function Invoke-SqlSafe {
    param(
        [string]$SqlInstance,
        [string]$Database = 'master',
        [string]$Query
    )

    $params = @{
        SqlInstance      = $SqlInstance
        Database         = $Database
        Query            = $Query
        EnableException  = $true
    }

    if ($SqlCredential) {
        $params.SqlCredential = $SqlCredential
    }

    Invoke-DbaQuery @params
}

function New-OutputFolder {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Export-Report {
    param([string]$Folder)

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath   = Join-Path $Folder "PostCutoverValidation_$timestamp.csv"
    $jsonPath  = Join-Path $Folder "PostCutoverValidation_$timestamp.json"
    $htmlPath  = Join-Path $Folder "PostCutoverValidation_$timestamp.html"

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
</style>
"@

    $rows = foreach ($r in $script:Results) {
        $cls = switch ($r.Status) {
            'PASS' { 'pass' }
            'WARN' { 'warn' }
            'FAIL' { 'fail' }
            default { 'info' }
        }

@"
<tr class="$cls">
  <td>$($r.Timestamp)</td>
  <td>$($r.Category)</td>
  <td>$($r.Check)</td>
  <td>$($r.Status)</td>
  <td>$($r.Target)</td>
  <td>$($r.Details)</td>
  <td>$($r.Remediation)</td>
</tr>
"@
    }

    $summaryHtml = ($script:Results | Group-Object Status | Sort-Object Name | ForEach-Object {
        "<li><strong>$($_.Name)</strong>: $($_.Count)</li>"
    }) -join "`n"

    $html = @"
<html>
<head>
<title>Post Cutover Validation Report</title>
$style
</head>
<body>
<h1>Post Cutover Validation Report</h1>
<p><strong>Generated:</strong> $(Get-Date)<br/>
<strong>Listener:</strong> $ListenerName<br/>
<strong>Expected Primary:</strong> $ExpectedPrimary<br/>
<strong>AG:</strong> $AgName</p>
<h2>Summary</h2>
<ul>
$summaryHtml
</ul>
<table>
<thead>
<tr>
<th>Timestamp</th>
<th>Category</th>
<th>Check</th>
<th>Status</th>
<th>Target</th>
<th>Details</th>
<th>Remediation</th>
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

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    throw "dbatools module is required. Install with: Install-Module dbatools -Scope CurrentUser"
}
Import-Module dbatools -ErrorAction Stop

if (-not $SkipClusterChecks) {
    if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
        throw "FailoverClusters module is required for cluster checks."
    }
    Import-Module FailoverClusters -ErrorAction Stop
}

New-OutputFolder -Path $OutputFolder

# Listener DNS + TCP
try {
    $dnsRecords = Resolve-DnsName -Name $ListenerName -ErrorAction Stop | Where-Object { $_.Type -eq 'A' }
    foreach ($r in $dnsRecords) {
        Add-Result -Category "Listener" -Check "DNS resolution" -Status "PASS" -Target $ListenerName `
            -Details "ResolvedIP=$($r.IPAddress)"
    }
}
catch {
    Add-Result -Category "Listener" -Check "DNS resolution" -Status "FAIL" -Target $ListenerName `
        -Details $_.Exception.Message `
        -Remediation "Validate listener DNS registration."
}

try {
    $tnc = Test-NetConnection -ComputerName $ListenerName -Port $ListenerPort -WarningAction SilentlyContinue
    if ($tnc.TcpTestSucceeded) {
        Add-Result -Category "Listener" -Check "TCP connectivity" -Status "PASS" -Target "$ListenerName:$ListenerPort" `
            -Details "RemoteAddress=$($tnc.RemoteAddress)"
    }
    else {
        Add-Result -Category "Listener" -Check "TCP connectivity" -Status "FAIL" -Target "$ListenerName:$ListenerPort" `
            -Details "TCP connectivity failed." `
            -Remediation "Validate load balancer, listener resource, and SQL service."
    }
}
catch {
    Add-Result -Category "Listener" -Check "TCP connectivity" -Status "FAIL" -Target "$ListenerName:$ListenerPort" `
        -Details $_.Exception.Message
}

# Listener SQL connection + actual server
try {
    $listenerSql = Invoke-SqlSafe -SqlInstance $ListenerName -Query "SELECT @@SERVERNAME AS ServerName, DB_NAME() AS DbName;" | Select-Object -First 1
    $serverName = [string]$listenerSql.ServerName

    if ($serverName -ieq $ExpectedPrimary) {
        Add-Result -Category "Listener" -Check "Listener lands on expected primary" -Status "PASS" -Target $ListenerName `
            -Details "ConnectedServer=$serverName"
    }
    else {
        Add-Result -Category "Listener" -Check "Listener lands on expected primary" -Status "FAIL" -Target $ListenerName `
            -Details "ConnectedServer=$serverName; Expected=$ExpectedPrimary" `
            -Remediation "Validate AG role, listener, and load balancer backend path."
    }
}
catch {
    Add-Result -Category "Listener" -Check "SQL listener connection" -Status "FAIL" -Target $ListenerName `
        -Details $_.Exception.Message `
        -Remediation "Validate listener resource, LB, DNS, and SQL connectivity."
}

# Basic instance connectivity
foreach ($instance in @($PrimaryInstance, $SecondaryInstance)) {
    try {
        $conn = Test-DbaConnection -SqlInstance $instance -SqlCredential $SqlCredential -EnableException
        Add-Result -Category "Connectivity" -Check "SQL instance connectivity" -Status "PASS" -Target $instance `
            -Details "Connected to instance."
    }
    catch {
        Add-Result -Category "Connectivity" -Check "SQL instance connectivity" -Status "FAIL" -Target $instance `
            -Details $_.Exception.Message
    }
}

# AG replica health
$agReplicaQuery = @"
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.operational_state_desc,
    ars.synchronization_health_desc,
    ar.availability_mode_desc,
    ar.failover_mode_desc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id
WHERE ag.name = N'$AgName';
"@

try {
    $replicas = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $agReplicaQuery
    foreach ($r in $replicas) {
        $status = if ($r.connected_state_desc -eq 'CONNECTED' -and $r.synchronization_health_desc -eq 'HEALTHY') { 'PASS' } else { 'WARN' }
        Add-Result -Category "AG" -Check "Replica health" -Status $status -Target $r.replica_server_name `
            -Details ("Role={0}; Connected={1}; Operational={2}; SyncHealth={3}; AvailabilityMode={4}; FailoverMode={5}" -f `
                $r.role_desc, $r.connected_state_desc, $r.operational_state_desc, `
                $r.synchronization_health_desc, $r.availability_mode_desc, $r.failover_mode_desc) `
            -Remediation "Replica should be CONNECTED and HEALTHY after cutover."
    }
}
catch {
    Add-Result -Category "AG" -Check "Replica health" -Status "FAIL" -Target $AgName `
        -Details $_.Exception.Message
}

# Database health
$dbQuery = @"
SELECT
    d.name AS database_name,
    d.state_desc,
    d.user_access_desc,
    d.recovery_model_desc
FROM sys.databases d
WHERE d.name IN ($(($Databases | ForEach-Object { "N'$_'" }) -join ','));
"@

$dbAgQuery = @"
SELECT
    DB_NAME(drs.database_id) AS database_name,
    drs.is_local,
    drs.is_primary_replica,
    drs.synchronization_state_desc,
    drs.synchronization_health_desc,
    drs.log_send_queue_size,
    drs.redo_queue_size,
    drs.last_commit_time
FROM sys.dm_hadr_database_replica_states drs
WHERE DB_NAME(drs.database_id) IN ($(($Databases | ForEach-Object { "N'$_'" }) -join ','));
"@

try {
    $dbs = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $dbQuery
    foreach ($db in $Databases) {
        $row = $dbs | Where-Object { $_.database_name -eq $db } | Select-Object -First 1
        if (-not $row) {
            Add-Result -Category "Database" -Check "Database present" -Status "FAIL" -Target $db `
                -Details "Database not found on primary."
            continue
        }

        $status = if ($row.state_desc -eq 'ONLINE') { 'PASS' } else { 'FAIL' }
        Add-Result -Category "Database" -Check "Database state" -Status $status -Target $db `
            -Details ("State={0}; UserAccess={1}; RecoveryModel={2}" -f `
                $row.state_desc, $row.user_access_desc, $row.recovery_model_desc) `
            -Remediation "Database must be ONLINE after cutover."
    }
}
catch {
    Add-Result -Category "Database" -Check "Database state query" -Status "FAIL" -Target $PrimaryInstance `
        -Details $_.Exception.Message
}

try {
    $dbAg = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $dbAgQuery
    foreach ($db in $Databases) {
        $rows = $dbAg | Where-Object { $_.database_name -eq $db }
        if (-not $rows) {
            Add-Result -Category "Database" -Check "AG database state" -Status "FAIL" -Target $db `
                -Details "No AG DMV row returned for database."
            continue
        }

        foreach ($r in $rows) {
            $status = 'PASS'
            $remediation = ''

            if ($r.synchronization_state_desc -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
                $status = 'FAIL'
                $remediation = "Database synchronization state is not healthy."
            }
            elseif ([int]$r.log_send_queue_size -gt $MaxLogSendQueueKB -or [int]$r.redo_queue_size -gt $MaxRedoQueueKB) {
                $status = 'WARN'
                $remediation = "Queue sizes exceed target threshold."
            }

            Add-Result -Category "Database" -Check "AG sync state" -Status $status -Target $db `
                -Details ("IsPrimaryReplica={0}; SyncState={1}; SyncHealth={2}; LogSendQueueKB={3}; RedoQueueKB={4}; LastCommitTime={5}" -f `
                    $r.is_primary_replica, $r.synchronization_state_desc, $r.synchronization_health_desc, `
                    $r.log_send_queue_size, $r.redo_queue_size, $r.last_commit_time) `
                -Remediation $remediation
        }
    }
}
catch {
    Add-Result -Category "Database" -Check "AG sync query" -Status "FAIL" -Target $PrimaryInstance `
        -Details $_.Exception.Message
}

# Backup recency
$backupQuery = @"
WITH b AS (
    SELECT
        database_name,
        MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS last_full_backup,
        MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS last_log_backup
    FROM msdb.dbo.backupset
    WHERE database_name IN ($(($Databases | ForEach-Object { "N'$_'" }) -join ','))
    GROUP BY database_name
)
SELECT *
FROM b;
"@

try {
    $backups = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Database msdb -Query $backupQuery
    $threshold = (Get-Date).AddHours(-$BackupMaxAgeHours)

    foreach ($db in $Databases) {
        $row = $backups | Where-Object { $_.database_name -eq $db } | Select-Object -First 1
        if (-not $row) {
            Add-Result -Category "Backup" -Check "Backup history exists" -Status "WARN" -Target $db `
                -Details "No backup history row found." `
                -Remediation "Validate backup jobs are configured on new primary."
            continue
        }

        $fullStatus = if ($row.last_full_backup -and [datetime]$row.last_full_backup -ge $threshold) { 'PASS' } else { 'WARN' }
        Add-Result -Category "Backup" -Check "Full backup recency" -Status $fullStatus -Target $db `
            -Details "LastFull=$($row.last_full_backup)" `
            -Remediation "Run/validate full backup job on new primary."

        $logStatus = if ($row.last_log_backup -and [datetime]$row.last_log_backup -ge $threshold) { 'PASS' } else { 'WARN' }
        Add-Result -Category "Backup" -Check "Log backup recency" -Status $logStatus -Target $db `
            -Details "LastLog=$($row.last_log_backup)" `
            -Remediation "Run/validate log backup job on new primary."
    }
}
catch {
    Add-Result -Category "Backup" -Check "Backup query" -Status "FAIL" -Target $PrimaryInstance `
        -Details $_.Exception.Message
}

# Job validation
if ($ExpectedEnabledJobs.Count -gt 0) {
    foreach ($job in $ExpectedEnabledJobs) {
        try {
            $q = @"
SELECT name, enabled
FROM msdb.dbo.sysjobs
WHERE name = N'$job';
"@
            $row = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Database msdb -Query $q | Select-Object -First 1
            if (-not $row) {
                Add-Result -Category "Jobs" -Check "Expected enabled job exists" -Status "FAIL" -Target $job `
                    -Details "Job not found on primary."
            }
            elseif ([int]$row.enabled -eq 1) {
                Add-Result -Category "Jobs" -Check "Expected enabled job state" -Status "PASS" -Target $job `
                    -Details "Job is enabled."
            }
            else {
                Add-Result -Category "Jobs" -Check "Expected enabled job state" -Status "FAIL" -Target $job `
                    -Details "Job exists but is disabled." `
                    -Remediation "Enable the job if cutover plan requires it."
            }
        }
        catch {
            Add-Result -Category "Jobs" -Check "Expected enabled job state" -Status "FAIL" -Target $job `
                -Details $_.Exception.Message
        }
    }
}

if ($ExpectedDisabledJobs.Count -gt 0) {
    foreach ($job in $ExpectedDisabledJobs) {
        try {
            $q = @"
SELECT name, enabled
FROM msdb.dbo.sysjobs
WHERE name = N'$job';
"@
            $row = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Database msdb -Query $q | Select-Object -First 1
            if (-not $row) {
                Add-Result -Category "Jobs" -Check "Expected disabled job exists" -Status "WARN" -Target $job `
                    -Details "Job not found on primary."
            }
            elseif ([int]$row.enabled -eq 0) {
                Add-Result -Category "Jobs" -Check "Expected disabled job state" -Status "PASS" -Target $job `
                    -Details "Job is disabled."
            }
            else {
                Add-Result -Category "Jobs" -Check "Expected disabled job state" -Status "WARN" -Target $job `
                    -Details "Job exists but is enabled." `
                    -Remediation "Disable if this job should remain off post-cutover."
            }
        }
        catch {
            Add-Result -Category "Jobs" -Check "Expected disabled job state" -Status "FAIL" -Target $job `
                -Details $_.Exception.Message
        }
    }
}

# Linked server validation
if ($TestLinkedServers) {
    try {
        $linkedServers = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query "
SELECT name
FROM sys.servers
WHERE is_linked = 1;
"
        foreach ($ls in $linkedServers) {
            $name = [string]$ls.name
            try {
                Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query "EXEC sys.sp_testlinkedserver @servername = N'$name';"
                Add-Result -Category "LinkedServer" -Check "Linked server connectivity" -Status "PASS" -Target $name `
                    -Details "sp_testlinkedserver succeeded."
            }
            catch {
                Add-Result -Category "LinkedServer" -Check "Linked server connectivity" -Status "WARN" -Target $name `
                    -Details $_.Exception.Message `
                    -Remediation "Validate provider, security context, network path, and target availability."
            }
        }
    }
    catch {
        Add-Result -Category "LinkedServer" -Check "Linked server discovery" -Status "FAIL" -Target $PrimaryInstance `
            -Details $_.Exception.Message
    }
}

# Smoke tests from JSON
if ($SmokeTestFile) {
    if (-not (Test-Path $SmokeTestFile)) {
        Add-Result -Category "SmokeTest" -Check "Smoke test file present" -Status "FAIL" -Target $SmokeTestFile `
            -Details "File not found."
    }
    else {
        try {
            $tests = Get-Content $SmokeTestFile -Raw | ConvertFrom-Json
            foreach ($test in $tests) {
                try {
                    $dbName = [string]$test.Database
                    $name   = [string]$test.Name
                    $query  = [string]$test.Query
                    $expectedScalar = $test.ExpectedScalar

                    $result = Invoke-SqlSafe -SqlInstance $ListenerName -Database $dbName -Query $query
                    if ($null -ne $expectedScalar) {
                        $actual = $result[0].Item(0)
                        if ([string]$actual -eq [string]$expectedScalar) {
                            Add-Result -Category "SmokeTest" -Check $name -Status "PASS" -Target $dbName `
                                -Details "Expected=$expectedScalar; Actual=$actual"
                        }
                        else {
                            Add-Result -Category "SmokeTest" -Check $name -Status "FAIL" -Target $dbName `
                                -Details "Expected=$expectedScalar; Actual=$actual" `
                                -Remediation "Review result and application readiness."
                        }
                    }
                    else {
                        Add-Result -Category "SmokeTest" -Check $name -Status "PASS" -Target $dbName `
                            -Details "Query executed successfully."
                    }
                }
                catch {
                    Add-Result -Category "SmokeTest" -Check $test.Name -Status "FAIL" -Target $test.Database `
                        -Details $_.Exception.Message
                }
            }
        }
        catch {
            Add-Result -Category "SmokeTest" -Check "Smoke test load" -Status "FAIL" -Target $SmokeTestFile `
                -Details $_.Exception.Message
        }
    }
}

# Optional WSFC checks
if (-not $SkipClusterChecks) {
    try {
        $cluster = if ($ClusterName) { Get-Cluster -Name $ClusterName } else { Get-Cluster }
        Add-Result -Category "Cluster" -Check "Cluster reachable" -Status "PASS" -Target $cluster.Name `
            -Details "Cluster is reachable."
    }
    catch {
        Add-Result -Category "Cluster" -Check "Cluster reachable" -Status "FAIL" -Target ($ClusterName ? $ClusterName : 'LocalCluster') `
            -Details $_.Exception.Message
        $cluster = $null
    }

    if ($cluster) {
        try {
            $nodes = Get-ClusterNode -Cluster $cluster.Name
            foreach ($n in $nodes) {
                $status = if ($n.State -eq 'Up') { 'PASS' } else { 'FAIL' }
                Add-Result -Category "Cluster" -Check "Cluster node state" -Status $status -Target $n.Name `
                    -Details "State=$($n.State)"
            }
        }
        catch {
            Add-Result -Category "Cluster" -Check "Cluster node state" -Status "FAIL" -Target $cluster.Name `
                -Details $_.Exception.Message
        }

        try {
            $groups = Get-ClusterGroup -Cluster $cluster.Name
            foreach ($g in $groups) {
                $status = if ($g.State -eq 'Online') { 'PASS' } else { 'WARN' }
                Add-Result -Category "Cluster" -Check "Cluster group state" -Status $status -Target $g.Name `
                    -Details "OwnerNode=$($g.OwnerNode); State=$($g.State)"
            }
        }
        catch {
            Add-Result -Category "Cluster" -Check "Cluster group state" -Status "FAIL" -Target $cluster.Name `
                -Details $_.Exception.Message
        }
    }
}

Export-Report -Folder $OutputFolder

$failCount = ($script:Results | Where-Object Status -eq 'FAIL' | Measure-Object).Count
if ($failCount -gt 0) {
    Write-Error "Post-cutover validation completed with $failCount FAIL result(s)."
    exit 2
}
else {
    Write-Host "Post-cutover validation completed with no FAIL results." -ForegroundColor Green
    exit 0
}