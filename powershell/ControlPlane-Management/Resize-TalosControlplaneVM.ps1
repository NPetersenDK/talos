#Requires -Modules VCF.PowerCLI, powershell-yaml
<#
.SYNOPSIS
    Resizes vCPU/RAM of each Talos control plane node to a target size, one
    node at a time, via a graceful shutdown -> resize -> power on cycle.

.DESCRIPTION
    For each control plane node (processed strictly one at a time):
      1. Verifies overall cluster health (etcd quorum, kubelet, apid) via
         `talosctl health` before touching the node.
      2. Cordons + drains the node (best-effort — control plane nodes are
         normally tainted NoSchedule, so this is mostly a no-op safety net).
      3. Gracefully shuts the node down via talosctl, routed through the
         *other* control plane nodes (not the one going down), falling back
         to a hard VM power-off if it doesn't shut down in time.
      4. Sets the VM's vCPU count and/or RAM (offline — CPU/mem hot-add is
         not enabled on these VMs, so the change requires a power cycle).
      5. Powers the VM back on, waits for the node to return Ready, uncordons
         it, and waits for `talosctl health` to pass again before moving to
         the next node.

    Processing one control plane node at a time keeps etcd quorum (2 of 3)
    intact throughout. Never run this against more than one node at once.

.PARAMETER ConfigsPath
    Path to your configs folder (the one containing environment.yaml).

.PARAMETER TargetCpu
    Desired vCPU count. Defaults to cluster.controlplane.cpu from
    environment.yaml. Override to resize without editing the config first.

.PARAMETER TargetMemoryGB
    Desired RAM in GB. Defaults to cluster.controlplane.memoryGB from
    environment.yaml. Override to resize without editing the config first.

.PARAMETER Node
    Optional. Only process this single control plane hostname (e.g.
    talos-cp-2).

.PARAMETER SkipDrain
    Skip the kubectl drain step and just cordon + shut down.

.PARAMETER ShutdownTimeoutSec
    Max time to wait for the node to power off gracefully via talosctl before
    falling back to a hard VM power-off. Default 300.

.PARAMETER ClusterHealthTimeoutSec
    Max time `talosctl health` will wait/retry for the cluster to report
    healthy, both before and after each node. Default 1200 (20 min).

.EXAMPLE
    .\Resize-TalosControlplaneVM.ps1 -ConfigsPath "C:\path\to\configs"

.EXAMPLE
    .\Resize-TalosControlplaneVM.ps1 -ConfigsPath "C:\path\to\configs" -TargetCpu 8 -Node talos-cp-2
#>
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath,

    [int]$TargetCpu = 0,

    [int]$TargetMemoryGB = 0,

    [string]$Node,

    [switch]$SkipDrain,

    [int]$ShutdownTimeoutSec = 300,

    [int]$ClusterHealthTimeoutSec = 1200
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
if (Test-Path $ConfigsPath -PathType Leaf) {
    $ConfigsPath = Split-Path $ConfigsPath -Parent
}
$config = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

# Target defaults to what's in environment.yaml; -TargetCpu/-TargetMemoryGB
# let you override without editing the config first.
if ($TargetCpu -le 0) { $TargetCpu = [int]$config.cluster.controlplane.cpu }
if ($TargetMemoryGB -le 0) { $TargetMemoryGB = [int]$config.cluster.controlplane.memoryGB }

Write-TalosBanner "Resize Talos Control Plane -> ${TargetCpu} vCPU, ${TargetMemoryGB} GB RAM"

# ─── Prerequisites ───────────────────────────────────────────────────────────
Write-TalosStep 1 "Checking prerequisites"

foreach ($tool in @('talosctl', 'kubectl')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool not found in PATH."
        exit 1
    }
}

$talosConfig = Resolve-Path (Join-Path $ConfigsPath $config.talos.talosConfigPath)
$kubeconfig  = Join-Path $ConfigsPath $config.talos.kubeconfigPath
if (-not (Test-Path $kubeconfig)) {
    Write-Error "kubeconfig not found: $kubeconfig"
    exit 1
}
$env:KUBECONFIG = (Resolve-Path $kubeconfig).Path
Write-TalosSuccess "talosctl + kubectl found; KUBECONFIG set"

