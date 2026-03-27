# Cutover Validation Guide

Two scripts to validate your new SQL Server Always On AG — one before cutover, one after.

---

## Prerequisites

Run once on the machine where you'll execute the scripts:

```powershell
Install-Module dbatools -Scope CurrentUser -Force
```

Clone the toolkit:

```powershell
git clone https://github.com/dereknguyenio/sql-server-vm-cutover-toolkit.git
cd sql-server-vm-cutover-toolkit
```

---

## Step 1 — Fill in your values

Open `examples\cutover-config.example.ps1`, fill in your environment, save as `cutover-config.ps1`:

```powershell
Copy-Item .\examples\cutover-config.example.ps1 .\cutover-config.ps1
notepad .\cutover-config.ps1
```

Key values to set:

```powershell
$PrimaryInstance    = "newsql01"           # new primary SQL instance
$SecondaryInstance  = "newsql02"           # new secondary SQL instance
$AgName             = "ProdAG"             # Availability Group name
$ListenerName       = "sql-prod-listener"  # AG listener DNS name
$ClusterName        = "SQLCLUSTER01"       # Windows Failover Cluster name
$ExpectedListenerIp = "10.x.x.x"          # listener IP from Azure ILB
$Databases          = @("HFM", "APPDB")    # databases in the AG
```

Load the config:

```powershell
. .\cutover-config.ps1
$Cred = Get-Credential -Message "SQL sysadmin credential"
```

---

## Pre-Cutover Validation

Run this **before the cutover window** to confirm the new cluster is ready.

```powershell
.\PreCutoverReadiness.ps1 `
    -PrimaryInstance    $PrimaryInstance `
    -SecondaryInstance  $SecondaryInstance `
    -AgName             $AgName `
    -ListenerName       $ListenerName `
    -Databases          $Databases `
    -ClusterName        $ClusterName `
    -ExpectedListenerIp $ExpectedListenerIp `
    -ExpectedProbePort  $ExpectedProbePort `
    -SqlCredential      $Cred `
    -OutputFolder       ".\Output\PreCutover"
```

View the report:

```powershell
Invoke-Item .\Output\PreCutover\*.html
```

**All checks should be PASS before proceeding with cutover.** Fix any FAILs first.

---

## Post-Cutover Validation

Run this **immediately after cutover** to confirm everything is healthy on the new AG.

```powershell
.\PostCutoverValidation.ps1 `
    -PrimaryInstance    $PrimaryInstance `
    -SecondaryInstance  $SecondaryInstance `
    -ListenerName       $ListenerName `
    -ExpectedPrimary    $PrimaryInstance `
    -AgName             $AgName `
    -Databases          $Databases `
    -SqlCredential      $Cred `
    -ClusterName        $ClusterName `
    -OutputFolder       ".\Output\PostCutover"
```

View the report:

```powershell
Invoke-Item .\Output\PostCutover\*.html
```

**All checks should be PASS before redirecting application traffic.**

---

## What Gets Checked

| Check | Pre-Cutover | Post-Cutover |
|---|:---:|:---:|
| AG exists and is healthy | ✓ | ✓ |
| Primary/secondary replicas connected | ✓ | ✓ |
| All databases synchronized | ✓ | ✓ |
| Listener reachable on correct IP/port | ✓ | ✓ |
| WSFC cluster health | ✓ | ✓ |
| Recent backup exists | ✓ | ✓ |
| Log send / redo queue within threshold | | ✓ |
| Listener routing to correct primary | | ✓ |
| SQL Agent jobs in expected state | | ✓ |

Reports are saved as HTML, CSV, and JSON in the `.\Output` folder.
