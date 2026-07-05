#Requires -Modules VCF.PowerCLI, powershell-yaml
<#
.SYNOPSIS
    Resizes vCPU/RAM of each Talos worker to a target size, one node at a time,
    via a graceful shutdown -> resize -> power on cycle.

.DESCRIPTION
    For each worker (processed strictly one at a time):
      1. Verifies the cluster + Longhorn are healthy before touching the node.
      2. Cordons + drains the node (best-effort).
      3. Gracefully shuts the node down via talosctl, falling back to a hard
         VM power-off if it doesn't shut down in time.
      4. Sets the VM's vCPU count and/or RAM (offline — CPU/mem hot-add is not
         enabled on these VMs, so the change requires a power cycle).
      5. Powers the VM back on, waits for the node to return Ready, uncordons
         it, and waits for all Longhorn volumes to return to healthy before
         moving to the next worker.

    Processing one node at a time keeps 2 healthy Longhorn replicas available
    throughout, so volumes stay up (degraded only while the node is down).

.PARAMETER ConfigsPath
    Path to your configs folder (the one containing environment.yaml).

.PARAMETER TargetCpu
    Desired vCPU count. Defaults to cluster.worker.cpu from environment.yaml.
    Override to resize without editing the config first.

.PARAMETER TargetMemoryGB
    Desired RAM in GB. Defaults to cluster.worker.memoryGB from
    environment.yaml. Override to resize without editing the config first.

.PARAMETER Node
    Optional. Only process this single worker hostname (e.g. talos-worker-2).

.PARAMETER SkipDrain
    Skip the kubectl drain step and just cordon + shut down. Faster, slightly
    less graceful (pods are killed rather than evicted first).

.PARAMETER ShutdownTimeoutSec
    Max time to wait for the node to power off gracefully via talosctl before
    falling back to a hard VM power-off. Default 300.

.EXAMPLE
    .\Resize-TalosWorkerVM.ps1 -ConfigsPath "C:\path\to\configs"

.EXAMPLE
    .\Resize-TalosWorkerVM.ps1 -ConfigsPath "C:\path\to\configs" -TargetCpu 8 -Node talos-worker-2
#>
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath,

    [int]$TargetCpu = 0,

    [int]$TargetMemoryGB = 0,

    [string]$Node,

    [switch]$SkipDrain,

    [int]$ShutdownTimeoutSec = 300,

    # Max time to wait for all Longhorn volumes to return healthy after the
    # node comes back up. A hot volume (e.g. a Prometheus TSDB) can take a
    # while to rebuild its replica, so this is generous by default.
    [int]$VolumeHealthyTimeoutSec = 5400
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot "..\TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
if (Test-Path $ConfigsPath -PathType Leaf) {
    $ConfigsPath = Split-Path $ConfigsPath -Parent
}
$config = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

# Target defaults to what's in environment.yaml; -TargetCpu/-TargetMemoryGB
# let you override without editing the config first.
if ($TargetCpu -le 0) { $TargetCpu = [int]$config.cluster.worker.cpu }
if ($TargetMemoryGB -le 0) { $TargetMemoryGB = [int]$config.cluster.worker.memoryGB }

Write-TalosBanner "Resize Talos Workers -> ${TargetCpu} vCPU, ${TargetMemoryGB} GB RAM"

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

function Get-UnhealthyVolumes {
    # Returns names of Longhorn volumes that are attached but NOT healthy,
    # or in a faulted state. Detached volumes are considered fine.
    $vols = Invoke-Kubectl @('get', 'volumes.longhorn.io', '-n', 'longhorn-system', '-o', 'json')
    if (-not $vols) { return @('<longhorn API unreachable>') }
    $bad = @()
    foreach ($v in $vols.items) {
        $state = $v.status.state
        $rob   = $v.status.robustness
        if ($rob -eq 'faulted') { $bad += "$($v.metadata.name) (faulted)" ; continue }
        if ($state -eq 'attached' -and $rob -ne 'healthy') {
            $bad += "$($v.metadata.name) ($state/$rob)"
        }
    }
    return $bad
}

function Wait-Until {
    # Polls $Condition (scriptblock returning bool) until true or timeout.
    # $Detail (optional) returns a status string appended to the waiting line.
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSec = 1800,
        [int]$IntervalSec = 15,
        [string]$Activity = "condition",
        [scriptblock]$Detail = $null
    )
    $elapsed = 0
    while (-not (& $Condition)) {
        if ($elapsed -ge $TimeoutSec) {
            throw "Timed out after ${TimeoutSec}s waiting for $Activity"
        }
        if ($elapsed % 60 -eq 0 -and $elapsed -gt 0) {
            $extra = if ($Detail) { " — $(& $Detail)" } else { "" }
            Write-TalosInfo "Still waiting for $Activity... (${elapsed}s)$extra"
        }
        Start-Sleep -Seconds $IntervalSec
        $elapsed += $IntervalSec
    }
}

function Get-RebuildSummary {
    # One-line summary of volumes that aren't healthy, with rebuild progress.
    $vols = Invoke-Kubectl @('get', 'volumes.longhorn.io', '-n', 'longhorn-system', '-o', 'json')
    if (-not $vols) { return "longhorn API unreachable" }
    $parts = @()
    foreach ($v in $vols.items) {
        if ($v.status.robustness -eq 'healthy' -or $v.status.state -eq 'detached') { continue }
        $name = $v.metadata.name
        $eng  = Invoke-Kubectl @('get', 'engines.longhorn.io', '-n', 'longhorn-system',
                                 '-l', "longhornvolume=$name", '-o', 'json')
        $pct = $null
        if ($eng -and $eng.items) {
            foreach ($rb in $eng.items[0].status.rebuildStatus.PSObject.Properties) {
                if ($rb.Value.isRebuilding) { $pct = $rb.Value.progress; break }
            }
        }
        $short = ($name -replace '^pvc-', '').Substring(0, 8)
        $parts += if ($null -ne $pct) { "$short $($v.status.robustness) ${pct}%" }
                  else                 { "$short $($v.status.robustness)" }
    }
    if ($parts.Count -eq 0) { return "all healthy" }
    return ($parts -join ", ")
}

