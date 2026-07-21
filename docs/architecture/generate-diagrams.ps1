param(
  [Parameter(Mandatory = $true)]
  [string]$OciLibraryPath
)

$ErrorActionPreference = 'Stop'
$outputDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$libraryText = Get-Content -LiteralPath $OciLibraryPath -Raw
$libraryJson = $libraryText -replace '^<mxlibrary>', '' -replace '</mxlibrary>$', ''
$script:library = @{}
foreach ($item in ($libraryJson | ConvertFrom-Json)) {
  if ($null -ne $item.title -and $item.title.Length -gt 0) {
    $script:library[$item.title] = $item
  }
}

function Decode-OciStencil([string]$title) {
  if (-not $script:library.ContainsKey($title)) {
    throw "OCI stencil not found: $title"
  }
  $bytes = [Convert]::FromBase64String($script:library[$title].xml)
  $memory = New-Object IO.MemoryStream(, $bytes)
  $deflate = New-Object IO.Compression.DeflateStream($memory, [IO.Compression.CompressionMode]::Decompress)
  $reader = New-Object IO.StreamReader($deflate, [Text.Encoding]::UTF8)
  try {
    [xml]([Uri]::UnescapeDataString($reader.ReadToEnd()))
  }
  finally {
    $reader.Dispose()
    $deflate.Dispose()
    $memory.Dispose()
  }
}

function New-Diagram([string]$name, [int]$width, [int]$height) {
  [xml]$document = @"
<mxfile host="app.diagrams.net" modified="2026-07-21T00:00:00.000Z" agent="Codex using Oracle OCI Architecture Diagram Toolkit" version="26.0.16" type="device">
  <diagram id="$([Guid]::NewGuid().ToString('N'))" name="$name">
    <mxGraphModel dx="1800" dy="1200" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="$width" pageHeight="$height" math="0" shadow="0">
      <root><mxCell id="0"/><mxCell id="1" parent="0"/></root>
    </mxGraphModel>
  </diagram>
</mxfile>
"@
  $document
}

function Add-Vertex {
  param([xml]$Document, [string]$Id, [string]$Value, [string]$Style,
    [double]$X, [double]$Y, [double]$Width, [double]$Height, [string]$Parent = '1')
  $cell = $Document.CreateElement('mxCell')
  $cell.SetAttribute('id', $Id)
  $cell.SetAttribute('value', $Value)
  $cell.SetAttribute('style', $Style)
  $cell.SetAttribute('vertex', '1')
  $cell.SetAttribute('parent', $Parent)
  $geometry = $Document.CreateElement('mxGeometry')
  $geometry.SetAttribute('x', [string]$X)
  $geometry.SetAttribute('y', [string]$Y)
  $geometry.SetAttribute('width', [string]$Width)
  $geometry.SetAttribute('height', [string]$Height)
  $geometry.SetAttribute('as', 'geometry')
  [void]$cell.AppendChild($geometry)
  [void]$Document.mxfile.diagram.mxGraphModel.root.AppendChild($cell)
  $Id
}

function Add-Edge {
  param([xml]$Document, [string]$Id, [string]$Source, [string]$Target,
    [string]$Value = '', [bool]$Dashed = $false, [string]$Color = '#2D5967')
  $dash = if ($Dashed) { 'dashed=1;dashPattern=8 6;' } else { '' }
  $cell = $Document.CreateElement('mxCell')
  $cell.SetAttribute('id', $Id)
  $cell.SetAttribute('value', $Value)
  $cell.SetAttribute('style', "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;endArrow=block;endFill=1;strokeWidth=2;strokeColor=$Color;fontSize=11;labelBackgroundColor=#FFFFFF;$dash")
  $cell.SetAttribute('edge', '1')
  $cell.SetAttribute('parent', '1')
  $cell.SetAttribute('source', $Source)
  $cell.SetAttribute('target', $Target)
  $geometry = $Document.CreateElement('mxGeometry')
  $geometry.SetAttribute('relative', '1')
  $geometry.SetAttribute('as', 'geometry')
  [void]$cell.AppendChild($geometry)
  [void]$Document.mxfile.diagram.mxGraphModel.root.AppendChild($cell)
}

