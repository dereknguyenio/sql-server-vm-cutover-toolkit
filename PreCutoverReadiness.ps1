<#
.SYNOPSIS
    Pre-cutover readiness validation for SQL Server Always On AG on Azure VMs.

.DESCRIPTION
    Runs pre-cutover health checks against:
      - SQL instances (primary + secondary)
      - Availability Group + databases
      - WSFC cluster
      - Listener / DNS / TCP connectivity
      - Backups
      - Server-level objects (logins, jobs, linked servers)
      - Optional listener IP / probe-port validation

    Outputs:
      - CSV
      - HTML
      - JSON

.NOTES
    Requires:
      - PowerShell 5.1+
      - dbatools
      - SqlServer module or dbatools Invoke-DbaQuery support
      - FailoverClusters module on the machine running cluster checks

.EXAMPLE
    .\PreCutoverReadiness.ps1 `
      -PrimaryInstance "sqlvm01" `
      -SecondaryInstance "sqlvm02" `
      -AgName "ProdAG" `
      -ListenerName "sql-prod-listener" `
      -Databases "HFM","APPDB" `
      -ClusterName "SQLCLUSTER01" `
      -ExpectedListenerIp "10.20.4.50" `
      -ExpectedProbePort 59999 `
      -OutputFolder "C:\Temp\PreCutover"

.EXAMPLE
    $cred = Get-Credential
    .\PreCutoverReadiness.ps1 `
      -PrimaryInstance "sqlvm01" `
      -SecondaryInstance "sqlvm02" `
      -AgName "ProdAG" `
      -ListenerName "sql-prod-listener" `
      -Databases "HFM","APPDB" `
      -SqlCredential $cred `
      -SkipClusterChecks:$false
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PrimaryInstance,

    [Parameter(Mandatory)]
    [string]$SecondaryInstance,

    [Parameter(Mandatory)]
    [string]$AgName,

    [Parameter(Mandatory)]
    [string]$ListenerName,

    [Parameter(Mandatory)]
    [string[]]$Databases,

    [Parameter()]
    [string]$ClusterName,

    [Parameter()]
    [string]$ExpectedListenerIp,

    [Parameter()]
    [int]$ExpectedProbePort = 59999,

    [Parameter()]
    [int]$ListenerPort = 1433,

    [Parameter()]
    [int]$EndpointPort = 5022,

    [Parameter()]
    [int]$BackupMaxAgeHours = 24,

    [Parameter()]
    [pscredential]$SqlCredential,

    [Parameter()]
    [string]$OutputFolder = ".\PreCutoverReadinessOutput",

    [Parameter()]
    [switch]$SkipClusterChecks,

    [Parameter()]
    [switch]$SkipObjectInventory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Helpers
# -----------------------------
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

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=" * 90) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ("=" * 90) -ForegroundColor DarkGray
}

function Invoke-SqlSafe {
    param(
        [string]$SqlInstance,
        [string]$Database = 'master',
        [string]$Query
    )

    $params = @{
        SqlInstance = $SqlInstance
        Database    = $Database
        Query       = $Query
        EnableException = $true
    }

    if ($SqlCredential) {
        $params.SqlCredential = $SqlCredential
    }

    Invoke-DbaQuery @params
}

function Test-SqlConnectionSafe {
    param([string]$SqlInstance)

    try {
        $params = @{
            SqlInstance      = $SqlInstance
            EnableException  = $true
        }
        if ($SqlCredential) {
            $params.SqlCredential = $SqlCredential
        }

        $conn = Test-DbaConnection @params
        return $conn
    }
    catch {
        return $null
    }
}

function Normalize-Scalar {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) { return ($Value -join ', ') }
    return [string]$Value
}

# -----------------------------
# Module checks
# -----------------------------
Write-Section "Module validation"

