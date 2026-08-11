<#
.SYNOPSIS
Opens the Streamlit tunnel using Terraform outputs and an existing OCI profile.

.DESCRIPTION
Reads bastion_id, instance_id, private_ip, and region from the currently
selected Terraform state. Reads user, tenancy, fingerprint, and key_file from
an existing OCI CLI profile, validates the resolved values, and delegates to
connect-streamlit-api-key-auth.ps1.

No OCIDs, fingerprints, or API private-key paths are stored in this script.

.EXAMPLE
.\scripts\connect-streamlit-from-terraform.ps1 `
  -ConnectorScriptPath 'C:\focus-loader-report-upload-source\windows-api-key-auth-streamlit\connect-streamlit-api-key-auth.ps1' `
  -SshPrivateKeyPath "$HOME\.ssh\bastion_ed25519"

.EXAMPLE
$env:FOCUS_STREAMLIT_API_KEY_CONNECTOR = 'C:\focus-loader-report-upload-source\windows-api-key-auth-streamlit\connect-streamlit-api-key-auth.ps1'
.\scripts\connect-streamlit-from-terraform.ps1 -ProfileName STREAMLIT_API_KEY -SshPrivateKeyPath "$HOME\.ssh\bastion_ed25519" -DryRun
#>

[CmdletBinding()]
param(
    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform'),

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ProfileName = 'STREAMLIT_API_KEY',

    [string]$OciConfigFilePath = (Join-Path $HOME '.oci\config'),

    [Parameter(Mandatory = $true)]
    [string]$SshPrivateKeyPath,

    [string]$SshPublicKeyPath,

    [string]$ConnectorScriptPath = $env:FOCUS_STREAMLIT_API_KEY_CONNECTOR,

    [string]$TerraformExecutable = 'terraform',

    [string]$OciExecutable = 'oci',

    [string]$SshExecutable = 'ssh',

    [ValidateRange(30, 10800)]
    [int]$BastionSessionTtl = 3600,

    [ValidateRange(1, 65535)]
    [int]$LocalPort = 8501,

    [ValidateRange(1, 65535)]
    [int]$RemotePort = 8501,

    [ValidateRange(60, 3600)]
    [int]$WaitSeconds = 1200,

    [ValidateRange(1, 60)]
    [int]$PollSeconds = 10,

    [ValidatePattern('^[a-z_][a-z0-9_-]*$')]
    [string]$TargetUser = 'oracle',

    [switch]$KeepSession,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$BaseDirectory
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"', "'"))
    if ($expanded -match '^\$\{HOME\}(.*)$') {
        $expanded = $HOME + $Matches[1]
    }
    elseif ($expanded -match '^\$HOME(.*)$') {
        $expanded = $HOME + $Matches[1]
    }
    elseif ($expanded -eq '~') {
        $expanded = $HOME
    }
    elseif ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $HOME $expanded.Substring(2)
    }
    if ($BaseDirectory -and -not [System.IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path $BaseDirectory $expanded
    }
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
        throw "$Label does not exist or is not a file: $expanded"
    }
    return (Resolve-Path -LiteralPath $expanded).Path
}

function Get-OciProfile {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $resolvedConfig = Resolve-RequiredFile -Path $ConfigPath -Label 'OCI config file'
    $values = @{}
    $inSelectedProfile = $false
    foreach ($line in [System.IO.File]::ReadAllLines($resolvedConfig)) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\[([^]]+)\]$') {
            $sectionName = $Matches[1].Trim()
            if ($sectionName.StartsWith('PROFILE ', [System.StringComparison]::OrdinalIgnoreCase)) {
                $sectionName = $sectionName.Substring(8).Trim()
            }
            $inSelectedProfile = $sectionName.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)
            continue
        }
        if (-not $inSelectedProfile -or -not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }
        $separator = $trimmed.IndexOf('=')
        if ($separator -gt 0) {
            $key = $trimmed.Substring(0, $separator).Trim().ToLowerInvariant()
            $values[$key] = $trimmed.Substring($separator + 1).Trim()
        }
    }
    if ($values.Count -eq 0) {
        throw "OCI profile [$Name] was not found in $resolvedConfig"
    }
    foreach ($requiredKey in @('user', 'tenancy', 'fingerprint', 'key_file')) {
        if (-not $values.ContainsKey($requiredKey) -or [string]::IsNullOrWhiteSpace($values[$requiredKey])) {
            throw "OCI profile [$Name] is missing required setting '$requiredKey' in $resolvedConfig"
        }
    }
    return [pscustomobject]@{
        ConfigPath = $resolvedConfig
        ConfigDirectory = Split-Path -Parent $resolvedConfig
        Values = $values
    }
}

function Get-TerraformValue {
    param(
        [Parameter(Mandatory = $true)]$Outputs,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Outputs.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value.value) {
        throw "Terraform output '$Name' is missing or null. Select the deployed workspace and retry."
    }
    $value = [string]$property.Value.value
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Terraform output '$Name' is empty. Select the deployed workspace and retry."
    }
    return $value.Trim()
}

