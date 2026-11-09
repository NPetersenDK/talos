#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Rolling upgrade to the installer image from schematic.id + schematic.version in
    environment.yaml. Control planes first, one node at a time: drain, upgrade, Ready, uncordon,
    then etcd (control plane) or Longhorn (worker) healthy before the next.

.PARAMETER Nodes
    Only these hostnames. Default: all.

.EXAMPLE
    .\Upgrade-TalosNodes.ps1 -EnvironmentFile "C:\configs\environment.yaml" -Nodes talos-cp-1,talos-worker-1
#>
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentFile,

    [string[]]$Nodes = @(),

    # Skip the NIC-by-name check.
    [switch]$SkipNetworkCheck
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

if (-not (Test-Path $EnvironmentFile -PathType Leaf)) {
    Write-Error "Environment file not found: $EnvironmentFile`nPoint -EnvironmentFile directly at your environment yaml file"
    exit 1
}
$EnvironmentFile = (Resolve-Path $EnvironmentFile).Path
$ConfigsPath = Split-Path $EnvironmentFile -Parent
$config = Get-TalosEnvironment -Path $EnvironmentFile

Write-TalosBanner "Upgrade Talos Nodes"

$tc = (Resolve-Path (Join-Path $ConfigsPath $config.talos.talosConfigPath)).Path
$kc = (Resolve-Path (Join-Path $ConfigsPath $config.talos.kubeconfigPath)).Path

function Invoke-Talos { & talosctl --talosconfig $tc @args }
function Invoke-Kube  { & kubectl --kubeconfig $kc @args }

$cpNodes = @($config.cluster.controlplane.nodes)
$wNodes  = @($config.cluster.worker.nodes)
$ordered = @($cpNodes | ForEach-Object { [pscustomobject]@{ Node = $_; IsCp = $true } }) +
           @($wNodes  | ForEach-Object { [pscustomobject]@{ Node = $_; IsCp = $false } })
if ($Nodes.Count -gt 0) {
    $unknown = $Nodes | Where-Object { $_ -notin @($ordered | ForEach-Object { $_.Node.hostname }) }
    if ($unknown) { Write-Error "Not found in environment.yaml: $($unknown -join ', ')"; exit 1 }
    $ordered = @($ordered | Where-Object { $Nodes -contains $_.Node.hostname })
}

# ─── Plan ────────────────────────────────────────────────────────────────────
Write-TalosStep 1 "Upgrade plan"
foreach ($t in $ordered) {
    Write-TalosInfo ("{0,-18} {1,-14} {2}" -f $t.Node.hostname, $t.Node.ip, (Get-TalosInstallerImage -Config $config -Node $t.Node))
}
Write-Host ""
if ((Read-Host "Upgrade these $($ordered.Count) node(s), one at a time? [y/N]") -notmatch '^(y|yes|j|ja)$') { exit 0 }

function Wait-LonghornHealthy {
    Invoke-Kube get namespace longhorn-system 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return }
    $deadline = (Get-Date).AddMinutes(60)
    while ($true) {
        $json = (Invoke-Kube -n longhorn-system get volumes.longhorn.io -o json) -join "`n"
        $bad = @(($json | ConvertFrom-Json).items | Where-Object { $_.status.state -eq 'attached' -and $_.status.robustness -ne 'healthy' })
        if ($bad.Count -eq 0) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for Longhorn volumes to become healthy ($($bad.Count) not healthy)" }
        Write-TalosInfo "Waiting for $($bad.Count) Longhorn volume(s) to be healthy..."
        Start-Sleep -Seconds 30
    }
}

# ─── Upgrade loop ────────────────────────────────────────────────────────────
Write-TalosStep 2 "Upgrading"

$done = @()
foreach ($t in $ordered) {
    $node  = $t.Node
    $image = Get-TalosInstallerImage -Config $config -Node $node
    $via   = (@($cpNodes | Where-Object { $_.hostname -ne $node.hostname }))[0].ip

    Write-Host ""
    Write-TalosInfo "$($node.hostname) ($($node.ip)) -> $image"

    # Guard: a config bound to the NIC name (eth0) loses its IP when the upgrade renames the NIC.
    # Refuse until Apply-TalosConfig.ps1 has bound it to the MAC.
    if (-not $SkipNetworkCheck) {
        $live = (& talosctl --talosconfig $tc -e $via -n $node.ip get machineconfig -o yaml 2>&1) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "Could not read the live config of $($node.hostname): $live" }
        if ($live -match '(?ms)^\s*interfaces:\s*\n\s*-\s+interface:\s*\S+') {
            throw "$($node.hostname) selects its NIC by name in the live machine config. Upgrading would rename the NIC and drop its IP. Run Apply-TalosConfig.ps1 -Nodes $($node.hostname) -Apply first (or -SkipNetworkCheck if you know better)."
        }
    }

    if (-not $t.IsCp) { Wait-LonghornHealthy }

    Invoke-Kube drain $node.hostname --ignore-daemonsets --delete-emptydir-data --timeout=15m
    if ($LASTEXITCODE -ne 0) { throw "Drain of $($node.hostname) failed - stopping (nothing upgraded on this node)" }

    Invoke-Talos -e $via -n $node.ip upgrade --image $image
    if ($LASTEXITCODE -ne 0) { throw "talosctl upgrade failed on $($node.hostname) - node is still cordoned, investigate before continuing" }

    # Keep machine config in sync so later reinstalls/upgrades use the same image
    $patchFile = [System.IO.Path]::GetTempFileName()
    (@(@{ op = 'replace'; path = '/machine/install/image'; value = $image }) | ConvertTo-Json -AsArray -Compress) | Set-Content -Path $patchFile -Encoding UTF8
    Invoke-Talos -e $via -n $node.ip patch machineconfig --mode=no-reboot --patch "@$patchFile" | Out-Null
    Remove-Item $patchFile -Force -ErrorAction SilentlyContinue

    Invoke-Kube wait --for=condition=Ready "node/$($node.hostname)" --timeout=10m
    if ($LASTEXITCODE -ne 0) { throw "$($node.hostname) did not become Ready - node is still cordoned" }
    Invoke-Kube uncordon $node.hostname | Out-Null

    if ($t.IsCp) {
        $members = @(Invoke-Talos -e $via -n $via etcd members | Select-Object -Skip 1 | Where-Object { $_.Trim() })
        if ($members.Count -ne $cpNodes.Count) { Write-TalosWarn "etcd has $($members.Count) members, expected $($cpNodes.Count)" }
    }
    else {
        Wait-LonghornHealthy
    }

    Write-TalosSuccess "$($node.hostname) upgraded"
    $done += $node.hostname
}

Write-TalosSummary "Upgrade Complete" @(
    "Upgraded: $($done -join ', ')",
    "Image:    schematic $($config.schematic.id)",
    "Version:  $($config.schematic.version)"
)