foreach ($module in @('dbatools')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Add-Result -Category "Prereq" -Check "Module installed" -Status "FAIL" -Target $module `
            -Details "Required module '$module' is not installed." `
            -Remediation "Install-Module $module -Scope CurrentUser"
        throw "Required module '$module' not installed."
    }
    else {
        Add-Result -Category "Prereq" -Check "Module installed" -Status "PASS" -Target $module `
            -Details "Module '$module' is installed."
    }
}

Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true

if (-not $SkipClusterChecks) {
    if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
        Add-Result -Category "Prereq" -Check "Module installed" -Status "FAIL" -Target "FailoverClusters" `
            -Details "FailoverClusters module is not installed / available on this host." `
            -Remediation "Run the script from a host with RSAT Failover Clustering tools or install the feature."
        throw "FailoverClusters module not available."
    }

    Import-Module FailoverClusters -ErrorAction Stop
    Add-Result -Category "Prereq" -Check "Module installed" -Status "PASS" -Target "FailoverClusters" `
        -Details "Module 'FailoverClusters' is installed."
}

# -----------------------------
# Create output path
# -----------------------------
if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$csvPath   = Join-Path $OutputFolder "PreCutoverReadiness_$timestamp.csv"
$htmlPath  = Join-Path $OutputFolder "PreCutoverReadiness_$timestamp.html"
$jsonPath  = Join-Path $OutputFolder "PreCutoverReadiness_$timestamp.json"

# -----------------------------
# SQL Connectivity
# -----------------------------
Write-Section "SQL connectivity"

foreach ($instance in @($PrimaryInstance, $SecondaryInstance)) {
    try {
        $conn = Test-SqlConnectionSafe -SqlInstance $instance
        if ($null -eq $conn) {
            Add-Result -Category "Connectivity" -Check "SQL connectivity" -Status "FAIL" -Target $instance `
                -Details "Could not connect to SQL instance." `
                -Remediation "Validate SQL service, firewall, listener, routing, and credentials."
            continue
        }

        Add-Result -Category "Connectivity" -Check "SQL connectivity" -Status "PASS" -Target $instance `
            -Details ("Connected. AuthScheme={0}; TcpPort={1}; IP={2}; IsPingable={3}" -f `
                (Normalize-Scalar $conn.AuthScheme),
                (Normalize-Scalar $conn.TcpPort),
                (Normalize-Scalar $conn.IPAddress),
                (Normalize-Scalar $conn.IsPingable))
    }
    catch {
        Add-Result -Category "Connectivity" -Check "SQL connectivity" -Status "FAIL" -Target $instance `
            -Details $_.Exception.Message `
            -Remediation "Validate SQL service, firewall, routing, and credentials."
    }
}

# -----------------------------
# Version / HADR / Endpoint checks
# -----------------------------
Write-Section "SQL engine and HADR validation"

$versionQuery = @"
SELECT
    @@SERVERNAME AS ServerName,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS ProductLevel,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
    CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS Collation;
"@

$endpointQuery = @"
SELECT
    name,
    state_desc,
    type_desc,
    port
FROM sys.tcp_endpoints
WHERE type_desc = 'DATABASE_MIRRORING';
"@

$instanceInfo = @{}

