<#
.SYNOPSIS
    Migrates server-level SQL Server objects from source to target for cutover preparation.

.DESCRIPTION
    Copies common non-database objects using dbatools:
      - Logins
      - Credentials
      - Linked Servers
      - SQL Agent Jobs
      - Operators
      - Alerts
      - Proxies
      - Database Mail
      - sp_configure settings

    Produces CSV/HTML/JSON execution reports.

.NOTES
    Requires:
      - PowerShell 5.1+
      - dbatools

.EXAMPLE
    .\MigrateServerObjects.ps1 `
      -SourceInstance "oldsql01" `
      -TargetInstance "newsql01" `
      -OutputFolder "C:\Temp\ServerMigration"

.EXAMPLE
    $src = Get-Credential
    $tgt = Get-Credential
    .\MigrateServerObjects.ps1 `
      -SourceInstance "oldsql01" `
      -TargetInstance "newsql01" `
      -SourceSqlCredential $src `
      -TargetSqlCredential $tgt `
      -DisableJobsOnTarget `
      -ExcludeJobs "Job_DoNotCopy","LegacyJob"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$SourceInstance,

    [Parameter(Mandatory)]
    [string]$TargetInstance,

    [Parameter()]
    [pscredential]$SourceSqlCredential,

    [Parameter()]
    [pscredential]$TargetSqlCredential,

    [Parameter()]
    [string[]]$ExcludeLogins = @(),

    [Parameter()]
    [string[]]$ExcludeJobs = @(),

    [Parameter()]
    [string[]]$ExcludeLinkedServers = @(),

    [Parameter()]
    [string[]]$ExcludeCredentials = @(),

    [Parameter()]
    [switch]$CopyLogins = $true,

    [Parameter()]
    [switch]$CopyCredentials = $true,

    [Parameter()]
    [switch]$CopyLinkedServers = $true,

    [Parameter()]
    [switch]$CopyJobs = $true,

    [Parameter()]
    [switch]$CopyOperators = $true,

    [Parameter()]
    [switch]$CopyAlerts = $true,

    [Parameter()]
    [switch]$CopyProxies = $true,

    [Parameter()]
    [switch]$CopyDatabaseMail = $true,

    [Parameter()]
    [switch]$CopySpConfigure = $true,

    [Parameter()]
    [switch]$DisableJobsOnTarget,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$OutputFolder = ".\ServerObjectMigrationOutput"
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

function Get-DbaConnectionParams {
    param(
        [string]$Instance,
        [pscredential]$Credential
    )
    $params = @{
        SqlInstance = $Instance
        EnableException = $true
    }
    if ($Credential) {
        $params.SqlCredential = $Credential
    }
    return $params
}

function Export-Report {
    param([string]$Folder)

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $csvPath   = Join-Path $Folder "MigrateServerObjects_$timestamp.csv"
    $jsonPath  = Join-Path $Folder "MigrateServerObjects_$timestamp.json"
    $htmlPath  = Join-Path $Folder "MigrateServerObjects_$timestamp.html"

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
<title>Server Object Migration Report</title>
$style
</head>
<body>
<h1>Server Object Migration Report</h1>
<p><strong>Source:</strong> $SourceInstance<br/>
<strong>Target:</strong> $TargetInstance<br/>
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

if (-not (Get-Module -ListAvailable -Name dbatools)) {
    throw "dbatools module is required. Install with: Install-Module dbatools -Scope CurrentUser"
}
Import-Module dbatools -ErrorAction Stop
Set-DbatoolsConfig -FullName sql.connection.trustcert -Value $true

New-OutputFolder -Path $OutputFolder

# Connectivity validation
try {
    $srcParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
    $srcConn = Test-DbaConnection @srcParams
    Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $SourceInstance -Status "PASS" `
        -Details "Connected to source instance."
}
catch {
    Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $SourceInstance -Status "FAIL" `
        -Details $_.Exception.Message
    Export-Report -Folder $OutputFolder
    throw
}

try {
    $tgtParams = Get-DbaConnectionParams -Instance $TargetInstance -Credential $TargetSqlCredential
    $tgtConn = Test-DbaConnection @tgtParams
    Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $TargetInstance -Status "PASS" `
        -Details "Connected to target instance."
}
catch {
    Add-Result -Category "Connectivity" -ObjectType "SQLInstance" -ObjectName $TargetInstance -Status "FAIL" `
        -Details $_.Exception.Message
    Export-Report -Folder $OutputFolder
    throw
}

# Logins
if ($CopyLogins) {
    try {
        $srcLoginParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
        $logins = Get-DbaLogin @srcLoginParams | Where-Object {
            $_.Name -notin $ExcludeLogins -and $_.Name -notlike '##*'
        }

        foreach ($login in $logins) {
            if ($PSCmdlet.ShouldProcess($TargetInstance, "Copy login $($login.Name)")) {
                try {
                    Copy-DbaLogin `
                        -Source $SourceInstance `
                        -Destination $TargetInstance `
                        -SourceSqlCredential $SourceSqlCredential `
                        -DestinationSqlCredential $TargetSqlCredential `
                        -Login $login.Name `
                        -Force:$Force `
                        -EnableException

                    Add-Result -Category "Migration" -ObjectType "Login" -ObjectName $login.Name -Status "PASS" `
                        -Details "Login copied successfully." -ActionTaken "Copy-DbaLogin"
                }
                catch {
                    Add-Result -Category "Migration" -ObjectType "Login" -ObjectName $login.Name -Status "FAIL" `
                        -Details $_.Exception.Message -ActionTaken "Copy-DbaLogin"
                }
            }
        }
    }
    catch {
        Add-Result -Category "Discovery" -ObjectType "Login" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {
    Add-Result -Category "Config" -ObjectType "Login" -ObjectName "*" -Status "SKIP" `
        -Details "Login copy disabled by parameter."
}

# Credentials
if ($CopyCredentials) {
    try {
        $srcCredParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
        $creds = Get-DbaCredential @srcCredParams | Where-Object { $_.Name -notin $ExcludeCredentials }

        foreach ($cred in $creds) {
            if ($PSCmdlet.ShouldProcess($TargetInstance, "Copy credential $($cred.Name)")) {
                try {
                    Copy-DbaCredential `
                        -Source $SourceInstance `
                        -Destination $TargetInstance `
                        -SourceSqlCredential $SourceSqlCredential `
                        -DestinationSqlCredential $TargetSqlCredential `
                        -Credential $cred.Name `
                        -Force:$Force `
                        -EnableException

                    Add-Result -Category "Migration" -ObjectType "Credential" -ObjectName $cred.Name -Status "PASS" `
                        -Details "Credential copied successfully." -ActionTaken "Copy-DbaCredential"
                }
                catch {
                    Add-Result -Category "Migration" -ObjectType "Credential" -ObjectName $cred.Name -Status "FAIL" `
                        -Details $_.Exception.Message -ActionTaken "Copy-DbaCredential"
                }
            }
        }
    }
    catch {
        Add-Result -Category "Discovery" -ObjectType "Credential" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {
    Add-Result -Category "Config" -ObjectType "Credential" -ObjectName "*" -Status "SKIP" `
        -Details "Credential copy disabled by parameter."
}

# Linked Servers
if ($CopyLinkedServers) {
    try {
        $srcLsParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
        $linkedServers = Get-DbaLinkedServer @srcLsParams | Where-Object { $_.Name -notin $ExcludeLinkedServers }

        foreach ($ls in $linkedServers) {
            if ($PSCmdlet.ShouldProcess($TargetInstance, "Copy linked server $($ls.Name)")) {
                try {
                    Copy-DbaLinkedServer `
                        -Source $SourceInstance `
                        -Destination $TargetInstance `
                        -SourceSqlCredential $SourceSqlCredential `
                        -DestinationSqlCredential $TargetSqlCredential `
                        -LinkedServer $ls.Name `
                        -Force:$Force `
                        -EnableException

                    Add-Result -Category "Migration" -ObjectType "LinkedServer" -ObjectName $ls.Name -Status "PASS" `
                        -Details "Linked server copied successfully." -ActionTaken "Copy-DbaLinkedServer"
                }
                catch {
                    Add-Result -Category "Migration" -ObjectType "LinkedServer" -ObjectName $ls.Name -Status "FAIL" `
                        -Details $_.Exception.Message -ActionTaken "Copy-DbaLinkedServer"
                }
            }
        }
    }
    catch {
        Add-Result -Category "Discovery" -ObjectType "LinkedServer" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {
    Add-Result -Category "Config" -ObjectType "LinkedServer" -ObjectName "*" -Status "SKIP" `
        -Details "Linked server copy disabled by parameter."
}

# Jobs
if ($CopyJobs) {
    try {
        $srcJobParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
        $jobs = Get-DbaAgentJob @srcJobParams | Where-Object { $_.Name -notin $ExcludeJobs }

        foreach ($job in $jobs) {
            if ($PSCmdlet.ShouldProcess($TargetInstance, "Copy SQL Agent job $($job.Name)")) {
                try {
                    Copy-DbaAgentJob `
                        -Source $SourceInstance `
                        -Destination $TargetInstance `
                        -SourceSqlCredential $SourceSqlCredential `
                        -DestinationSqlCredential $TargetSqlCredential `
                        -Job $job.Name `
                        -Force:$Force `
                        -EnableException

                    Add-Result -Category "Migration" -ObjectType "AgentJob" -ObjectName $job.Name -Status "PASS" `
                        -Details "SQL Agent job copied successfully." -ActionTaken "Copy-DbaAgentJob"

                    if ($DisableJobsOnTarget) {
                        try {
                            Disable-DbaAgentJob `
                                -SqlInstance $TargetInstance `
                                -SqlCredential $TargetSqlCredential `
                                -Job $job.Name `
                                -EnableException

                            Add-Result -Category "PostConfig" -ObjectType "AgentJob" -ObjectName $job.Name -Status "PASS" `
                                -Details "Job disabled on target after copy." -ActionTaken "Disable-DbaAgentJob"
                        }
                        catch {
                            Add-Result -Category "PostConfig" -ObjectType "AgentJob" -ObjectName $job.Name -Status "WARN" `
                                -Details $_.Exception.Message -ActionTaken "Disable-DbaAgentJob"
                        }
                    }
                }
                catch {
                    Add-Result -Category "Migration" -ObjectType "AgentJob" -ObjectName $job.Name -Status "FAIL" `
                        -Details $_.Exception.Message -ActionTaken "Copy-DbaAgentJob"
                }
            }
        }
    }
    catch {
        Add-Result -Category "Discovery" -ObjectType "AgentJob" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message
    }
}
else {
    Add-Result -Category "Config" -ObjectType "AgentJob" -ObjectName "*" -Status "SKIP" `
        -Details "Job copy disabled by parameter."
}

# Operators
if ($CopyOperators) {
    try {
        Copy-DbaAgentOperator `
            -Source $SourceInstance `
            -Destination $TargetInstance `
            -SourceSqlCredential $SourceSqlCredential `
            -DestinationSqlCredential $TargetSqlCredential `
            -Force:$Force `
            -EnableException

        Add-Result -Category "Migration" -ObjectType "AgentOperator" -ObjectName "*" -Status "PASS" `
            -Details "Operators copied successfully." -ActionTaken "Copy-DbaAgentOperator"
    }
    catch {
        Add-Result -Category "Migration" -ObjectType "AgentOperator" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Copy-DbaAgentOperator"
    }
}
else {
    Add-Result -Category "Config" -ObjectType "AgentOperator" -ObjectName "*" -Status "SKIP" `
        -Details "Operator copy disabled by parameter."
}

# Alerts
if ($CopyAlerts) {
    try {
        Copy-DbaAgentAlert `
            -Source $SourceInstance `
            -Destination $TargetInstance `
            -SourceSqlCredential $SourceSqlCredential `
            -DestinationSqlCredential $TargetSqlCredential `
            -Force:$Force `
            -EnableException

        Add-Result -Category "Migration" -ObjectType "AgentAlert" -ObjectName "*" -Status "PASS" `
            -Details "Alerts copied successfully." -ActionTaken "Copy-DbaAgentAlert"
    }
    catch {
        Add-Result -Category "Migration" -ObjectType "AgentAlert" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Copy-DbaAgentAlert"
    }
}
else {
    Add-Result -Category "Config" -ObjectType "AgentAlert" -ObjectName "*" -Status "SKIP" `
        -Details "Alert copy disabled by parameter."
}

# Proxies
if ($CopyProxies) {
    try {
        Copy-DbaAgentProxy `
            -Source $SourceInstance `
            -Destination $TargetInstance `
            -SourceSqlCredential $SourceSqlCredential `
            -DestinationSqlCredential $TargetSqlCredential `
            -Force:$Force `
            -EnableException

        Add-Result -Category "Migration" -ObjectType "AgentProxy" -ObjectName "*" -Status "PASS" `
            -Details "Agent proxies copied successfully." -ActionTaken "Copy-DbaAgentProxy"
    }
    catch {
        Add-Result -Category "Migration" -ObjectType "AgentProxy" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Copy-DbaAgentProxy"
    }
}
else {
    Add-Result -Category "Config" -ObjectType "AgentProxy" -ObjectName "*" -Status "SKIP" `
        -Details "Proxy copy disabled by parameter."
}

# Database Mail
if ($CopyDatabaseMail) {
    try {
        Copy-DbaDbMail `
            -Source $SourceInstance `
            -Destination $TargetInstance `
            -SourceSqlCredential $SourceSqlCredential `
            -DestinationSqlCredential $TargetSqlCredential `
            -Force:$Force `
            -EnableException

        Add-Result -Category "Migration" -ObjectType "DatabaseMail" -ObjectName "*" -Status "PASS" `
            -Details "Database Mail copied successfully." -ActionTaken "Copy-DbaDbMail"
    }
    catch {
        Add-Result -Category "Migration" -ObjectType "DatabaseMail" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Copy-DbaDbMail"
    }
}
else {
    Add-Result -Category "Config" -ObjectType "DatabaseMail" -ObjectName "*" -Status "SKIP" `
        -Details "Database Mail copy disabled by parameter."
}

# sp_configure
if ($CopySpConfigure) {
    try {
        Copy-DbaSpConfigure `
            -Source $SourceInstance `
            -Destination $TargetInstance `
            -SourceSqlCredential $SourceSqlCredential `
            -DestinationSqlCredential $TargetSqlCredential `
            -Force:$Force `
            -EnableException

        Add-Result -Category "Migration" -ObjectType "SpConfigure" -ObjectName "*" -Status "PASS" `
            -Details "sp_configure settings copied successfully." -ActionTaken "Copy-DbaSpConfigure"
    }
    catch {
        Add-Result -Category "Migration" -ObjectType "SpConfigure" -ObjectName "*" -Status "FAIL" `
            -Details $_.Exception.Message -ActionTaken "Copy-DbaSpConfigure"
    }
}
else {
    Add-Result -Category "Config" -ObjectType "SpConfigure" -ObjectName "*" -Status "SKIP" `
        -Details "sp_configure copy disabled by parameter."
}