function Assert-StorageHealthy {
    param([string]$Context)
    $bad = Get-UnhealthyVolumes
    if ($bad.Count -gt 0) {
        Write-TalosWarn "Longhorn not healthy ($Context):"
        $bad | ForEach-Object { Write-TalosInfo $_ }
        throw "Aborting — refusing to proceed while Longhorn volumes are unhealthy."
    }
}

# ─── Connect to vCenter ──────────────────────────────────────────────────────
Write-TalosStep 2 "Connecting to vCenter"
Connect-TalosVCenter -Server $config.vcenter.server | Out-Null
Write-TalosSuccess "Connected to $($config.vcenter.server)"

# ─── Select workers ──────────────────────────────────────────────────────────
Write-TalosStep 3 "Selecting workers to resize"

$workers = @($config.cluster.worker.nodes)
if ($Node) {
    $workers = @($workers | Where-Object { $_.hostname -eq $Node })
    if ($workers.Count -eq 0) {
        Write-Error "Worker '$Node' not found in environment.yaml"
        exit 1
    }
}

$plan = @()
foreach ($w in $workers) {
    $vm = Get-VM -Name $w.hostname -ErrorAction SilentlyContinue
    if (-not $vm) { Write-TalosWarn "$($w.hostname): VM not found — skipping"; continue }
    $curCpu = $vm.NumCpu
    $curMemGB = [math]::Round($vm.MemoryGB, 0)
    $wantCpu = $TargetCpu
    $wantMemGB = $TargetMemoryGB
    if ($wantCpu -eq $curCpu -and $wantMemGB -eq $curMemGB) {
        Write-TalosSuccess "$($w.hostname): already ${curCpu} vCPU / ${curMemGB} GB — skipping"
        continue
    }
    Write-TalosInfo "$($w.hostname): ${curCpu} vCPU / ${curMemGB} GB -> ${wantCpu} vCPU / ${wantMemGB} GB"
    $plan += [pscustomobject]@{ Node = $w; VM = $vm; CurrentCpu = $curCpu; CurrentMemGB = $curMemGB; WantCpu = $wantCpu; WantMemGB = $wantMemGB }
}

if ($plan.Count -eq 0) {
    Write-TalosSummary "Nothing to do" @("All selected workers already match the target vCPU/RAM.")
    return
}

# ─── Process one worker at a time ────────────────────────────────────────────
$done = @()
foreach ($item in $plan) {
    $w    = $item.Node
    $vm   = $item.VM
    $name = $w.hostname
    $ip   = $w.ip

    Write-TalosStep 4 "Resizing $name ($ip): $($item.CurrentCpu) vCPU/$($item.CurrentMemGB) GB -> $($item.WantCpu) vCPU/$($item.WantMemGB) GB"

    # Gate: cluster + storage healthy before we disturb anything.
    Assert-StorageHealthy -Context "before $name"

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

    # 2. Gracefully shut the node down so the VM powers off.
    Write-TalosInfo "Shutting down $name via talosctl..."
    & talosctl shutdown --talosconfig $talosConfig --endpoints $ip --nodes $ip --wait --timeout 5m 2>&1 |
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
    Set-VM -VM (Get-VM -Name $name) -NumCpu $item.WantCpu -MemoryGB $item.WantMemGB -Confirm:$false | Out-Null
    Write-TalosSuccess "Set $name to $($item.WantCpu) vCPU / $($item.WantMemGB) GB"

    # 4. Power back on.
    Start-VM -VM (Get-VM -Name $name) | Out-Null
    Write-TalosInfo "Powered on $name"

    # 5. Wait for the node to be Ready, then uncordon.
    Wait-Until -Activity "$name to become Ready" -TimeoutSec 900 -Condition { Test-NodeReady -Name $name }
    Write-TalosSuccess "$name is Ready"
    & kubectl uncordon $name | Out-Null
    Write-TalosInfo "Uncordoned $name"

    # 6. Wait for Longhorn to return fully healthy before moving on.
    Write-TalosInfo "Waiting for all Longhorn volumes to return healthy (rebuilds can be slow)..."
    Wait-Until -Activity "Longhorn volumes to return healthy" -TimeoutSec $VolumeHealthyTimeoutSec -Condition {
        (Get-UnhealthyVolumes).Count -eq 0
    } -Detail { Get-RebuildSummary }
    Write-TalosSuccess "$name done — all volumes healthy"

    $actual = Get-VM -Name $name
    $done += "$name : $($item.CurrentCpu) vCPU/$($item.CurrentMemGB) GB -> $($actual.NumCpu) vCPU/$([math]::Round($actual.MemoryGB,0)) GB"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summary = @("Resized workers:")
$summary += $done | ForEach-Object { "  $_" }
if ([int]$config.cluster.worker.cpu -ne $TargetCpu -or [int]$config.cluster.worker.memoryGB -ne $TargetMemoryGB) {
    $summary += ""
    $summary += "Remember to set worker.cpu: ${TargetCpu} / worker.memoryGB: ${TargetMemoryGB} in environment.yaml"
    $summary += "so future (re)deploys match the new size."
}
Write-TalosSummary "Worker Resources Resized" $summary
