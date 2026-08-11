<#
.SYNOPSIS
Opens the Streamlit tunnel using scripts\output_assets.txt.

.DESCRIPTION
By default, reads validated infrastructure, OCI profile, and key-path values
from output_assets.txt beside this script and delegates to
connect-streamlit-api-key-auth.ps1.

Use -RefreshAssets to rebuild the local inventory from the selected Terraform
state and OCI profile. Use -AssetsOnly with -RefreshAssets to write the file
without opening a connection. output_assets.txt contains sensitive
infrastructure metadata and is intentionally ignored by Git.

.EXAMPLE
.\scripts\connect-streamlit-from-terraform.ps1

.EXAMPLE
.\scripts\connect-streamlit-from-terraform.ps1 -DryRun

.EXAMPLE
.\scripts\connect-streamlit-from-terraform.ps1 -RefreshAssets -AssetsOnly `
  -SshPrivateKeyPath "$HOME\.ssh\bastion_ed25519" `
  -ConnectorScriptPath 'C:\focus-loader-report-upload-source\windows-api-key-auth-streamlit\connect-streamlit-api-key-auth.ps1'
#>

[CmdletBinding()]
param(
    [string]$AssetsFilePath = (Join-Path $PSScriptRoot 'output_assets.txt'),

    [switch]$RefreshAssets,

    [switch]$AssetsOnly,

    [string]$TerraformDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'terraform'),

    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$ProfileName = 'STREAMLIT_API_KEY',

    [string]$OciConfigFilePath = (Join-Path $HOME '.oci\config'),

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

function Expand-AssetPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
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
    return $expanded
}

function Resolve-RequiredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$BaseDirectory
    )

    $expanded = Expand-AssetPath -Path $Path -BaseDirectory $BaseDirectory
    if (-not (Test-Path -LiteralPath $expanded -PathType Leaf)) {
        throw "$Label does not exist or is not a file: $expanded"
    }
    return (Resolve-Path -LiteralPath $expanded).Path
}

function Get-KeyValueFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$AllowedKeys,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $resolvedPath = Resolve-RequiredFile -Path $Path -Label $Label
    $values = @{}
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadAllLines($resolvedPath)) {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) { continue }
        $separator = $trimmed.IndexOf('=')
        if ($separator -le 0) { throw "$Label has an invalid line ${lineNumber}: expected Name=Value" }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim().Trim('"', "'")
        if ($AllowedKeys -notcontains $key) { throw "$Label contains unsupported key '$key' on line $lineNumber" }
        if ($values.ContainsKey($key)) { throw "$Label contains duplicate key '$key'" }
        $values[$key] = $value
    }
    return [pscustomobject]@{ Path = $resolvedPath; Directory = Split-Path -Parent $resolvedPath; Values = $values }
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
            $values[$trimmed.Substring(0, $separator).Trim().ToLowerInvariant()] = $trimmed.Substring($separator + 1).Trim()
        }
    }
    if ($values.Count -eq 0) { throw "OCI profile [$Name] was not found in $resolvedConfig" }
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
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Terraform output '$Name' is empty." }
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
    if ($command) { return $command.Source }
    throw 'Cannot find connect-streamlit-api-key-auth.ps1. Pass -ConnectorScriptPath or set FOCUS_STREAMLIT_API_KEY_CONNECTOR.'
}

function ConvertTo-RequiredInt {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum
    )

    $parsed = 0
    if (-not [int]::TryParse($Values[$Name], [ref]$parsed) -or $parsed -lt $Minimum -or $parsed -gt $Maximum) {
        throw "Asset '$Name' must be an integer from $Minimum through $Maximum"
    }
    return $parsed
}

function Write-AssetsFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Values
    )

    $fullPath = [System.IO.Path]::GetFullPath((Expand-AssetPath -Path $Path))
    $directory = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# Local Streamlit/OCI asset inventory. Do not commit this file.')
    $lines.Add('# Regenerate with generate-output-assets.ps1.')
    foreach ($key in $Values.Keys) { $lines.Add("${key}=$($Values[$key])") }
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($fullPath, $lines, $utf8WithoutBom)
    Write-Host "Wrote local asset inventory: $fullPath"
    return $fullPath
}

$allowedAssetKeys = @(
    'AssetsVersion', 'BastionId', 'InstanceId', 'PrivateIp', 'Region',
    'SshPrivateKeyPath', 'SshPublicKeyPath', 'OciUserId', 'OciTenancyId',
    'ApiKeyFingerprint', 'ApiPrivateKeyPath', 'ProfileName', 'OciConfigFilePath',
    'ConnectorScriptPath', 'BastionSessionTtl', 'LocalPort', 'RemotePort',
    'WaitSeconds', 'PollSeconds', 'TargetUser', 'OciExecutable', 'SshExecutable',
    'KeepSession'
)