function Add-OciIcon {
  param([xml]$Document, [string]$Title, [string]$Prefix, [double]$X, [double]$Y)
  $source = Decode-OciStencil $Title
  $cells = @($source.mxGraphModel.root.mxCell | Where-Object { $_.id -notin @('0', '1') })
  foreach ($cell in $cells) {
    $cell.id = "$Prefix$($cell.id)"
  }
  foreach ($cell in $cells) {
    if ($cell.parent -eq '1') { $cell.parent = '1' }
    elseif ($cell.parent) { $cell.parent = "$Prefix$($cell.parent)" }
    if ($cell.source) { $cell.source = "$Prefix$($cell.source)" }
    if ($cell.target) { $cell.target = "$Prefix$($cell.target)" }
  }
  $topCells = @($cells | Where-Object { $_.parent -eq '1' })
  $top = $topCells | Select-Object -First 1
  foreach ($topCell in $topCells) {
    $originalX = if ($topCell.mxGeometry.x) { [double]$topCell.mxGeometry.x } else { 0 }
    $originalY = if ($topCell.mxGeometry.y) { [double]$topCell.mxGeometry.y } else { 0 }
    $topCell.mxGeometry.SetAttribute('x', [string]($X + $originalX))
    $topCell.mxGeometry.SetAttribute('y', [string]($Y + $originalY))
  }
  foreach ($cell in $cells) {
    [void]$Document.mxfile.diagram.mxGraphModel.root.AppendChild($Document.ImportNode($cell, $true))
  }
  "$Prefix$($top.id -replace "^$Prefix", '')"
}

function Save-Diagram([xml]$Document, [string]$FileName) {
  $settings = New-Object Xml.XmlWriterSettings
  $settings.Indent = $true
  $settings.Encoding = New-Object Text.UTF8Encoding($false)
  $path = Join-Path $outputDirectory $FileName
  $writer = [Xml.XmlWriter]::Create($path, $settings)
  try { $Document.Save($writer) } finally { $writer.Dispose() }
}

$titleStyle = 'text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;fontFamily=Oracle Sans;fontSize=28;fontStyle=1;fontColor=#161513;'
$subtitleStyle = 'text;html=1;strokeColor=none;fillColor=none;align=left;verticalAlign=middle;whiteSpace=wrap;fontFamily=Oracle Sans;fontSize=13;fontColor=#5B5B5B;'
$boundaryStyle = 'rounded=1;whiteSpace=wrap;html=1;verticalAlign=top;align=left;spacingTop=12;spacingLeft=14;fontFamily=Oracle Sans;fontSize=16;fontStyle=1;fillColor=none;strokeWidth=2;'
$boxStyle = 'rounded=1;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontFamily=Oracle Sans;fontSize=13;fillColor=#FFFFFF;strokeColor=#9E9892;strokeWidth=1;'
$futureStyle = 'rounded=1;whiteSpace=wrap;html=1;align=center;verticalAlign=middle;fontFamily=Oracle Sans;fontSize=13;fillColor=#F7F6F3;strokeColor=#C74634;strokeWidth=2;dashed=1;dashPattern=8 6;'
$noteStyle = 'rounded=1;whiteSpace=wrap;html=1;align=left;verticalAlign=middle;spacing=10;fontFamily=Oracle Sans;fontSize=12;fillColor=#F7F6F3;strokeColor=#D6D2CD;'

