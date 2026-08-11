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
    $sshPublicKey = "${sshKey}.pub"
    Set-Content -LiteralPath $apiKey -Value 'test-only-api-key'
    Set-Content -LiteralPath $sshKey -Value 'test-only-ssh-key'
    Set-Content -LiteralPath $sshPublicKey -Value 'ssh-ed25519 AAAATESTONLY'

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
    SshPrivateKeyPath = $SshPrivateKeyPath; SshPublicKeyPath = $SshPublicKeyPath
    LocalPort = $LocalPort; DryRun = [bool]$DryRun
} | ConvertTo-Json | Set-Content -LiteralPath $env:CONNECTOR_CAPTURE_PATH
'@ | Set-Content -LiteralPath $connectorMock

    $assetsPath = Join-Path $testRoot 'output_assets.txt'
    $env:CONNECTOR_CAPTURE_PATH = $capturePath
    & $scriptUnderTest `
        -AssetsFilePath $assetsPath `
        -RefreshAssets `
        -AssetsOnly `
        -TerraformDirectory $terraformDirectory `
        -TerraformExecutable $terraformMock `
        -OciConfigFilePath $configPath `
        -ProfileName STREAMLIT_API_KEY `
        -SshPrivateKeyPath $sshKey `
        -SshPublicKeyPath $sshPublicKey `
        -ConnectorScriptPath $connectorMock

    if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) { throw 'Asset inventory was not created.' }
    if (Test-Path -LiteralPath $capturePath) { throw 'AssetsOnly unexpectedly invoked the connector.' }
    $assetText = Get-Content -Raw -LiteralPath $assetsPath
    foreach ($expected in @('AssetsVersion=1', 'BastionId=ocid1.bastion.', 'InstanceId=ocid1.instance.',
            'PrivateIp=10.30.1.159', 'ProfileName=STREAMLIT_API_KEY', "SshPrivateKeyPath=$sshKey")) {
        if (-not $assetText.Contains($expected)) { throw "Generated inventory is missing: $expected" }
    }
    if ($assetText.Contains('test-only-api-key') -or $assetText.Contains('test-only-ssh-key')) {
        throw 'Generated inventory contains private-key contents.'
    }

    & $scriptUnderTest -AssetsFilePath $assetsPath -DryRun

    $captured = Get-Content -Raw -LiteralPath $capturePath | ConvertFrom-Json
    if ($captured.BastionId -ne 'ocid1.bastion.oc1.eu-frankfurt-1.testbastion') { throw 'BastionId was not forwarded.' }
    if ($captured.InstanceId -ne 'ocid1.instance.oc1.eu-frankfurt-1.testinstance') { throw 'InstanceId was not forwarded.' }
    if ($captured.PrivateIp -ne '10.30.1.159') { throw 'PrivateIp was not forwarded.' }
    if ($captured.OciUserId -ne 'ocid1.user.oc1..testuser') { throw 'OCI user was not loaded.' }
    if ($captured.OciTenancyId -ne 'ocid1.tenancy.oc1..testtenancy') { throw 'OCI tenancy was not loaded.' }
    if ($captured.ApiPrivateKeyPath -ne (Resolve-Path -LiteralPath $apiKey).Path) { throw 'API key path was not loaded.' }
    if ($captured.SshPrivateKeyPath -ne (Resolve-Path -LiteralPath $sshKey).Path) { throw 'SSH key path was not loaded.' }
    if ($captured.SshPublicKeyPath -ne (Resolve-Path -LiteralPath $sshPublicKey).Path) { throw 'SSH public key path was not loaded.' }
    if (-not $captured.DryRun) { throw 'DryRun was not forwarded.' }

    Write-Host 'PASS: asset inventory generation, validation, and execution succeeded.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\CONNECTOR_CAPTURE_PATH -ErrorAction SilentlyContinue
}