foreach ($instance in @($PrimaryInstance, $SecondaryInstance)) {
    try {
        $info = Invoke-SqlSafe -SqlInstance $instance -Query $versionQuery | Select-Object -First 1
        $instanceInfo[$instance] = $info

        Add-Result -Category "SQL" -Check "SQL version" -Status "PASS" -Target $instance `
            -Details ("Version={0}; Level={1}; Edition={2}; Collation={3}" -f `
                $info.ProductVersion, $info.ProductLevel, $info.Edition, $info.Collation)

        if ([int]$info.IsHadrEnabled -eq 1) {
            Add-Result -Category "SQL" -Check "Always On enabled" -Status "PASS" -Target $instance `
                -Details "IsHadrEnabled = 1"
        }
        else {
            Add-Result -Category "SQL" -Check "Always On enabled" -Status "FAIL" -Target $instance `
                -Details "IsHadrEnabled <> 1" `
                -Remediation "Enable Always On in SQL Server Configuration Manager and restart SQL Server service."
        }

        $endpoints = Invoke-SqlSafe -SqlInstance $instance -Query $endpointQuery
        if (-not $endpoints) {
            Add-Result -Category "SQL" -Check "HADR endpoint exists" -Status "FAIL" -Target $instance `
                -Details "No DATABASE_MIRRORING endpoint found." `
                -Remediation "Create/start the HADR endpoint and grant CONNECT as required."
        }
        else {
            foreach ($ep in $endpoints) {
                $status = if ($ep.state_desc -eq 'STARTED' -and [int]$ep.port -eq $EndpointPort) { 'PASS' } else { 'WARN' }
                $remediation = if ($status -eq 'WARN') {
                    "Ensure endpoint is STARTED and port matches expected value $EndpointPort."
                } else { '' }

                Add-Result -Category "SQL" -Check "HADR endpoint state" -Status $status -Target $instance `
                    -Details ("Endpoint={0}; State={1}; Port={2}" -f $ep.name, $ep.state_desc, $ep.port) `
                    -Remediation $remediation
            }
        }
    }
    catch {
        Add-Result -Category "SQL" -Check "Instance metadata query" -Status "FAIL" -Target $instance `
            -Details $_.Exception.Message `
            -Remediation "Validate connectivity, permissions, and SQL service state."
    }
}

# Compare versions + collation
if ($instanceInfo.ContainsKey($PrimaryInstance) -and $instanceInfo.ContainsKey($SecondaryInstance)) {
    $p = $instanceInfo[$PrimaryInstance]
    $s = $instanceInfo[$SecondaryInstance]

    if ($p.ProductVersion -eq $s.ProductVersion -and $p.ProductLevel -eq $s.ProductLevel) {
        Add-Result -Category "SQL" -Check "Version parity" -Status "PASS" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details ("Both replicas match: Version={0}; Level={1}" -f $p.ProductVersion, $p.ProductLevel)
    }
    else {
        Add-Result -Category "SQL" -Check "Version parity" -Status "FAIL" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details ("Mismatch. Primary={0}/{1}; Secondary={2}/{3}" -f `
                $p.ProductVersion, $p.ProductLevel, $s.ProductVersion, $s.ProductLevel) `
            -Remediation "Patch both replicas to the same SQL build before cutover."
    }

    if ($p.Collation -eq $s.Collation) {
        Add-Result -Category "SQL" -Check "Collation parity" -Status "PASS" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details "Both replicas use collation '$($p.Collation)'."
    }
    else {
        Add-Result -Category "SQL" -Check "Collation parity" -Status "FAIL" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details ("Mismatch. Primary={0}; Secondary={1}" -f $p.Collation, $s.Collation) `
            -Remediation "Investigate collation mismatch before cutover."
    }
}

# -----------------------------
# AG + database health
# -----------------------------
Write-Section "Availability Group validation"

$agReplicaQuery = @"
SELECT
    ag.name AS ag_name,
    ar.replica_server_name,
    ars.role_desc,
    ars.connected_state_desc,
    ars.operational_state_desc,
    ars.synchronization_health_desc,
    ar.availability_mode_desc,
    ar.failover_mode_desc,
    ar.endpoint_url
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id
WHERE ag.name = N'$AgName';
"@

