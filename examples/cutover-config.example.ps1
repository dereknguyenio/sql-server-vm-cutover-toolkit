# =============================================================================
# Sample Cutover Configuration
# =============================================================================
# Copy this file, fill in your values, and dot-source it before running scripts.
# Usage:  . .\cutover-config.ps1
# =============================================================================

# --- SQL Instances ---
$SourceInstance    = "oldsql01"          # Source SQL Server (current production)
$PrimaryInstance   = "newsql01"          # New primary replica
$SecondaryInstance = "newsql02"          # New secondary replica

# --- Availability Group ---
$AgName            = "ProdAG"           # AG name on new cluster
$ListenerName      = "sql-prod-listener"
$ListenerPort      = 1433
$EndpointPort      = 5022

# --- Cluster ---
$ClusterName       = "SQLCLUSTER01"
$ExpectedListenerIp = "10.20.4.50"
$ExpectedProbePort  = 59999

# --- Databases ---
$Databases         = @("HFM", "APPDB")

# --- Backup / Restore ---
$BackupPath        = "\\fileserver\sqlbackups\cutover"

# --- Credentials (prompted at runtime - never hardcode) ---
# $SourceSqlCredential = Get-Credential -Message "Source SQL credential"
# $TargetSqlCredential = Get-Credential -Message "Target SQL credential"

# --- Server Object Migration ---
$ExcludeLogins        = @()             # Logins to skip
$ExcludeJobs          = @()             # Jobs to skip
$ExcludeLinkedServers = @()             # Linked servers to skip

# --- Post-Cutover Job Validation ---
$ExpectedEnabledJobs  = @("NightlyBackup", "IndexMaintenance")
$ExpectedDisabledJobs = @("OldReplicationJob")

# --- Output ---
$OutputRoot = ".\CutoverOutput"