# OCI deployment topology
$d = New-Diagram 'OCI private deployment topology' 1900 1200
Add-Vertex $d 'd-title' 'Private OCI FOCUS FinOps ETL platform' $titleStyle 40 25 1200 42 | Out-Null
Add-Vertex $d 'd-subtitle' 'Deployment topology - private compute and Autonomous Database - OCI Bastion administration - future Oracle Analytics Cloud' $subtitleStyle 42 66 1350 34 | Out-Null
Add-Vertex $d 'd-controller' '<b>Linux controller</b><br><font style="font-size:11px">Terraform + Ansible<br/>restricted public CIDR</font>' $boxStyle 40 250 210 100 | Out-Null
Add-Vertex $d 'd-github' '<b>GitHub</b><br><font style="font-size:11px">eugsim1/focus-loader-report-upload</font>' $boxStyle 40 460 210 82 | Out-Null
Add-Vertex $d 'd-internet' '<b>Oracle/YUM/Go endpoints</b><br><font style="font-size:11px">outbound package downloads only</font>' $boxStyle 40 700 210 82 | Out-Null
Add-Vertex $d 'd-region' 'OCI Region' ($boundaryStyle + 'strokeColor=#C74634;fontColor=#C74634;') 300 125 1540 1010 | Out-Null
Add-Vertex $d 'd-vcn' 'Virtual Cloud Network (VCN)' ($boundaryStyle + 'strokeColor=#2D5967;fontColor=#2D5967;') 470 235 1100 700 | Out-Null
Add-Vertex $d 'd-subnet' 'Private subnet - no public IPs' ($boundaryStyle + 'strokeColor=#6F7780;fontColor=#161513;dashed=1;dashPattern=6 4;') 565 345 865 480 | Out-Null

$bastion = Add-OciIcon $d 'Identity and Security - Bastion' 'dbas-' 350 330
$vm = Add-OciIcon $d 'Compute - Virtual Machine VM' 'dvm-' 650 430
$adb = Add-OciIcon $d 'Database - Autonomous DB' 'dadb-' 1050 435
$dbpe = Add-OciIcon $d 'Developer Services - Private Endpoint IP' 'dpe-' 1285 450
$nat = Add-OciIcon $d 'Networking - NAT Gateway' 'dnat-' 600 675
$service = Add-OciIcon $d 'Networking - Service Gateway' 'dsg-' 830 690
$storage = Add-OciIcon $d 'Storage - Object Storage' 'dos-' 1630 250
$vault = Add-OciIcon $d 'Identity and Security - Vault' 'dvault-' 1460 600
$oac = Add-OciIcon $d 'Analytics and AI' 'doac-' 1640 860

Add-Vertex $d 'd-vm-label' '<b>Oracle Linux 8 utility host</b><br><font style="font-size:11px">Go multi-worker ETL - SQL*Loader - OCI CLI<br/>oracle user - IMDSv2 only</font>' $noteStyle 590 575 270 82 | Out-Null
Add-Vertex $d 'd-adb-label' '<b>Autonomous Database</b><br><font style="font-size:11px">private endpoint - FOCUS data mart<br/>TCP 1522 TLS/mTLS</font>' $noteStyle 990 575 250 82 | Out-Null
Add-Vertex $d 'd-pe-label' '<b>Database Tools private endpoint</b><br><font style="font-size:11px">private connection metadata</font>' $noteStyle 1240 585 175 66 | Out-Null
Add-Vertex $d 'd-oac-label' '<b>Oracle Analytics Cloud</b><br><font style="font-size:11px">future private access channel<br/>semantic model + dashboards</font>' $futureStyle 1580 970 215 88 | Out-Null
Add-Vertex $d 'd-legend' '<b>Legend</b><br/>Solid = implemented by this project<br/>Dashed red = future integration<br/>All data-plane connections remain private' $noteStyle 330 960 310 105 | Out-Null
Add-Vertex $d 'd-attribution' 'Icons: Oracle Cloud Infrastructure Architecture Diagram Toolkit - Architecture is indicative; verify service limits and security controls for each tenancy.' $subtitleStyle 330 1085 1200 30 | Out-Null