# Post-copy validation
try {
    $srcValParams = Get-DbaConnectionParams -Instance $SourceInstance -Credential $SourceSqlCredential
    $tgtValParams = Get-DbaConnectionParams -Instance $TargetInstance -Credential $TargetSqlCredential

    $sourceCounts = [pscustomobject]@{
        Logins        = (Get-DbaLogin @srcValParams | Where-Object { $_.Name -notin $ExcludeLogins -and $_.Name -notlike '##*' }).Count
        Jobs          = (Get-DbaAgentJob @srcValParams | Where-Object { $_.Name -notin $ExcludeJobs }).Count
        LinkedServers = (Get-DbaLinkedServer @srcValParams | Where-Object { $_.Name -notin $ExcludeLinkedServers }).Count
    }

    $targetCounts = [pscustomobject]@{
        Logins        = (Get-DbaLogin @tgtValParams | Where-Object { $_.Name -notlike '##*' }).Count
        Jobs          = (Get-DbaAgentJob @tgtValParams).Count
        LinkedServers = (Get-DbaLinkedServer @tgtValParams).Count
    }

    Add-Result -Category "Validation" -ObjectType "CountParity" -ObjectName "Logins" -Status "INFO" `
        -Details "Source=$($sourceCounts.Logins); Target=$($targetCounts.Logins)"

    Add-Result -Category "Validation" -ObjectType "CountParity" -ObjectName "Jobs" -Status "INFO" `
        -Details "Source=$($sourceCounts.Jobs); Target=$($targetCounts.Jobs)"

    Add-Result -Category "Validation" -ObjectType "CountParity" -ObjectName "LinkedServers" -Status "INFO" `
        -Details "Source=$($sourceCounts.LinkedServers); Target=$($targetCounts.LinkedServers)"
}
catch {
    Add-Result -Category "Validation" -ObjectType "CountParity" -ObjectName "*" -Status "WARN" `
        -Details $_.Exception.Message
}

Export-Report -Folder $OutputFolder

$failCount = ($script:Results | Where-Object Status -eq 'FAIL' | Measure-Object).Count
if ($failCount -gt 0) {
    Write-Error "Migration completed with $failCount FAIL result(s). Review report before cutover."
    exit 2
}
else {
    Write-Host "Migration completed with no FAIL results." -ForegroundColor Green
    exit 0
}