function Resolve-ConnectorScript {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        return Resolve-RequiredFile -Path $RequestedPath -Label 'Streamlit API-key connector script'
    }
    $localCandidate = Join-Path $PSScriptRoot 'connect-streamlit-api-key-auth.ps1'
    if (Test-Path -LiteralPath $localCandidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $localCandidate).Path
    }
    $command = Get-Command connect-streamlit-api-key-auth.ps1 -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }
    throw 'Cannot find connect-streamlit-api-key-auth.ps1. Pass -ConnectorScriptPath or set FOCUS_STREAMLIT_API_KEY_CONNECTOR.'
}

$resolvedTerraformDirectory = (Resolve-Path -LiteralPath $TerraformDirectory -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $resolvedTerraformDirectory -PathType Container)) {
    throw "TerraformDirectory is not a directory: $resolvedTerraformDirectory"
}

$terraformCommand = Get-Command $TerraformExecutable -ErrorAction Stop
$terraformOutput = & $terraformCommand.Source "-chdir=$resolvedTerraformDirectory" output -json
$terraformExitVariable = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
$terraformExitCode = if ($terraformExitVariable) { [int]$terraformExitVariable.Value } else { 0 }
if ($terraformExitCode -ne 0) {
    throw "terraform output failed with exit code $terraformExitCode in $resolvedTerraformDirectory"
}
try {
    $outputs = ($terraformOutput -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "terraform output did not return valid JSON: $($_.Exception.Message)"
}

$bastionId = Get-TerraformValue -Outputs $outputs -Name 'bastion_id'
$instanceId = Get-TerraformValue -Outputs $outputs -Name 'instance_id'
$privateIp = Get-TerraformValue -Outputs $outputs -Name 'private_ip'
$region = Get-TerraformValue -Outputs $outputs -Name 'region'

if ($bastionId -notmatch '^ocid1\.bastion\.') { throw "Invalid Terraform bastion_id: $bastionId" }
if ($instanceId -notmatch '^ocid1\.instance\.') { throw "Invalid Terraform instance_id: $instanceId" }
$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($privateIp, [ref]$parsedIp)) { throw "Invalid Terraform private_ip: $privateIp" }
if ($region -notmatch '^[a-z]{2}-[a-z0-9-]+-[0-9]+$') { throw "Invalid Terraform region: $region" }

$ociProfile = Get-OciProfile -ConfigPath $OciConfigFilePath -Name $ProfileName
$profileValues = $ociProfile.Values
if ($profileValues.user -notmatch '^ocid1\.user\.') { throw "Invalid user OCID in OCI profile [$ProfileName]" }
if ($profileValues.tenancy -notmatch '^ocid1\.tenancy\.') { throw "Invalid tenancy OCID in OCI profile [$ProfileName]" }
if ($profileValues.fingerprint -notmatch '^([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}$') {
    throw "Invalid API-key fingerprint in OCI profile [$ProfileName]"
}

$resolvedApiPrivateKey = Resolve-RequiredFile -Path $profileValues.key_file `
    -Label 'OCI API private key' -BaseDirectory $ociProfile.ConfigDirectory
$resolvedSshPrivateKey = Resolve-RequiredFile -Path $SshPrivateKeyPath -Label 'SSH private key'
$resolvedConnector = Resolve-ConnectorScript -RequestedPath $ConnectorScriptPath

$connectorParameters = @{
    BastionId = $bastionId
    InstanceId = $instanceId
    PrivateIp = $privateIp
    Region = $region
    SshPrivateKeyPath = $resolvedSshPrivateKey
    OciUserId = $profileValues.user
    OciTenancyId = $profileValues.tenancy
    ApiKeyFingerprint = $profileValues.fingerprint
    ApiPrivateKeyPath = $resolvedApiPrivateKey
    ProfileName = $ProfileName
    OciConfigFilePath = $ociProfile.ConfigPath
    BastionSessionTtl = $BastionSessionTtl
    LocalPort = $LocalPort
    RemotePort = $RemotePort
    WaitSeconds = $WaitSeconds
    PollSeconds = $PollSeconds
    TargetUser = $TargetUser
    OciExecutable = $OciExecutable
    SshExecutable = $SshExecutable
    DryRun = $DryRun
    KeepSession = $KeepSession
}
if ($SshPublicKeyPath) {
    $connectorParameters.SshPublicKeyPath = Resolve-RequiredFile -Path $SshPublicKeyPath -Label 'SSH public key'
}

Write-Host "Terraform directory: $resolvedTerraformDirectory"
Write-Host "Terraform workspace resources: Bastion=$bastionId Instance=$instanceId PrivateIp=$privateIp Region=$region"
Write-Host "OCI profile: [$ProfileName] from $($ociProfile.ConfigPath)"
Write-Host "API signing key: $resolvedApiPrivateKey"
Write-Host "SSH private key: $resolvedSshPrivateKey"
Write-Host "Connector: $resolvedConnector"

& $resolvedConnector @connectorParameters
$connectorExitVariable = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
$connectorExitCode = if ($connectorExitVariable) { [int]$connectorExitVariable.Value } else { 0 }
if ($connectorExitCode -ne 0) {
    exit $connectorExitCode
}