if ($AssetsOnly -and -not $RefreshAssets) {
    throw '-AssetsOnly can be used only together with -RefreshAssets.'
}

if ($RefreshAssets) {
    if ([string]::IsNullOrWhiteSpace($SshPrivateKeyPath)) {
        throw '-SshPrivateKeyPath is required with -RefreshAssets.'
    }
    $resolvedTerraformDirectory = (Resolve-Path -LiteralPath $TerraformDirectory -ErrorAction Stop).Path
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
    catch { throw "terraform output did not return valid JSON: $($_.Exception.Message)" }

    $ociProfile = Get-OciProfile -ConfigPath $OciConfigFilePath -Name $ProfileName
    $profileValues = $ociProfile.Values
    $resolvedApiPrivateKey = Resolve-RequiredFile -Path $profileValues.key_file `
        -Label 'OCI API private key' -BaseDirectory $ociProfile.ConfigDirectory
    $resolvedSshPrivateKey = Resolve-RequiredFile -Path $SshPrivateKeyPath -Label 'SSH private key'
    $resolvedConnector = Resolve-ConnectorScript -RequestedPath $ConnectorScriptPath
    $resolvedSshPublicKey = ''
    if ($SshPublicKeyPath) {
        $resolvedSshPublicKey = Resolve-RequiredFile -Path $SshPublicKeyPath -Label 'SSH public key'
    }

    $generatedAssets = [ordered]@{
        AssetsVersion = '1'
        BastionId = Get-TerraformValue -Outputs $outputs -Name 'bastion_id'
        InstanceId = Get-TerraformValue -Outputs $outputs -Name 'instance_id'
        PrivateIp = Get-TerraformValue -Outputs $outputs -Name 'private_ip'
        Region = Get-TerraformValue -Outputs $outputs -Name 'region'
        SshPrivateKeyPath = $resolvedSshPrivateKey
        SshPublicKeyPath = $resolvedSshPublicKey
        OciUserId = $profileValues.user
        OciTenancyId = $profileValues.tenancy
        ApiKeyFingerprint = $profileValues.fingerprint.ToLowerInvariant()
        ApiPrivateKeyPath = $resolvedApiPrivateKey
        ProfileName = $ProfileName
        OciConfigFilePath = $ociProfile.ConfigPath
        ConnectorScriptPath = $resolvedConnector
        BastionSessionTtl = $BastionSessionTtl
        LocalPort = $LocalPort
        RemotePort = $RemotePort
        WaitSeconds = $WaitSeconds
        PollSeconds = $PollSeconds
        TargetUser = $TargetUser
        OciExecutable = $OciExecutable
        SshExecutable = $SshExecutable
        KeepSession = [string][bool]$KeepSession
    }
    $AssetsFilePath = Write-AssetsFile -Path $AssetsFilePath -Values $generatedAssets
    if ($AssetsOnly) { return }
}

$assetFile = Get-KeyValueFile -Path $AssetsFilePath -AllowedKeys $allowedAssetKeys -Label 'Streamlit asset inventory'
$assets = $assetFile.Values
$requiredAssetKeys = @(
    'AssetsVersion', 'BastionId', 'InstanceId', 'PrivateIp', 'Region',
    'SshPrivateKeyPath', 'OciUserId', 'OciTenancyId', 'ApiKeyFingerprint',
    'ApiPrivateKeyPath', 'ProfileName', 'OciConfigFilePath', 'ConnectorScriptPath',
    'BastionSessionTtl', 'LocalPort', 'RemotePort', 'WaitSeconds', 'PollSeconds',
    'TargetUser', 'OciExecutable', 'SshExecutable', 'KeepSession'
)
foreach ($key in $requiredAssetKeys) {
    if (-not $assets.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($assets[$key])) {
        throw "Streamlit asset inventory is missing required value '$key'"
    }
}
if ($assets.AssetsVersion -ne '1') { throw "Unsupported AssetsVersion '$($assets.AssetsVersion)'" }
if ($assets.BastionId -notmatch '^ocid1\.bastion\.') { throw 'Invalid BastionId in asset inventory' }
if ($assets.InstanceId -notmatch '^ocid1\.instance\.') { throw 'Invalid InstanceId in asset inventory' }
$parsedIp = $null
if (-not [System.Net.IPAddress]::TryParse($assets.PrivateIp, [ref]$parsedIp)) { throw 'Invalid PrivateIp in asset inventory' }
if ($assets.Region -notmatch '^[a-z]{2}-[a-z0-9-]+-[0-9]+$') { throw 'Invalid Region in asset inventory' }
if ($assets.OciUserId -notmatch '^ocid1\.user\.') { throw 'Invalid OciUserId in asset inventory' }
if ($assets.OciTenancyId -notmatch '^ocid1\.tenancy\.') { throw 'Invalid OciTenancyId in asset inventory' }
if ($assets.ApiKeyFingerprint -notmatch '^([0-9A-Fa-f]{2}:){15}[0-9A-Fa-f]{2}$') {
    throw 'Invalid ApiKeyFingerprint in asset inventory'
}
if ($assets.ProfileName -notmatch '^[A-Za-z0-9_-]+$') { throw 'Invalid ProfileName in asset inventory' }
if ($assets.TargetUser -notmatch '^[a-z_][a-z0-9_-]*$') { throw 'Invalid TargetUser in asset inventory' }

$resolvedSshPrivateKey = Resolve-RequiredFile -Path $assets.SshPrivateKeyPath `
    -Label 'SSH private key' -BaseDirectory $assetFile.Directory
$resolvedApiPrivateKey = Resolve-RequiredFile -Path $assets.ApiPrivateKeyPath `
    -Label 'OCI API private key' -BaseDirectory $assetFile.Directory
$resolvedOciConfig = Resolve-RequiredFile -Path $assets.OciConfigFilePath `
    -Label 'OCI config file' -BaseDirectory $assetFile.Directory
$resolvedConnector = Resolve-RequiredFile -Path $assets.ConnectorScriptPath `
    -Label 'Streamlit API-key connector script' -BaseDirectory $assetFile.Directory

$fileKeepSession = $false
if (-not [bool]::TryParse($assets.KeepSession, [ref]$fileKeepSession)) {
    throw "Asset 'KeepSession' must be true or false"
}
$connectorParameters = @{
    BastionId = $assets.BastionId
    InstanceId = $assets.InstanceId
    PrivateIp = $assets.PrivateIp
    Region = $assets.Region
    SshPrivateKeyPath = $resolvedSshPrivateKey
    OciUserId = $assets.OciUserId
    OciTenancyId = $assets.OciTenancyId
    ApiKeyFingerprint = $assets.ApiKeyFingerprint
    ApiPrivateKeyPath = $resolvedApiPrivateKey
    ProfileName = $assets.ProfileName
    OciConfigFilePath = $resolvedOciConfig
    BastionSessionTtl = ConvertTo-RequiredInt -Values $assets -Name 'BastionSessionTtl' -Minimum 30 -Maximum 10800
    LocalPort = ConvertTo-RequiredInt -Values $assets -Name 'LocalPort' -Minimum 1 -Maximum 65535
    RemotePort = ConvertTo-RequiredInt -Values $assets -Name 'RemotePort' -Minimum 1 -Maximum 65535
    WaitSeconds = ConvertTo-RequiredInt -Values $assets -Name 'WaitSeconds' -Minimum 60 -Maximum 3600
    PollSeconds = ConvertTo-RequiredInt -Values $assets -Name 'PollSeconds' -Minimum 1 -Maximum 60
    TargetUser = $assets.TargetUser
    OciExecutable = $assets.OciExecutable
    SshExecutable = $assets.SshExecutable
    DryRun = $DryRun
    KeepSession = ($KeepSession -or $fileKeepSession)
}
if ($assets.ContainsKey('SshPublicKeyPath') -and $assets.SshPublicKeyPath) {
    $connectorParameters.SshPublicKeyPath = Resolve-RequiredFile -Path $assets.SshPublicKeyPath `
        -Label 'SSH public key' -BaseDirectory $assetFile.Directory
}

Write-Host "Asset inventory: $($assetFile.Path)"
Write-Host "Resources: Bastion=$($assets.BastionId) Instance=$($assets.InstanceId) PrivateIp=$($assets.PrivateIp) Region=$($assets.Region)"
Write-Host "OCI profile: [$($assets.ProfileName)] from $resolvedOciConfig"
Write-Host "SSH private key: $resolvedSshPrivateKey"
Write-Host "Connector: $resolvedConnector"

& $resolvedConnector @connectorParameters
$connectorExitVariable = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
$connectorExitCode = if ($connectorExitVariable) { [int]$connectorExitVariable.Value } else { 0 }
if ($connectorExitCode -ne 0) { exit $connectorExitCode }