$dbStateQuery = @"
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
    $replicas = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $agReplicaQuery
    if (-not $replicas) {
        Add-Result -Category "AG" -Check "AG exists" -Status "FAIL" -Target $AgName `
            -Details "AG '$AgName' not found from primary instance query." `
            -Remediation "Validate AG name, instance, and permissions."
    }
    else {
        Add-Result -Category "AG" -Check "AG exists" -Status "PASS" -Target $AgName `
            -Details "Availability Group '$AgName' returned $(($replicas | Measure-Object).Count) replica row(s)."

        foreach ($r in $replicas) {
            $status = if ($r.connected_state_desc -eq 'CONNECTED' -and $r.synchronization_health_desc -eq 'HEALTHY') { 'PASS' } else { 'WARN' }
            Add-Result -Category "AG" -Check "Replica health" -Status $status -Target $r.replica_server_name `
                -Details ("Role={0}; Connected={1}; Operational={2}; SyncHealth={3}; AvailabilityMode={4}; FailoverMode={5}; Endpoint={6}" -f `
                    $r.role_desc, $r.connected_state_desc, $r.operational_state_desc, $r.synchronization_health_desc, `
                    $r.availability_mode_desc, $r.failover_mode_desc, $r.endpoint_url) `
                -Remediation "Replica should be CONNECTED and HEALTHY before cutover."
        }
    }
}
catch {
    Add-Result -Category "AG" -Check "Replica health query" -Status "FAIL" -Target $AgName `
        -Details $_.Exception.Message `
        -Remediation "Validate AG DMVs, permissions, and connectivity."
}

try {
    $dbStates = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $dbStateQuery
    foreach ($db in $Databases) {
        $matches = $dbStates | Where-Object { $_.database_name -eq $db }
        if (-not $matches) {
            Add-Result -Category "AG" -Check "Database in AG state DMV" -Status "FAIL" -Target $db `
                -Details "Database '$db' did not return a row from sys.dm_hadr_database_replica_states." `
                -Remediation "Verify the database is joined to the AG and healthy."
            continue
        }

        foreach ($m in $matches) {
            $status = 'PASS'
            $remediation = ''

            if ($m.synchronization_state_desc -notin @('SYNCHRONIZED','SYNCHRONIZING')) {
                $status = 'FAIL'
                $remediation = "Database should be SYNCHRONIZED or actively SYNCHRONIZING before cutover."
            }
            elseif ([int]$m.log_send_queue_size -gt 0 -or [int]$m.redo_queue_size -gt 0) {
                $status = 'WARN'
                $remediation = "Drain queues to zero or near-zero before cutover."
            }

            Add-Result -Category "AG" -Check "Database sync state" -Status $status -Target $db `
                -Details ("IsLocal={0}; IsPrimaryReplica={1}; SyncState={2}; SyncHealth={3}; LogSendQueueKB={4}; RedoQueueKB={5}; LastCommitTime={6}" -f `
                    $m.is_local, $m.is_primary_replica, $m.synchronization_state_desc, $m.synchronization_health_desc, `
                    $m.log_send_queue_size, $m.redo_queue_size, $m.last_commit_time) `
                -Remediation $remediation
        }
    }
}
catch {
    Add-Result -Category "AG" -Check "Database sync state query" -Status "FAIL" -Target $AgName `
        -Details $_.Exception.Message `
        -Remediation "Validate AG DMVs, permissions, and that queried databases exist."
}

# -----------------------------
# Backup recency
# -----------------------------
Write-Section "Backup recency validation"

$backupQuery = @"
WITH b AS (
    SELECT
        database_name,
        MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS last_full_backup,
        MAX(CASE WHEN type = 'I' THEN backup_finish_date END) AS last_diff_backup,
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
    foreach ($db in $Databases) {
        $row = $backups | Where-Object { $_.database_name -eq $db } | Select-Object -First 1
        if (-not $row) {
            Add-Result -Category "Backup" -Check "Backup history exists" -Status "FAIL" -Target $db `
                -Details "No backup history found." `
                -Remediation "Ensure full and log backups exist before cutover."
            continue
        }

        $maxAge = (Get-Date).AddHours(-$BackupMaxAgeHours)

        $fullStatus = if ($row.last_full_backup -and [datetime]$row.last_full_backup -ge $maxAge) { 'PASS' } else { 'WARN' }
        $logStatus  = if ($row.last_log_backup  -and [datetime]$row.last_log_backup  -ge $maxAge) { 'PASS' } else { 'WARN' }

        Add-Result -Category "Backup" -Check "Full backup recency" -Status $fullStatus -Target $db `
            -Details ("LastFull={0}; ThresholdHours={1}" -f $row.last_full_backup, $BackupMaxAgeHours) `
            -Remediation "Take a fresh full backup if required by your cutover policy."

        Add-Result -Category "Backup" -Check "Log backup recency" -Status $logStatus -Target $db `
            -Details ("LastLog={0}; ThresholdHours={1}" -f $row.last_log_backup, $BackupMaxAgeHours) `
            -Remediation "Take a fresh log backup if required by your cutover policy."
    }
}
catch {
    Add-Result -Category "Backup" -Check "Backup history query" -Status "FAIL" -Target $PrimaryInstance `
        -Details $_.Exception.Message `
        -Remediation "Validate msdb permissions and backup history availability."
}

# -----------------------------
# Listener / DNS / TCP
# -----------------------------
Write-Section "Listener validation"

try {
    $dnsRecords = Resolve-DnsName -Name $ListenerName -ErrorAction Stop
    $aRecords = $dnsRecords | Where-Object { $_.Type -eq 'A' }

    if ($aRecords) {
        foreach ($r in $aRecords) {
            $status = if ($ExpectedListenerIp -and $r.IPAddress -ne $ExpectedListenerIp) { 'WARN' } else { 'PASS' }
            $remediation = if ($status -eq 'WARN') { "Listener DNS should resolve to expected IP $ExpectedListenerIp." } else { '' }

            Add-Result -Category "Listener" -Check "DNS resolution" -Status $status -Target $ListenerName `
                -Details ("ResolvedIP={0}" -f $r.IPAddress) `
                -Remediation $remediation
        }
    }
    else {
        Add-Result -Category "Listener" -Check "DNS resolution" -Status "FAIL" -Target $ListenerName `
            -Details "No A record returned." `
            -Remediation "Validate listener DNS registration."
    }
}
catch {
    Add-Result -Category "Listener" -Check "DNS resolution" -Status "FAIL" -Target $ListenerName `
        -Details $_.Exception.Message `
        -Remediation "Validate DNS registration and name resolution."
}

try {
    $tnc = Test-NetConnection -ComputerName $ListenerName -Port $ListenerPort -WarningAction SilentlyContinue
    if ($tnc.TcpTestSucceeded) {
        Add-Result -Category "Listener" -Check "TCP connectivity" -Status "PASS" -Target "${ListenerName}:${ListenerPort}" `
            -Details ("TcpTestSucceeded={0}; RemoteAddress={1}" -f $tnc.TcpTestSucceeded, $tnc.RemoteAddress)
    }
    else {
        Add-Result -Category "Listener" -Check "TCP connectivity" -Status "FAIL" -Target "${ListenerName}:${ListenerPort}" `
            -Details ("TcpTestSucceeded={0}; RemoteAddress={1}" -f $tnc.TcpTestSucceeded, $tnc.RemoteAddress) `
            -Remediation "Validate load balancer rule, backend pool, SQL listener, and firewall."
    }
}
catch {
    Add-Result -Category "Listener" -Check "TCP connectivity" -Status "FAIL" -Target "${ListenerName}:${ListenerPort}" `
        -Details $_.Exception.Message `
        -Remediation "Validate name resolution, route, firewall, and LB."
}

