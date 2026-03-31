# SQL Server AG Cutover Runbook

**Purpose:** Step-by-step guide for production cutover from legacy SQL Server to a new Always On Availability Group on Azure VMs.

**Estimated time:** 2–4 hours depending on database sizes and number of objects.

---

## Before You Begin

### Prerequisites

- [ ] PowerShell 5.1 or later (run `$PSVersionTable.PSVersion`)
- [ ] dbatools module installed: `Install-Module dbatools -Scope CurrentUser`
- [ ] FailoverClusters module available on the machine you're running from, OR run scripts directly on the primary SQL VM
- [ ] Network access from your workstation to source and target SQL instances
- [ ] Shared backup path accessible from **both** source and target SQL servers (UNC path, e.g. `\\fileserver\sqlbackups\cutover`)
- [ ] SQL credentials with sysadmin on source and target

### Download the scripts

```powershell
git clone https://github.com/dereknguyenio/sql-server-vm-cutover-toolkit.git
cd sql-server-vm-cutover-toolkit
```

---

## Step 0 — Configure Your Environment

Copy the example config and fill in your values:

```powershell
Copy-Item .\examples\cutover-config.example.ps1 .\cutover-config.ps1
notepad .\cutover-config.ps1
```

Minimum required values to set:

| Variable | Example | Description |
|---|---|---|
| `$SourceInstance` | `oldsql01` | Current production SQL Server |
| `$PrimaryInstance` | `newsql01` | New primary AG replica |
| `$SecondaryInstance` | `newsql02` | New secondary AG replica |
| `$DRInstance` | `newsql03` | DR AG replica (optional) |
| `$AgName` | `ProdAG` | Availability Group name |
| `$ListenerName` | `sql-prod-listener` | AG listener DNS name |
| `$Databases` | `@("HFM","APPDB")` | Databases to cut over |
| `$BackupPath` | `\\fileserver\sqlbackups\cutover` | Shared UNC backup path |
| `$ClusterName` | `SQLCLUSTER01` | Windows Failover Cluster name |
| `$ExpectedListenerIp` | `10.20.4.50` | Listener IP (from Azure ILB) |

Load the config into your session:

```powershell
. .\cutover-config.ps1
```

Set credentials (you will be prompted — do not hardcode passwords):

```powershell
$SourceCred = Get-Credential -Message "Source SQL sysadmin credential"
$TargetCred = Get-Credential -Message "Target SQL sysadmin credential"
```

---

## Step 1 — Pre-Cutover Readiness Check

**Run this before the cutover window. Fix any FAILs before proceeding.**

```powershell
.\PreCutoverReadiness.ps1 `
    -PrimaryInstance   $PrimaryInstance `
    -SecondaryInstance $SecondaryInstance `
    -DRInstance        $DRInstance `
    -AgName            $AgName `
    -ListenerName      $ListenerName `
    -Databases         $Databases `
    -ClusterName       $ClusterName `
    -ExpectedListenerIp $ExpectedListenerIp `
    -ExpectedProbePort  $ExpectedProbePort `
    -SqlCredential      $TargetCred `
    -OutputFolder       "$OutputRoot\PreCutover"
```

**What it checks:**
- AG health and replica sync state
- Listener IP and port reachability
- WSFC cluster health
- Backup recency on all databases
- Server object inventory (logins, jobs, linked servers)

**Expected result:** All checks PASS or WARN. No FAILs.

Open the HTML report to review:
```powershell
Invoke-Item "$OutputRoot\PreCutover\*.html"
```

---

## Step 2 — Schedule the Cutover Window

Once Step 1 is all green:

- [ ] Notify application teams of the cutover window
- [ ] Confirm backup has completed within the last hour
- [ ] Confirm no long-running transactions on source (`SELECT * FROM sys.dm_exec_requests`)
- [ ] Have rollback plan ready (see [Rollback](#rollback) at bottom)

---

## Step 3 — Migrate Server Objects

**Run at the start of the cutover window. Applications can still be up at this point.**

Copies logins, SQL Agent jobs, linked servers, credentials, operators, alerts, proxies, database mail, and sp_configure settings from source to target.

```powershell
.\MigrateServerObjects.ps1 `
    -SourceInstance       $SourceInstance `
    -TargetInstance       $PrimaryInstance `
    -SourceSqlCredential  $SourceCred `
    -TargetSqlCredential  $TargetCred `
    -ExcludeLogins        $ExcludeLogins `
    -ExcludeJobs          $ExcludeJobs `
    -ExcludeLinkedServers $ExcludeLinkedServers `
    -DisableJobsOnTarget `
    -Force `
    -OutputFolder "$OutputRoot\ServerObjects"
```

> `-DisableJobsOnTarget` keeps SQL Agent jobs disabled on the new server until you're ready to enable them. `-Force` overwrites any objects that already exist.

**Review the report:**
```powershell
Invoke-Item "$OutputRoot\ServerObjects\*.html"
```

---

## Step 4 — Stop Applications / Quiesce

> **This is the start of downtime.**

- [ ] Stop or redirect application connections to prevent new writes to source
- [ ] Confirm no active connections on source databases:

```sql
-- Run on source SQL Server
SELECT session_id, login_name, host_name, program_name, status
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID('HFM')
  AND session_id <> @@SPID
