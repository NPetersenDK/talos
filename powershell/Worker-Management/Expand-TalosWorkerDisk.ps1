#Requires -Modules VCF.PowerCLI, powershell-yaml
<#
.SYNOPSIS
    Grows the VMDK of each Talos worker to a target size, one node at a time,
    rebooting so Talos expands the EPHEMERAL (/var) partition and Longhorn picks
    up the extra capacity.

.DESCRIPTION
    For each worker (processed strictly one at a time):
      1. Verifies the cluster + Longhorn are healthy before touching the node.
      2. Grows the VM's first disk to -TargetDiskGB (online, thin — grow only).
      3. Cordons + drains the node (best-effort), then reboots it via talosctl.
         Talos auto-grows EPHEMERAL on boot; the Longhorn replica data on that
         partition is preserved (filesystem grow, no data loss).
      4. Waits for the node to return Ready, uncordons it, and waits for all
         Longhorn volumes to return to healthy before moving to the next worker.

    Processing one node at a time keeps 2 healthy Longhorn replicas available
    throughout, so volumes stay up (degraded only during the brief reboot).

.PARAMETER ConfigsPath
    Path to your configs folder (the one containing environment.yaml).

.PARAMETER TargetDiskGB
    Desired worker disk size in GB. Default 200. Workers already at or above
    this size are skipped (VMDK can only grow, never shrink).

.PARAMETER Node
    Optional. Only process this single worker hostname (e.g. talos-worker-2).

.PARAMETER SkipDrain
    Skip the kubectl drain step and just cordon + reboot. Faster, slightly less
    graceful (pods are killed by the reboot rather than evicted first).

.EXAMPLE
    .\Expand-TalosWorkerDisk.ps1 -ConfigsPath "C:\path\to\configs"

.EXAMPLE
    .\Expand-TalosWorkerDisk.ps1 -ConfigsPath "C:\path\to\configs" -Node talos-worker-2
#>
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath,

    [int]$TargetDiskGB = 200,

    [string]$Node,

    [switch]$SkipDrain,

    # Max time to wait for all Longhorn volumes to return healthy after a reboot.
    # A hot volume (e.g. a Prometheus TSDB) can take a while to rebuild its
    # replica, so this is generous by default.
    [int]$VolumeHealthyTimeoutSec = 5400
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
if (Test-Path $ConfigsPath -PathType Leaf) {
    $ConfigsPath = Split-Path $ConfigsPath -Parent
}
$config = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

Write-TalosBanner "Expand Talos Worker Disks -> ${TargetDiskGB} GB"

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

function Get-LonghornNodeMaxGB {
    param([string]$Name)
    $ln = Invoke-Kubectl @('get', 'nodes.longhorn.io', $Name, '-n', 'longhorn-system', '-o', 'json')
    if (-not $ln) { return $null }
    $max = 0
    foreach ($d in $ln.status.diskStatus.PSObject.Properties) {
        $max += [int64]$d.Value.storageMaximum
    }
    return [math]::Round($max / 1GB, 1)
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
Write-TalosStep 3 "Selecting workers to expand"

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
    $disk = Get-HardDisk -VM $vm | Select-Object -First 1
    $curGB = [math]::Round($disk.CapacityGB, 0)
    if ($curGB -ge $TargetDiskGB) {
        Write-TalosSuccess "$($w.hostname): already ${curGB} GB — skipping"
        continue
    }
    Write-TalosInfo "$($w.hostname): ${curGB} GB -> ${TargetDiskGB} GB"
    $plan += [pscustomobject]@{ Node = $w; VM = $vm; CurrentGB = $curGB }
}

if ($plan.Count -eq 0) {
    Write-TalosSummary "Nothing to do" @("All selected workers are already >= ${TargetDiskGB} GB.")
    return
}

# ─── Process one worker at a time ────────────────────────────────────────────
$done = @()
foreach ($item in $plan) {
    $w    = $item.Node
    $vm   = $item.VM
    $name = $w.hostname
    $ip   = $w.ip

    Write-TalosStep 4 "Expanding $name ($ip): $($item.CurrentGB) GB -> ${TargetDiskGB} GB"

    # Gate: cluster + storage healthy before we disturb anything.
    Assert-StorageHealthy -Context "before $name"
    $beforeGB = Get-LonghornNodeMaxGB -Name $name
    Write-TalosInfo "Longhorn capacity on $name before: ${beforeGB} GB"

    # 1. Grow the VMDK (online, grow-only).
    $disk = Get-HardDisk -VM $vm | Select-Object -First 1
    Set-HardDisk -HardDisk $disk -CapacityGB $TargetDiskGB -Confirm:$false | Out-Null
    Write-TalosSuccess "VMDK grown to ${TargetDiskGB} GB"

    # 2. Cordon (+ best-effort drain).
    & kubectl cordon $name | Out-Null
    Write-TalosInfo "Cordoned $name"
    if (-not $SkipDrain) {
        Write-TalosInfo "Draining $name (best-effort)..."
        & kubectl drain $name --ignore-daemonsets --delete-emptydir-data --force --timeout=300s 2>&1 |
            ForEach-Object { Write-TalosInfo $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-TalosWarn "Drain did not fully complete (PodDisruptionBudgets?) — proceeding with reboot anyway"
        } else {
            Write-TalosSuccess "Drained $name"
        }
    }

    # 3. Reboot so Talos grows EPHEMERAL on boot.
    Write-TalosInfo "Rebooting $name via talosctl..."
    & talosctl reboot --talosconfig $talosConfig --endpoints $ip --nodes $ip --wait --timeout 15m 2>&1 |
        ForEach-Object { Write-TalosInfo $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-TalosWarn "talosctl reboot --wait returned non-zero — falling back to polling node readiness"
    }

    # 4. Wait for the node to be Ready, then uncordon.
    Wait-Until -Activity "$name to become Ready" -TimeoutSec 900 -Condition { Test-NodeReady -Name $name }
    Write-TalosSuccess "$name is Ready"
    & kubectl uncordon $name | Out-Null
    Write-TalosInfo "Uncordoned $name"

    # 5. Confirm capacity grew and wait for Longhorn to return fully healthy.
    Wait-Until -Activity "Longhorn capacity on $name to grow" -TimeoutSec 600 -Condition {
        $now = Get-LonghornNodeMaxGB -Name $name
        $now -and (-not $beforeGB -or $now -gt $beforeGB)
    }
    $afterGB = Get-LonghornNodeMaxGB -Name $name
    Write-TalosSuccess "Longhorn capacity on $name now: ${afterGB} GB (was ${beforeGB} GB)"

    Write-TalosInfo "Waiting for all Longhorn volumes to return healthy (rebuilds can be slow)..."
    Wait-Until -Activity "Longhorn volumes to return healthy" -TimeoutSec $VolumeHealthyTimeoutSec -Condition {
        (Get-UnhealthyVolumes).Count -eq 0
    } -Detail { Get-RebuildSummary }
    Write-TalosSuccess "$name done — all volumes healthy"
    $done += "$name : $($item.CurrentGB) GB -> ${afterGB} GB"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summary = @("Expanded workers:")
$summary += $done | ForEach-Object { "  $_" }
$summary += ""
$summary += "Remember to set worker.diskGB: ${TargetDiskGB} in environment.yaml"
$summary += "so future (re)deploys match the new size."
Write-TalosSummary "Worker Disks Expanded" $summary