$allCPIPs     = @($config.cluster.controlplane.nodes | ForEach-Object { $_.ip })
$allWorkerIPs = @($config.cluster.worker.nodes | ForEach-Object { $_.ip })

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Invoke-Kubectl {
    # Runs kubectl and returns parsed JSON ($null on failure).
    param([string[]]$KubectlArgs)
    $raw = & kubectl @KubectlArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Test-NodeReady {
    param([string]$Name)
    $n = Invoke-Kubectl @('get', 'node', $Name, '-o', 'json')
    if (-not $n) { return $false }
    $ready = $n.status.conditions | Where-Object { $_.type -eq 'Ready' }
    return ($ready -and $ready.status -eq 'True')
}

function Wait-Until {
    # Polls $Condition (scriptblock returning bool) until true or timeout.
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSec = 1800,
        [int]$IntervalSec = 15,
        [string]$Activity = "condition"
    )
    $elapsed = 0
    while (-not (& $Condition)) {
        if ($elapsed -ge $TimeoutSec) {
            throw "Timed out after ${TimeoutSec}s waiting for $Activity"
        }
        if ($elapsed % 60 -eq 0 -and $elapsed -gt 0) {
            Write-TalosInfo "Still waiting for $Activity... (${elapsed}s)"
        }
        Start-Sleep -Seconds $IntervalSec
        $elapsed += $IntervalSec
    }
}