Add-Edge $d 'de1' 'd-controller' $bastion 'managed SSH session' $false '#C74634'
Add-Edge $d 'de2' $bastion $vm 'SSH through Bastion plugin' $false '#C74634'
Add-Edge $d 'de3' $vm $nat '' $false '#2D5967'
Add-Edge $d 'de4' $nat 'd-github' 'git clone' $false '#2D5967'
Add-Edge $d 'de5' $nat 'd-internet' 'package downloads' $false '#2D5967'
Add-Edge $d 'de6' $vm $service 'OCI APIs' $false '#2D5967'
Add-Edge $d 'de7' $service $storage 'FOCUS CSV.GZ objects' $false '#2D5967'
Add-Edge $d 'de8' $vm $adb 'SQL*Loader / SQL*Net 1522' $false '#C74634'
Add-Edge $d 'de9' $dbpe $adb 'private DB connection' $false '#2D5967'
Add-Edge $d 'de10' $vault $dbpe 'credential secret' $false '#2D5967'
Add-Edge $d 'de11' $adb $oac 'future private analytics' $true '#C74634'
Save-Diagram $d 'oci-focus-private-finops.drawio'

# Solution Design Architecture (SDA)
$s = New-Diagram 'Solution Design Architecture (SDA)' 1900 1250
Add-Vertex $s 's-title' 'Solution Design Architecture (SDA)' $titleStyle 40 25 1050 42 | Out-Null
Add-Vertex $s 's-subtitle' 'Logical layers, responsibilities, trust boundaries, and the FOCUS data path' $subtitleStyle 42 66 1050 34 | Out-Null
$layerStyle = $boundaryStyle + 'strokeColor=#D6D2CD;fontColor=#161513;fillColor=#FFFFFF;'
Add-Vertex $s 's-consumers' '1 - Consumers and outcomes' $layerStyle 40 125 1490 125 | Out-Null
Add-Vertex $s 's-experience' '2 - Analytics and experience' $layerStyle 40 270 1490 145 | Out-Null
Add-Vertex $s 's-data' '3 - Data products and persistence' $layerStyle 40 435 1490 170 | Out-Null
Add-Vertex $s 's-app' '4 - Application and integration' $layerStyle 40 625 1490 190 | Out-Null
Add-Vertex $s 's-platform' '5 - OCI platform and network' $layerStyle 40 835 1490 190 | Out-Null
Add-Vertex $s 's-delivery' '6 - Delivery and operations' $layerStyle 40 1045 1490 145 | Out-Null
Add-Vertex $s 's-security' '<b>Cross-cutting security controls</b><br/><br/>- Private IPs only<br/>- NSG least-privilege rules<br/>- OCI Bastion time-limited sessions<br/>- IMDSv2-only compute metadata<br/>- IAM policies and OCI profiles<br/>- Vault/KMS-protected credentials<br/>- Wallet TLS/mTLS<br/>- Sanitized reports and secret-safe logs' ($boundaryStyle + 'strokeColor=#C74634;fontColor=#C74634;fillColor=#FCEDEA;') 1560 125 290 900 | Out-Null

