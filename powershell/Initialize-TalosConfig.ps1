#Requires -Modules powershell-yaml
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath,

    [switch]$Force
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
if (Test-Path $ConfigsPath -PathType Leaf) {
    $ConfigsPath = Split-Path $ConfigsPath -Parent
}
$config = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

Write-TalosBanner "Initialize Talos Config"

# ─── Validate prerequisites ──────────────────────────────────────────────────
Write-TalosStep 1 "Checking prerequisites"

$talosctl = Get-Command talosctl -ErrorAction SilentlyContinue
if (-not $talosctl) {
    Write-Error "talosctl not found in PATH. Install it from https://www.talos.dev/latest/introduction/getting-started/"
    exit 1
}
Write-TalosSuccess "talosctl found: $($talosctl.Source)"

# ─── Prepare output directory ────────────────────────────────────────────────
Write-TalosStep 2 "Preparing output directory"

$outputDir = Join-Path $ConfigsPath "talosfiles"

if (Test-Path $outputDir) {
    $existing = Get-ChildItem $outputDir -File
    if ($existing -and -not $Force) {
        Write-TalosWarn "talosfiles/ already contains files:"
        $existing | ForEach-Object { Write-TalosInfo $_.Name }
        Write-Host ""
        Write-Error "Use -Force to overwrite existing configs"
        exit 1
    }
    if ($existing -and $Force) {
        Write-TalosWarn "Overwriting existing configs (-Force)"
    }
} else {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}
Write-TalosSuccess "Output: $outputDir"

# ─── Build and run talosctl gen config ────────────────────────────────────────
Write-TalosStep 3 "Generating machine configs"

$clusterName   = $config.cluster.name
$endpoint      = "https://$($config.talos.vip):6443"
$installImage  = $config.schematic.vmwareInstallerImage

Write-TalosInfo "Cluster:       $clusterName"
Write-TalosInfo "Endpoint:      $endpoint"
Write-TalosInfo "Install image: $installImage"

$genArgs = @(
    "gen", "config",
    $clusterName,
    $endpoint,
    "--install-image", $installImage,
    "--output-dir", $outputDir
)

if ($Force) {
    $genArgs += "--force"
}

$output = & talosctl @genArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "talosctl gen config failed: $output"
    exit 1
}
Write-TalosSuccess "Machine configs generated"

# ─── Show generated files ────────────────────────────────────────────────────
Write-TalosStep 4 "Verifying output"

$expectedFiles = @("controlplane.yaml", "worker.yaml", "talosconfig")
foreach ($file in $expectedFiles) {
    $filePath = Join-Path $outputDir $file
    if (Test-Path $filePath) {
        $size = (Get-Item $filePath).Length
        Write-TalosSuccess "$file ($([math]::Round($size / 1KB, 1)) KB)"
    } else {
        Write-TalosWarn "$file not found"
    }
}

# ─── Generate per-node machine configs ────────────────────────────────────────
Write-TalosStep 5 "Generating per-node machine configs"

$machineDir    = Join-Path $outputDir "machineconfigs"
$cpConfigPath  = Join-Path $outputDir "controlplane.yaml"
$wkConfigPath  = Join-Path $outputDir "worker.yaml"
$net           = $config.cluster.network
$nameservers   = @($net.nameservers)

if (-not (Test-Path $machineDir)) {
    New-Item -ItemType Directory -Path $machineDir | Out-Null
}

foreach ($node in $config.cluster.controlplane.nodes) {
    $outFile = Join-Path $machineDir "$($node.hostname).yaml"
    New-TalosNodeConfig `
        -BaseConfigPath $cpConfigPath `
        -Hostname $node.hostname `
        -IP $node.ip `
        -SubnetPrefix $net.subnetPrefix `
        -Gateway $net.gateway `
        -Nameservers $nameservers `
        -VIP $config.talos.vip `
        -OutputPath $outFile | Out-Null
    Write-TalosSuccess "$($node.hostname).yaml (controlplane)"
}

foreach ($node in $config.cluster.worker.nodes) {
    $outFile = Join-Path $machineDir "$($node.hostname).yaml"
    New-TalosNodeConfig `
        -BaseConfigPath $wkConfigPath `
        -Hostname $node.hostname `
        -IP $node.ip `
        -SubnetPrefix $net.subnetPrefix `
        -Gateway $net.gateway `
        -Nameservers $nameservers `
        -OutputPath $outFile | Out-Null
    Write-TalosSuccess "$($node.hostname).yaml (worker)"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-TalosSummary "Config Generated" @(
    "Cluster:  $clusterName",
    "Endpoint: $endpoint",
    "Version:  $($config.schematic.version)",
    "",
    "Files written to:",
    "  $outputDir",
    "",
    "Next steps:",
    "  1. Upload-TalosOva.ps1    (import OVA)",
    "  2. Deploy-TalosCluster.ps1 (create VMs)",
    "  3. Bootstrap-TalosCluster.ps1 (bootstrap)"
)
