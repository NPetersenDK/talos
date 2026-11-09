#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Applies each node's machine config (IP bound to its MAC) to running nodes, without reboot.

.DESCRIPTION
    Per node, stopping at the first problem: take node.mac from environment.yaml (or read it from
    the node and write it there), generate the config, then dry-run `apply-config`. With -Apply it
    applies with --mode no-reboot and waits for the node on its IP and for Kubernetes Ready.
    The whole machine config is replaced: manual patches show up in the dry run and are lost.

.PARAMETER Nodes
    Only these hostnames. Default: all.

.PARAMETER Address
    Reach the node here instead of its configured IP (e.g. after a DHCP fallback). One node only.

.PARAMETER Apply
    Apply. Without it: dry run only.

.EXAMPLE
    .\Apply-TalosConfig.ps1 -EnvironmentFile ..\talos-configs\environment.yaml -Nodes talos-worker-04 -Address 10.0.16.31 -Apply
#>
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentFile,

    [string[]]$Nodes = @(),
    [string]$Address,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

if (-not (Test-Path $EnvironmentFile -PathType Leaf)) {
    Write-Error "Environment file not found: $EnvironmentFile"
    exit 1
}
$EnvironmentFile = (Resolve-Path $EnvironmentFile).Path
$ConfigsPath = Split-Path $EnvironmentFile -Parent
$config = Get-TalosEnvironment -Path $EnvironmentFile

Write-TalosBanner "Apply Talos Config$(if (-not $Apply) { ' (dry run)' })"

$tc = (Resolve-Path (Join-Path $ConfigsPath $config.talos.talosConfigPath)).Path
$kcPath = Join-Path $ConfigsPath $config.talos.kubeconfigPath

$ordered = @($config.cluster.controlplane.nodes | ForEach-Object { [pscustomobject]@{ Node = $_; Role = 'controlplane' } }) +
           @($config.cluster.worker.nodes       | ForEach-Object { [pscustomobject]@{ Node = $_; Role = 'worker' } })
if ($Nodes.Count -gt 0) {
    $unknown = $Nodes | Where-Object { $_ -notin @($ordered | ForEach-Object { $_.Node.hostname }) }
    if ($unknown) { Write-Error "Not found in environment.yaml: $($unknown -join ', ')"; exit 1 }
    $ordered = @($ordered | Where-Object { $Nodes -contains $_.Node.hostname })
}
if ($Address -and $ordered.Count -ne 1) {
    Write-Error "-Address can only be used with exactly one node (use -Nodes)"
    exit 1
}

$done = @()
foreach ($t in $ordered) {
    $node = $t.Node
    $addr = if ($Address) { $Address } else { $node.ip }

    Write-TalosStep ($done.Count + 1) "$($node.hostname) ($($t.Role)) via $addr"

    # ── 1. MAC ──────────────────────────────────────────────────────────────
    try { $live = Get-TalosNodeMacLive -TalosConfig $tc -Address $addr }
    catch {
        if (-not $node.mac) { throw }
        Write-TalosWarn "Could not read the NIC from the node ($($_.Exception.Message)); using mac from environment.yaml"
        $live = $node.mac.ToLower()
    }
    Write-TalosInfo "NIC on the node: $live"
    $writeMac = $false
    if ($node.mac) {
        if ($node.mac.ToLower() -ne $live) {
            throw "$($node.hostname): environment.yaml says mac $($node.mac) but the node's NIC is $live. Nothing was changed. Fix environment.yaml if the NIC was replaced."
        }
    }
    else {
        $node['mac'] = $live
        $writeMac = $true
        Write-TalosInfo "environment.yaml has no mac for $($node.hostname); using $live$(if (-not $Apply) { ' (not written in a dry run)' })"
    }

    # ── 2. Config ───────────────────────────────────────────────────────────
    $cfgFile = New-TalosNodeConfigFromEnvironment -Config $config -Node $node -Role $t.Role -ConfigsPath $ConfigsPath
    Write-TalosSuccess "Generated $cfgFile"

    # ── 3. Dry run or apply ─────────────────────────────────────────────────
    if (-not $Apply) {
        & talosctl --talosconfig $tc -e $addr -n $addr apply-config --file $cfgFile --dry-run
        if ($LASTEXITCODE -ne 0) { throw "apply-config --dry-run failed for $($node.hostname)" }
        $done += $node.hostname
        continue
    }

    if ($writeMac) {
        Set-TalosNodeMac -Path $EnvironmentFile -Hostname $node.hostname -Mac $live
        Write-TalosSuccess "mac $live written to environment.yaml"
    }

    & talosctl --talosconfig $tc -e $addr -n $addr apply-config --file $cfgFile --mode no-reboot
    if ($LASTEXITCODE -ne 0) {
        throw "apply-config failed for $($node.hostname) (it never reboots here: --mode no-reboot). Stopping before the next node."
    }

    # The node may move to its configured IP.
    Write-TalosInfo "Waiting for $($node.hostname) on $($node.ip):50000"
    $deadline = (Get-Date).AddMinutes(3)
    while (-not (Test-Connection -TargetName $node.ip -TcpPort 50000 -TimeoutSeconds 3 -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $deadline) { throw "$($node.hostname) did not come up on $($node.ip) within 3 minutes. Stopping before the next node." }
        Start-Sleep -Seconds 5
    }
    Write-TalosSuccess "$($node.hostname) answers on $($node.ip)"

    if ((Get-Command kubectl -ErrorAction SilentlyContinue) -and (Test-Path $kcPath)) {
        & kubectl --kubeconfig $kcPath wait --for=condition=Ready "node/$($node.hostname)" --timeout=3m
        if ($LASTEXITCODE -ne 0) { throw "$($node.hostname) is not Ready in Kubernetes. Stopping before the next node." }
    }
    $done += $node.hostname
}

Write-TalosSummary $(if ($Apply) { "Config Applied" } else { "Dry Run Done" }) @(
    "Nodes: $($done -join ', ')",
    "",
    $(if ($Apply) { "Nodes now match environment.yaml. Safe to upgrade." } else { "Nothing was changed. Run again with -Apply to apply." })
)