Add-Vertex $s 's-finops' '<b>FinOps analysts</b><br/><font style="font-size:11px">cost visibility and allocation</font>' $boxStyle 220 165 220 58 | Out-Null
Add-Vertex $s 's-platform-user' '<b>Platform operator</b><br/><font style="font-size:11px">repeatable secure deployment</font>' $boxStyle 800 165 220 58 | Out-Null
$sOac = Add-OciIcon $s 'Analytics and AI' 'soac-' 300 285
Add-Vertex $s 's-oac-text' '<b>Oracle Analytics Cloud (future)</b><br/><font style="font-size:11px">private access channel - semantic model<br/>configurable cost-management dashboards</font>' $futureStyle 455 302 330 82 | Out-Null
Add-Vertex $s 's-query' '<b>SQL and reusable views</b><br/><font style="font-size:11px">immediate analysis before OAC phase</font>' $boxStyle 970 307 260 70 | Out-Null
$sStorage = Add-OciIcon $s 'Storage - Object Storage' 'sos-' 190 480
$sAdb = Add-OciIcon $s 'Database - Autonomous DB' 'sadb-' 685 480
Add-Vertex $s 's-source-text' '<b>FOCUS report source</b><br/><font style="font-size:11px">CSV.GZ objects and tag metadata</font>' $noteStyle 325 507 230 62 | Out-Null
Add-Vertex $s 's-adb-text' '<b>Private Autonomous Database</b><br/><font style="font-size:11px">FOCUS schema - load audit - checkpoints<br/>statistics and report history</font>' $noteStyle 830 500 300 76 | Out-Null
$sVm = Add-OciIcon $s 'Compute - Virtual Machine VM' 'svm-' 190 655
Add-Vertex $s 's-etl' '<b>Go multi-worker ETL</b><br/><font style="font-size:11px">download - decompress - enrich tags<br/>preload checks - worker coordination</font>' $boxStyle 380 674 250 92 | Out-Null
Add-Vertex $s 's-loader' '<b>SQL*Loader deployment</b><br/><font style="font-size:11px">schema bootstrap - bulk load<br/>audit and safe result files</font>' $boxStyle 720 674 250 92 | Out-Null
Add-Vertex $s 's-runtime' '<b>Runtime tooling</b><br/><font style="font-size:11px">Oracle Instant Client - Python - OCI CLI<br/>Go - Git - wallet/TNS_ADMIN</font>' $boxStyle 1060 674 300 92 | Out-Null
$sBastion = Add-OciIcon $s 'Identity and Security - Bastion' 'sbas-' 120 875
$sNat = Add-OciIcon $s 'Networking - NAT Gateway' 'snat-' 390 860
$sSg = Add-OciIcon $s 'Networking - Service Gateway' 'ssg-' 650 870
$sVault = Add-OciIcon $s 'Identity and Security - Vault' 'svault-' 910 875
$sPe = Add-OciIcon $s 'Developer Services - Private Endpoint IP' 'spe-' 1180 875
Add-Vertex $s 's-platform-label' '<font style="font-size:11px">VCN + private subnet - Bastion - controlled egress - Oracle Services Network - Vault/KMS - Database Tools private endpoint</font>' $subtitleStyle 170 995 1190 25 | Out-Null
Add-Vertex $s 's-tf' '<b>Terraform modules</b><br/><font style="font-size:11px">network - compute - ADB - Bastion - Database Tools - report</font>' $boxStyle 150 1080 350 75 | Out-Null
Add-Vertex $s 's-ansible' '<b>Ansible roles</b><br/><font style="font-size:11px">OS/runtime - OCI config - wallet - ETL - verification</font>' $boxStyle 600 1080 350 75 | Out-Null
Add-Vertex $s 's-git' '<b>GitHub source control</b><br/><font style="font-size:11px">infrastructure project + ETL project</font>' $boxStyle 1050 1080 300 75 | Out-Null
Add-Vertex $s 's-scope' '<b>Scope legend</b><br/>Solid = current solution<br/>Dashed red = planned OAC phase' $noteStyle 1570 1050 270 105 | Out-Null
Add-Vertex $s 's-attribution' 'Icons: Oracle Cloud Infrastructure Architecture Diagram Toolkit - SDA = Solution Design Architecture.' $subtitleStyle 45 1200 900 25 | Out-Null

Add-Edge $s 'se1' 's-finops' $sOac 'dashboards' $true '#C74634'
Add-Edge $s 'se2' $sAdb 's-query' 'SQL' $false '#2D5967'
Add-Edge $s 'se3' $sAdb $sOac 'future private query' $true '#C74634'
Add-Edge $s 'se4' $sStorage 's-etl' 'CSV.GZ' $false '#2D5967'
Add-Edge $s 'se5' 's-etl' 's-loader' 'enriched load files' $false '#2D5967'
Add-Edge $s 'se6' 's-loader' $sAdb 'bulk load + audit' $false '#C74634'
Add-Edge $s 'se7' 's-tf' 's-platform' 'provision' $false '#2D5967'
Add-Edge $s 'se8' 's-ansible' $sVm 'configure' $false '#2D5967'
Add-Edge $s 'se9' 's-git' 's-etl' 'versioned source' $false '#2D5967'
Save-Diagram $s 'oci-focus-private-finops-sda.drawio'

Write-Output "Generated diagrams in $outputDirectory"