function Assert-ClusterHealthy {
    # Gate on etcd quorum / apid / kubelet health across the whole cluster.
    # Fails closed: any error (unreachable endpoint, non-zero exit) aborts.
    param([string]$Context, [string]$Endpoint)
    Write-TalosInfo "Checking cluster health ($Context)..."
    & talosctl health --talosconfig $talosConfig `
        --endpoints $Endpoint `
        --nodes $Endpoint `
        --control-plane-nodes ($allCPIPs -join ',') `
        --worker-nodes ($allWorkerIPs -join ',') `
        --wait-timeout "${ClusterHealthTimeoutSec}s" 2>&1 |
        ForEach-Object { Write-TalosInfo $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "Aborting — cluster health check failed ($Context)."
    }
    Write-TalosSuccess "Cluster healthy ($Context)"
}

# ─── Connect to vCenter ──────────────────────────────────────────────────────
Write-TalosStep 2 "Connecting to vCenter"
Connect-TalosVCenter -Server $config.vcenter.server | Out-Null
Write-TalosSuccess "Connected to $($config.vcenter.server)"

# ─── Select control plane nodes ──────────────────────────────────────────────
Write-TalosStep 3 "Selecting control plane nodes to resize"

$nodes = @($config.cluster.controlplane.nodes)
if ($Node) {
    $nodes = @($nodes | Where-Object { $_.hostname -eq $Node })
    if ($nodes.Count -eq 0) {
        Write-Error "Control plane node '$Node' not found in environment.yaml"
        exit 1
    }
}

$plan = @()
foreach ($cp in $nodes) {
    $vm = Get-VM -Name $cp.hostname -ErrorAction SilentlyContinue
    if (-not $vm) { Write-TalosWarn "$($cp.hostname): VM not found — skipping"; continue }
    $curCpu = $vm.NumCpu
    $curMemGB = [math]::Round($vm.MemoryGB, 0)
    if ($TargetCpu -eq $curCpu -and $TargetMemoryGB -eq $curMemGB) {
        Write-TalosSuccess "$($cp.hostname): already ${curCpu} vCPU / ${curMemGB} GB — skipping"
        continue
    }
    Write-TalosInfo "$($cp.hostname): ${curCpu} vCPU / ${curMemGB} GB -> ${TargetCpu} vCPU / ${TargetMemoryGB} GB"
    $plan += [pscustomobject]@{ Node = $cp; VM = $vm; CurrentCpu = $curCpu; CurrentMemGB = $curMemGB }
}

if ($plan.Count -eq 0) {
    Write-TalosSummary "Nothing to do" @("All selected control plane nodes already match the target vCPU/RAM.")
    return
}

if ($plan.Count -gt 1) {
    Write-TalosWarn "Resizing $($plan.Count) control plane nodes — processed one at a time to keep etcd quorum intact."
}

# ─── Process one control plane node at a time ────────────────────────────────
$done = @()
foreach ($item in $plan) {
    $cp   = $item.Node
    $name = $cp.hostname
    $ip   = $cp.ip
    $otherCPIPs = @($allCPIPs | Where-Object { $_ -ne $ip })

    Write-TalosStep 4 "Resizing $name ($ip): $($item.CurrentCpu) vCPU/$($item.CurrentMemGB) GB -> ${TargetCpu} vCPU/${TargetMemoryGB} GB"

    # Gate: full cluster (etcd quorum included) healthy before we disturb anything.
    Assert-ClusterHealthy -Context "before $name" -Endpoint $otherCPIPs[0]

    # 1. Cordon (+ best-effort drain).
    & kubectl cordon $name | Out-Null
    Write-TalosInfo "Cordoned $name"
    if (-not $SkipDrain) {
        Write-TalosInfo "Draining $name (best-effort)..."
        & kubectl drain $name --ignore-daemonsets --delete-emptydir-data --force --timeout=300s 2>&1 |
            ForEach-Object { Write-TalosInfo $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-TalosWarn "Drain did not fully complete (PodDisruptionBudgets?) — proceeding anyway"
        } else {
            Write-TalosSuccess "Drained $name"
        }
    }

    # 2. Gracefully shut the node down, routed through the *other* control
    #    plane nodes so the request doesn't depend on the node going down.
    Write-TalosInfo "Shutting down $name via talosctl..."
    & talosctl shutdown --talosconfig $talosConfig --endpoints ($otherCPIPs -join ',') --nodes $ip --wait --timeout 5m 2>&1 |
        ForEach-Object { Write-TalosInfo $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-TalosWarn "talosctl shutdown --wait returned non-zero — falling back to polling VM power state"
    }

    try {
        Wait-Until -Activity "$name VM to power off" -TimeoutSec $ShutdownTimeoutSec -IntervalSec 10 -Condition {
            (Get-VM -Name $name).PowerState -eq 'PoweredOff'
        }
    } catch {
        Write-TalosWarn "$name did not power off gracefully in ${ShutdownTimeoutSec}s — forcing power-off"
        Stop-VM -VM (Get-VM -Name $name) -Confirm:$false | Out-Null
    }
    Write-TalosSuccess "$name is powered off"

    # 3. Resize vCPU/RAM (offline — hot-add is not enabled on these VMs).
    Set-VM -VM (Get-VM -Name $name) -NumCpu $TargetCpu -MemoryGB $TargetMemoryGB -Confirm:$false | Out-Null
    Write-TalosSuccess "Set $name to ${TargetCpu} vCPU / ${TargetMemoryGB} GB"

    # 4. Power back on.
    Start-VM -VM (Get-VM -Name $name) | Out-Null
    Write-TalosInfo "Powered on $name"

    # 5. Wait for the node to be Ready, then uncordon.
    Wait-Until -Activity "$name to become Ready" -TimeoutSec 900 -Condition { Test-NodeReady -Name $name }
    Write-TalosSuccess "$name is Ready"
    & kubectl uncordon $name | Out-Null
    Write-TalosInfo "Uncordoned $name"

    # 6. Confirm etcd has rejoined quorum and the whole cluster is healthy
    #    again before moving to the next control plane node.
    Assert-ClusterHealthy -Context "after $name" -Endpoint $ip

    $actual = Get-VM -Name $name
    $done += "$name : $($item.CurrentCpu) vCPU/$($item.CurrentMemGB) GB -> $($actual.NumCpu) vCPU/$([math]::Round($actual.MemoryGB,0)) GB"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summary = @("Resized control plane nodes:")
$summary += $done | ForEach-Object { "  $_" }
if ([int]$config.cluster.controlplane.cpu -ne $TargetCpu -or [int]$config.cluster.controlplane.memoryGB -ne $TargetMemoryGB) {
    $summary += ""
    $summary += "Remember to set controlplane.cpu: ${TargetCpu} / controlplane.memoryGB: ${TargetMemoryGB} in environment.yaml"
    $summary += "so future (re)deploys match the new size."
}
Write-TalosSummary "Control Plane Resources Resized" $summary
