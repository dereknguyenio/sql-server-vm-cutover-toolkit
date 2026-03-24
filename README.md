# SQL Server Always On AG - Cutover Toolkit

Production cutover and validation scripts for migrating SQL Server databases to a new Always On Availability Group on Azure VMs.

## Overview

This toolkit provides four scripts that cover the end-to-end cutover workflow. Each script produces HTML, CSV, and JSON reports.

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `PreCutoverReadiness.ps1` | Validate AG, cluster, listener, replicas, backups, and server objects before cutover |
| 2 | `MigrateServerObjects.ps1` | Copy logins, jobs, linked servers, credentials, operators, alerts, proxies, database mail, sp_configure |
| 3 | `DatabaseRefresh.ps1` | Backup from source, restore to new primary, add to AG with automatic seeding |
| 4 | `PostCutoverValidation.ps1` | Validate listener routing, AG health, sync state, backups, jobs, and run smoke tests |

## Prerequisites

- PowerShell 5.1+
- [dbatools](https://dbatools.io/) module
- FailoverClusters module (for cluster checks)
- SQL Server 2016+ on target (automatic seeding support)
- Shared backup path accessible from source and target

```powershell
Install-Module dbatools -Scope CurrentUser
```

## Quick Start

### 1. Configure your environment

Copy and edit the sample config:

```powershell
cp .\examples\cutover-config.example.ps1 .\cutover-config.ps1
# Edit cutover-config.ps1 with your values
. .\cutover-config.ps1
```

### 2. Pre-cutover readiness check

```powershell
.\PreCutoverReadiness.ps1 `
  -PrimaryInstance $PrimaryInstance `
  -SecondaryInstance $SecondaryInstance `
  -AgName $AgName `
  -ListenerName $ListenerName `
  -Databases $Databases `
  -ClusterName $ClusterName `
  -ExpectedListenerIp $ExpectedListenerIp `
  -ExpectedProbePort $ExpectedProbePort
```

### 3. Migrate server objects

```powershell
$srcCred = Get-Credential -Message "Source SQL credential"
$tgtCred = Get-Credential -Message "Target SQL credential"

.\MigrateServerObjects.ps1 `
  -SourceInstance $SourceInstance `
  -TargetInstance $PrimaryInstance `
  -SourceSqlCredential $srcCred `
  -TargetSqlCredential $tgtCred `
  -ExcludeLogins $ExcludeLogins `
  -ExcludeJobs $ExcludeJobs `
  -DisableJobsOnTarget
```

### 4. Database refresh (backup/restore + AG seeding)

```powershell
.\DatabaseRefresh.ps1 `
  -SourceInstance $SourceInstance `
  -PrimaryInstance $PrimaryInstance `
  -AgName $AgName `
  -Databases $Databases `
  -BackupPath $BackupPath `
  -SourceSqlCredential $srcCred `
  -TargetSqlCredential $tgtCred `
  -Force
```

### 5. Post-cutover validation

```powershell
.\PostCutoverValidation.ps1 `
  -PrimaryInstance $PrimaryInstance `
  -SecondaryInstance $SecondaryInstance `
  -ListenerName $ListenerName `
  -ExpectedPrimary $PrimaryInstance `
  -AgName $AgName `
  -Databases $Databases `
  -ExpectedEnabledJobs $ExpectedEnabledJobs `
  -ExpectedDisabledJobs $ExpectedDisabledJobs `
  -TestLinkedServers `
  -SmokeTestFile ".\examples\smoke-tests.example.json"
```

## Smoke Tests

Post-cutover validation supports custom smoke test queries via a JSON file. See [examples/smoke-tests.example.json](examples/smoke-tests.example.json).

Each entry can optionally include `ExpectedScalar` to assert a specific return value:

```json
[
  {
    "Name": "Verify row count",
    "Database": "HFM",
    "Query": "SELECT COUNT(*) FROM dbo.Accounts",
    "ExpectedScalar": "1500"
  }
]
```

## Reports

Each script generates timestamped reports in its output folder:

- **HTML** - Color-coded results table (PASS/WARN/FAIL/INFO)
- **CSV** - Machine-readable for import into Excel or other tools
- **JSON** - Structured data for programmatic consumption

## Parameters Reference

All scripts accept SQL credentials via `-SqlCredential` or `-SourceSqlCredential`/`-TargetSqlCredential` parameters. **Never hardcode credentials.** Use `Get-Credential` or a secrets manager at runtime.

### Common optional parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SkipClusterChecks` | `$false` | Skip WSFC validation (if running from a non-cluster node) |
| `-BackupMaxAgeHours` | `24` | Threshold for backup recency warnings |
| `-OutputFolder` | Script-specific | Directory for report output |

## License

MIT