```

---

## Step 5 — Database Refresh (Backup → Restore → AG Seeding)

**Takes the final backup of source databases, restores to new primary, then adds them to the AG with automatic seeding to the secondary.**

```powershell
.\DatabaseRefresh.ps1 `
    -SourceInstance      $SourceInstance `
    -PrimaryInstance     $PrimaryInstance `
    -AgName              $AgName `
    -Databases           $Databases `
    -BackupPath          $BackupPath `
    -SourceSqlCredential $SourceCred `
    -TargetSqlCredential $TargetCred `
    -Force `
    -OutputFolder "$OutputRoot\DatabaseRefresh"
```

**What it does:**
1. Takes a full backup of each database on source
2. Restores to new primary (with NORECOVERY)
3. Adds each database to the AG
4. Waits for automatic seeding to complete on secondary

**Review the report:**
```powershell
Invoke-Item "$OutputRoot\DatabaseRefresh\*.html"
```

---

## Step 6 — Post-Cutover Validation

**Validate everything is healthy on the new AG before redirecting traffic.**

```powershell
.\PostCutoverValidation.ps1 `
    -PrimaryInstance       $PrimaryInstance `
    -SecondaryInstance     $SecondaryInstance `
    -DRInstance            $DRInstance `
    -ListenerName          $ListenerName `
    -ExpectedPrimary       $PrimaryInstance `
    -AgName                $AgName `
    -Databases             $Databases `
    -SqlCredential         $TargetCred `
    -ClusterName           $ClusterName `
    -ExpectedEnabledJobs   $ExpectedEnabledJobs `
    -ExpectedDisabledJobs  $ExpectedDisabledJobs `
    -TestLinkedServers `
    -SmokeTestFile         ".\examples\smoke-tests.example.json" `
    -OutputFolder          "$OutputRoot\PostCutover"
```

**What it validates:**
- Listener is reachable and routing to correct primary
- All databases are SYNCHRONIZED (not just joined)
- Log send queue and redo queue are within thresholds
- Recent backup exists on the AG
- Jobs are in expected enabled/disabled state
- Linked server connectivity
- Custom smoke test queries

**Expected result:** All checks PASS. Open report:
```powershell
Invoke-Item "$OutputRoot\PostCutover\*.html"
```

---

## Step 7 — Redirect Applications

Once Step 6 is all green:

- [ ] Update application connection strings to point to the **listener** (`$ListenerName` or `$ListenerName.$DomainName`, port 1433)
- [ ] Enable SQL Agent jobs on the new primary:

```sql
-- Run on new primary via listener
EXEC msdb.dbo.sp_update_job @job_name = 'NightlyBackup', @enabled = 1;
EXEC msdb.dbo.sp_update_job @job_name = 'IndexMaintenance', @enabled = 1;
```

- [ ] Smoke test the application end-to-end
- [ ] Confirm application teams sign off

---

## Step 8 — Post-Cutover Housekeeping

- [ ] Keep source SQL Server online but offline from applications for 24–48 hours as a safety net
- [ ] After sign-off period, decommission source
- [ ] Archive cutover reports from `$OutputRoot`

---

## Rollback

If validation fails before application redirect (Step 7), you can roll back with zero data loss:

1. Stop all writes to the new primary
2. Point applications back to the source SQL Server (original connection strings)
3. Verify source is still intact with original data
4. Document what failed and schedule a new cutover window

> If applications were already redirected and you need to roll back, restore from the backup taken in Step 5 and contact your DBA team.

---

## Troubleshooting

| Error | Likely cause | Fix |
|---|---|---|
| `Cannot connect to Source instance` | Firewall / wrong instance name | Verify TCP 1433 open, check `$SourceInstance` value |
| `The certificate chain was not trusted` | SQL Server 2022 cert enforcement | dbatools trust cert is set automatically by scripts |
| `AG does not exist or you do not have permission` | Credentials lack sysadmin | Confirm `$TargetCred` has sysadmin on target |
| `Log send queue exceeds threshold` (WARN) | Replica lag | Wait for sync, or increase `-MaxLogSendQueueKB` threshold |
| `Backup older than 24 hours` (WARN) | No recent backup | Take a manual backup before proceeding |
| Linked server connectivity FAIL | Linked server creds not migrated | Manually update linked server passwords on target |

---

## Output Files

All reports land in `$OutputRoot` (default: `.\CutoverOutput`):

```
CutoverOutput\
  PreCutover\
    PreCutoverReadiness_<timestamp>.html   ← open this
    PreCutoverReadiness_<timestamp>.csv
    PreCutoverReadiness_<timestamp>.json
  ServerObjects\
    MigrateServerObjects_<timestamp>.html
  DatabaseRefresh\
    DatabaseRefresh_<timestamp>.html
  PostCutover\
    PostCutoverValidation_<timestamp>.html
```

Save these reports as evidence of the cutover.
