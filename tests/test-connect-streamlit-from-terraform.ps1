$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptUnderTest = Join-Path $projectRoot 'scripts\connect-streamlit-from-terraform.ps1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("focus-streamlit-test-{0}" -f [guid]::NewGuid().ToString('N'))

try {
    $terraformDirectory = Join-Path $testRoot 'terraform'
    $ociDirectory = Join-Path $testRoot '.oci'
    $sshDirectory = Join-Path $testRoot '.ssh'
    New-Item -ItemType Directory -Path $terraformDirectory, $ociDirectory, $sshDirectory | Out-Null

    $apiKey = Join-Path $ociDirectory 'api.pem'
    $sshKey = Join-Path $sshDirectory 'bastion_ed25519'
    Set-Content -LiteralPath $apiKey -Value 'test-only-api-key'
    Set-Content -LiteralPath $sshKey -Value 'test-only-ssh-key'

    $configPath = Join-Path $ociDirectory 'config'
    @"
[STREAMLIT_API_KEY]
user=ocid1.user.oc1..testuser
fingerprint=aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99
key_file=api.pem
tenancy=ocid1.tenancy.oc1..testtenancy
region=eu-frankfurt-1
"@ | Set-Content -LiteralPath $configPath

    $terraformMock = Join-Path $testRoot 'terraform-mock.ps1'
    @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
@{
    bastion_id = @{ value = 'ocid1.bastion.oc1.eu-frankfurt-1.testbastion' }
    instance_id = @{ value = 'ocid1.instance.oc1.eu-frankfurt-1.testinstance' }
    private_ip = @{ value = '10.30.1.159' }
    region = @{ value = 'eu-frankfurt-1' }
} | ConvertTo-Json -Depth 4
'@ | Set-Content -LiteralPath $terraformMock

    $capturePath = Join-Path $testRoot 'captured.json'
    $connectorMock = Join-Path $testRoot 'connector-mock.ps1'
    @'
param(
    [string]$BastionId, [string]$InstanceId, [string]$PrivateIp, [string]$Region,
    [string]$SshPrivateKeyPath, [string]$SshPublicKeyPath,
    [string]$OciUserId, [string]$OciTenancyId, [string]$ApiKeyFingerprint,
    [string]$ApiPrivateKeyPath, [string]$ProfileName, [string]$OciConfigFilePath,
    [int]$BastionSessionTtl, [int]$LocalPort, [int]$RemotePort,
    [int]$WaitSeconds, [int]$PollSeconds, [string]$TargetUser,
    [string]$OciExecutable, [string]$SshExecutable,
    [switch]$ReplaceExistingProfile, [switch]$KeepSession, [switch]$DryRun
)
@{
    BastionId = $BastionId; InstanceId = $InstanceId; PrivateIp = $PrivateIp; Region = $Region
    OciUserId = $OciUserId; OciTenancyId = $OciTenancyId; ApiKeyFingerprint = $ApiKeyFingerprint
    ApiPrivateKeyPath = $ApiPrivateKeyPath; ProfileName = $ProfileName
    SshPrivateKeyPath = $SshPrivateKeyPath; DryRun = [bool]$DryRun
} | ConvertTo-Json | Set-Content -LiteralPath $env:CONNECTOR_CAPTURE_PATH
'@ | Set-Content -LiteralPath $connectorMock

    $env:CONNECTOR_CAPTURE_PATH = $capturePath
    & $scriptUnderTest `
        -TerraformDirectory $terraformDirectory `
        -TerraformExecutable $terraformMock `
        -OciConfigFilePath $configPath `
        -ProfileName STREAMLIT_API_KEY `
        -SshPrivateKeyPath $sshKey `
        -ConnectorScriptPath $connectorMock `
        -DryRun

    $captured = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json
    if ($captured.BastionId -ne 'ocid1.bastion.oc1.eu-frankfurt-1.testbastion') { throw 'BastionId was not forwarded.' }
    if ($captured.InstanceId -ne 'ocid1.instance.oc1.eu-frankfurt-1.testinstance') { throw 'InstanceId was not forwarded.' }
    if ($captured.PrivateIp -ne '10.30.1.159') { throw 'PrivateIp was not forwarded.' }
    if ($captured.Region -ne 'eu-frankfurt-1') { throw 'Region was not forwarded.' }
    if ($captured.OciUserId -ne 'ocid1.user.oc1..testuser') { throw 'OCI user was not read from the profile.' }
    if ($captured.OciTenancyId -ne 'ocid1.tenancy.oc1..testtenancy') { throw 'OCI tenancy was not read from the profile.' }
    if ($captured.ApiKeyFingerprint -ne 'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99') { throw 'Fingerprint was not read from the profile.' }
    if ($captured.ApiPrivateKeyPath -ne (Resolve-Path -LiteralPath $apiKey).Path) { throw 'Relative API key path was not resolved.' }
    if (-not $captured.DryRun) { throw 'DryRun was not forwarded.' }

    Write-Host 'PASS: Terraform outputs and OCI API-key profile were resolved and forwarded.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\CONNECTOR_CAPTURE_PATH -ErrorAction SilentlyContinue
}