try {
    $listenerTestQuery = "SELECT @@SERVERNAME AS CurrentServer, DB_NAME() AS CurrentDb;"
    $listenerResult = Invoke-SqlSafe -SqlInstance $ListenerName -Query $listenerTestQuery | Select-Object -First 1
    Add-Result -Category "Listener" -Check "SQL listener connection" -Status "PASS" -Target $ListenerName `
        -Details ("Connected via listener. CurrentServer={0}; CurrentDb={1}" -f $listenerResult.CurrentServer, $listenerResult.CurrentDb)
}
catch {
    Add-Result -Category "Listener" -Check "SQL listener connection" -Status "FAIL" -Target $ListenerName `
        -Details $_.Exception.Message `
        -Remediation "Validate listener resource, ILB, probe, rule, and SQL service."
}

# -----------------------------
# WSFC cluster validation
# -----------------------------
if (-not $SkipClusterChecks) {
    Write-Section "WSFC cluster validation"

    try {
        $cluster = if ($ClusterName) { Get-Cluster -Name $ClusterName } else { Get-Cluster }
        Add-Result -Category "Cluster" -Check "Cluster reachable" -Status "PASS" -Target $cluster.Name `
            -Details ("ClusterName={0}" -f $cluster.Name)
    }
    catch {
        Add-Result -Category "Cluster" -Check "Cluster reachable" -Status "FAIL" -Target $(if ($ClusterName) { $ClusterName } else { 'LocalCluster' }) `
            -Details $_.Exception.Message `
            -Remediation "Run from a host with cluster access and validate cluster service / permissions."
        $cluster = $null
    }

    if ($cluster) {
        try {
            $nodes = Get-ClusterNode -Cluster $cluster.Name
            foreach ($n in $nodes) {
                $status = if ($n.State -eq 'Up') { 'PASS' } else { 'FAIL' }
                Add-Result -Category "Cluster" -Check "Cluster node state" -Status $status -Target $n.Name `
                    -Details ("State={0}" -f $n.State) `
                    -Remediation "All WSFC nodes should be Up before cutover."
            }
        }
        catch {
            Add-Result -Category "Cluster" -Check "Cluster node state" -Status "FAIL" -Target $cluster.Name `
                -Details $_.Exception.Message
        }

        try {
            $quorum = Get-ClusterQuorum -Cluster $cluster.Name
            Add-Result -Category "Cluster" -Check "Quorum" -Status "PASS" -Target $cluster.Name `
                -Details ($quorum | Out-String).Trim()
        }
        catch {
            Add-Result -Category "Cluster" -Check "Quorum" -Status "FAIL" -Target $cluster.Name `
                -Details $_.Exception.Message `
                -Remediation "Validate quorum configuration and witness."
        }

        try {
            $groups = Get-ClusterGroup -Cluster $cluster.Name
            foreach ($g in $groups) {
                $status = if ($g.State -eq 'Online') { 'PASS' } else { 'WARN' }
                Add-Result -Category "Cluster" -Check "Cluster group state" -Status $status -Target $g.Name `
                    -Details ("OwnerNode={0}; State={1}" -f $g.OwnerNode, $g.State) `
                    -Remediation "Critical AG/listener groups should be Online."
            }
        }
        catch {
            Add-Result -Category "Cluster" -Check "Cluster group state" -Status "FAIL" -Target $cluster.Name `
                -Details $_.Exception.Message
        }

        # Optional listener IP / probe-port validation
        if ($ExpectedListenerIp) {
            try {
                $ipResources = Get-ClusterResource -Cluster $cluster.Name | Where-Object { $_.ResourceType -eq 'IP Address' }
                $matched = $false

                foreach ($res in $ipResources) {
                    $params = Get-ClusterParameter -InputObject $res
                    $address = ($params | Where-Object Name -eq 'Address' | Select-Object -ExpandProperty Value -First 1)
                    $probe   = ($params | Where-Object Name -eq 'ProbePort' | Select-Object -ExpandProperty Value -First 1)
                    $subnet  = ($params | Where-Object Name -eq 'SubnetMask' | Select-Object -ExpandProperty Value -First 1)
                    $network = ($params | Where-Object Name -eq 'Network' | Select-Object -ExpandProperty Value -First 1)
                    $dhcp    = ($params | Where-Object Name -eq 'EnableDhcp' | Select-Object -ExpandProperty Value -First 1)

                    if ($address -eq $ExpectedListenerIp) {
                        $matched = $true
                        $status = if ([int]$probe -eq $ExpectedProbePort -and "$subnet" -eq '255.255.255.255' -and [int]$dhcp -eq 0) { 'PASS' } else { 'WARN' }
                        Add-Result -Category "Cluster" -Check "Listener IP resource parameters" -Status $status -Target $res.Name `
                            -Details ("Address={0}; ProbePort={1}; SubnetMask={2}; Network={3}; EnableDhcp={4}" -f `
                                $address, $probe, $subnet, $network, $dhcp) `
                            -Remediation "For Azure ILB-based listener, confirm expected address/probe/subnet/DHCP values."
                    }
                }

                if (-not $matched) {
                    Add-Result -Category "Cluster" -Check "Listener IP resource present" -Status "WARN" -Target $ExpectedListenerIp `
                        -Details "No cluster IP resource matched the expected listener IP." `
                        -Remediation "Validate the listener IP resource and cluster parameters."
                }
            }
            catch {
                Add-Result -Category "Cluster" -Check "Listener IP resource parameters" -Status "FAIL" -Target $cluster.Name `
                    -Details $_.Exception.Message `
                    -Remediation "Validate cluster permissions and resource parameter access."
            }
        }
    }
}

