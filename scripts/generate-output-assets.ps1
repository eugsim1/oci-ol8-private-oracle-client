<#
.SYNOPSIS
Generates scripts\output_assets.txt for the Streamlit Bastion launcher.

.DESCRIPTION
Reads the active Terraform workspace outputs and an existing OCI API-key
profile, validates all identifiers and key paths, and writes the local asset
inventory. It never creates a Bastion session or opens SSH.

.EXAMPLE
.\scripts\generate-output-assets.ps1 `
  -SshPrivateKeyPath "$HOME\.ssh\bastion_ed25519" `
  -ConnectorScriptPath 'C:\focus-loader-report-upload-source\windows-api-key-auth-streamlit\connect-streamlit-api-key-auth.ps1'
#>

[CmdletBinding()]
param(
    [string]$AssetsFilePath = (Join-Path $PSScriptRoot 'output_assets.txt'),

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

    [switch]$KeepSession
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'connect-streamlit-from-terraform.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Streamlit launcher is missing: $launcher"
}

$launcherParameters = @{
    AssetsFilePath = $AssetsFilePath
    RefreshAssets = $true
    AssetsOnly = $true
    TerraformDirectory = $TerraformDirectory
    ProfileName = $ProfileName
    OciConfigFilePath = $OciConfigFilePath
    SshPrivateKeyPath = $SshPrivateKeyPath
    TerraformExecutable = $TerraformExecutable
    OciExecutable = $OciExecutable
    SshExecutable = $SshExecutable
    BastionSessionTtl = $BastionSessionTtl
    LocalPort = $LocalPort
    RemotePort = $RemotePort
    WaitSeconds = $WaitSeconds
    PollSeconds = $PollSeconds
    TargetUser = $TargetUser
    KeepSession = $KeepSession
}
if ($SshPublicKeyPath) { $launcherParameters.SshPublicKeyPath = $SshPublicKeyPath }
if ($ConnectorScriptPath) { $launcherParameters.ConnectorScriptPath = $ConnectorScriptPath }

& $launcher @launcherParameters
$launcherExitVariable = Get-Variable LASTEXITCODE -ErrorAction SilentlyContinue
$launcherExitCode = if ($launcherExitVariable) { [int]$launcherExitVariable.Value } else { 0 }
if ($launcherExitCode -ne 0) { exit $launcherExitCode }