# -----------------------------
# Server object inventory
# -----------------------------
if (-not $SkipObjectInventory) {
    Write-Section "Server object validation"

    # Logins
    $loginQuery = @"
SELECT COUNT(*) AS LoginCount
FROM sys.server_principals
WHERE type IN ('S','U','G')
  AND name NOT LIKE '##%';
"@

    # Agent jobs
    $jobQuery = @"
SELECT
    COUNT(*) AS TotalJobs,
    SUM(CASE WHEN enabled = 1 THEN 1 ELSE 0 END) AS EnabledJobs
FROM msdb.dbo.sysjobs;
"@

    # Jobs with missing owners
    $jobOwnerQuery = @"
SELECT
    j.name AS job_name,
    SUSER_SNAME(j.owner_sid) AS owner_name
FROM msdb.dbo.sysjobs j
WHERE SUSER_SNAME(j.owner_sid) IS NULL;
"@

    # Operators
    $operatorQuery = @"
SELECT COUNT(*) AS OperatorCount
FROM msdb.dbo.sysoperators;
"@

    # Linked servers
    $linkedServerQuery = @"
SELECT COUNT(*) AS LinkedServerCount
FROM sys.servers
WHERE is_linked = 1;
"@

    foreach ($instance in @($PrimaryInstance, $SecondaryInstance)) {
        try {
            $loginCount = Invoke-SqlSafe -SqlInstance $instance -Query $loginQuery | Select-Object -First 1
            Add-Result -Category "Objects" -Check "Login inventory" -Status "INFO" -Target $instance `
                -Details ("LoginCount={0}" -f $loginCount.LoginCount)
        }
        catch {
            Add-Result -Category "Objects" -Check "Login inventory" -Status "FAIL" -Target $instance `
                -Details $_.Exception.Message
        }

        try {
            $jobs = Invoke-SqlSafe -SqlInstance $instance -Database msdb -Query $jobQuery | Select-Object -First 1
            Add-Result -Category "Objects" -Check "SQL Agent job inventory" -Status "INFO" -Target $instance `
                -Details ("TotalJobs={0}; EnabledJobs={1}" -f $jobs.TotalJobs, $jobs.EnabledJobs)
        }
        catch {
            Add-Result -Category "Objects" -Check "SQL Agent job inventory" -Status "FAIL" -Target $instance `
                -Details $_.Exception.Message
        }

        try {
            $orphanOwners = Invoke-SqlSafe -SqlInstance $instance -Database msdb -Query $jobOwnerQuery
            if ($orphanOwners -and ($orphanOwners | Measure-Object).Count -gt 0) {
                foreach ($row in $orphanOwners) {
                    Add-Result -Category "Objects" -Check "Job owner valid" -Status "WARN" -Target $instance `
                        -Details ("Job '{0}' has a missing/invalid owner." -f $row.job_name) `
                        -Remediation "Remap job owner before cutover."
                }
            }
            else {
                Add-Result -Category "Objects" -Check "Job owner valid" -Status "PASS" -Target $instance `
                    -Details "All SQL Agent jobs returned a valid owner."
            }
        }
        catch {
            Add-Result -Category "Objects" -Check "Job owner valid" -Status "FAIL" -Target $instance `
                -Details $_.Exception.Message
        }

        try {
            $operators = Invoke-SqlSafe -SqlInstance $instance -Database msdb -Query $operatorQuery | Select-Object -First 1
            Add-Result -Category "Objects" -Check "Operator inventory" -Status "INFO" -Target $instance `
                -Details ("OperatorCount={0}" -f $operators.OperatorCount)
        }
        catch {
            Add-Result -Category "Objects" -Check "Operator inventory" -Status "FAIL" -Target $instance `
                -Details $_.Exception.Message
        }

        try {
            $ls = Invoke-SqlSafe -SqlInstance $instance -Query $linkedServerQuery | Select-Object -First 1
            Add-Result -Category "Objects" -Check "Linked server inventory" -Status "INFO" -Target $instance `
                -Details ("LinkedServerCount={0}" -f $ls.LinkedServerCount)
        }
        catch {
            Add-Result -Category "Objects" -Check "Linked server inventory" -Status "FAIL" -Target $instance `
                -Details $_.Exception.Message
        }
    }

    # Compare login/job/operator/linked server counts between replicas
    try {
        $pLogin = (Invoke-SqlSafe -SqlInstance $PrimaryInstance -Query $loginQuery | Select-Object -First 1).LoginCount
        $sLogin = (Invoke-SqlSafe -SqlInstance $SecondaryInstance -Query $loginQuery | Select-Object -First 1).LoginCount

        $status = if ($pLogin -eq $sLogin) { 'PASS' } else { 'WARN' }
        Add-Result -Category "Objects" -Check "Login count parity" -Status $status -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details ("Primary={0}; Secondary={1}" -f $pLogin, $sLogin) `
            -Remediation "If counts differ, validate expected login migration / exclusions."
    }
    catch {
        Add-Result -Category "Objects" -Check "Login count parity" -Status "FAIL" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details $_.Exception.Message
    }

    try {
        $pJobs = Invoke-SqlSafe -SqlInstance $PrimaryInstance -Database msdb -Query $jobQuery | Select-Object -First 1
        $sJobs = Invoke-SqlSafe -SqlInstance $SecondaryInstance -Database msdb -Query $jobQuery | Select-Object -First 1

        $status = if ($pJobs.TotalJobs -eq $sJobs.TotalJobs) { 'PASS' } else { 'WARN' }
        Add-Result -Category "Objects" -Check "Job count parity" -Status $status -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details ("PrimaryJobs={0}; SecondaryJobs={1}" -f $pJobs.TotalJobs, $sJobs.TotalJobs) `
            -Remediation "Validate SQL Agent job migration and intentional exclusions."
    }
    catch {
        Add-Result -Category "Objects" -Check "Job count parity" -Status "FAIL" -Target "$PrimaryInstance,$SecondaryInstance" `
            -Details $_.Exception.Message
    }
}

# -----------------------------
# Summaries + exports
# -----------------------------
Write-Section "Report generation"

$summary = $script:Results | Group-Object Status | Sort-Object Name | ForEach-Object {
    "{0}: {1}" -f $_.Name, $_.Count
}

foreach ($line in $summary) {
    Write-Host $line
}

$script:Results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
$script:Results | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding UTF8

$style = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
h1, h2 { color: #1f4e79; }
table { border-collapse: collapse; width: 100%; font-size: 12px; }
th, td { border: 1px solid #d9d9d9; padding: 6px; text-align: left; vertical-align: top; }
th { background-color: #f2f2f2; }
.pass { background-color: #e2f0d9; }
.warn { background-color: #fff2cc; }
.fail { background-color: #f4cccc; }
.info { background-color: #ddebf7; }
.summary { margin-bottom: 20px; }
</style>
"@

$htmlRows = foreach ($r in $script:Results) {
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
<title>PreCutoverReadiness</title>
$style
</head>
<body>
<h1>Pre-Cutover Readiness Report</h1>
<div class="summary">
  <p><strong>Generated:</strong> $(Get-Date)</p>
  <p><strong>Primary:</strong> $PrimaryInstance<br/>
     <strong>Secondary:</strong> $SecondaryInstance<br/>
     <strong>AG:</strong> $AgName<br/>
     <strong>Listener:</strong> $ListenerName</p>
  <h2>Summary</h2>
  <ul>
    $summaryHtml
  </ul>
</div>

<h2>Detailed Results</h2>
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
    $($htmlRows -join "`n")
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

# Non-zero exit if any FAIL
$failCount = ($script:Results | Where-Object Status -eq 'FAIL' | Measure-Object).Count
if ($failCount -gt 0) {
    Write-Error "Readiness validation completed with $failCount FAIL result(s)."
    exit 2
}
else {
    Write-Host "Readiness validation completed with no FAIL results." -ForegroundColor Green
    exit 0
}