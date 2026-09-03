#Requires -Modules powershell-yaml, Posh-SSH
<#
.SYNOPSIS
    Stops and destroys all cluster VMs defined in the environment file, including
    their disks and cloud-init snippets. Use before a clean redeploy.

.PARAMETER EnvironmentFile
    Path to your environment yaml file (e.g. C:\configs\environment.yaml).

.PARAMETER Force
    Skip the interactive confirmation prompt.

.EXAMPLE
    .\Remove-TalosCluster.ps1 -EnvironmentFile "C:\path\to\configs\environment.yaml"
#>
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentFile,

    [switch]$Force
)

Import-Module (Join-Path $PSScriptRoot ".." "TalosHelper") -Force

if (-not (Test-Path $EnvironmentFile -PathType Leaf)) {
    Write-Error "Environment file not found: $EnvironmentFile`nPoint -EnvironmentFile directly at your environment yaml file"
    exit 1
}
$EnvironmentFile = (Resolve-Path $EnvironmentFile).Path
$config = Get-TalosEnvironment -Path $EnvironmentFile

Write-TalosBanner "Remove Talos Cluster (Proxmox)"

$px = $config.proxmox
if (-not $px) {
    Write-Error "No 'proxmox' section found in environment.yaml"
    exit 1
}
$sshUser      = $px.sshUser ?? 'root'
$snippetsPath = $px.snippetsPath ?? '/var/lib/vz/snippets'

$clusterNodes = @(
    $config.cluster.controlplane.nodes
    $config.cluster.worker.nodes
)
$allHostnames = @($clusterNodes | ForEach-Object { $_.hostname })
$hosts = @($clusterNodes | ForEach-Object { $px.locations.($_.location).host } | Sort-Object -Unique)

# ─── Find the VMs ────────────────────────────────────────────────────────────
Write-TalosStep 1 "Finding cluster VMs"

$targets = @()
foreach ($pveHost in $hosts) {
    $json = Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "pvesh get /cluster/resources --type vm --output-format json"
    $vms = ($json -join "`n") | ConvertFrom-Json
    foreach ($vm in $vms) {
        if ($allHostnames -contains $vm.name -and -not ($targets | Where-Object { $_.Vmid -eq $vm.vmid })) {
            $targets += [pscustomobject]@{
                Name    = $vm.name
                Vmid    = $vm.vmid
                Node    = $vm.node
                Status  = $vm.status
                SshHost = $pveHost
            }
        }
    }
}

if ($targets.Count -eq 0) {
    Write-TalosSummary "Nothing to remove" @("No VMs matching the environment file's hostnames were found.")
    return
}

foreach ($t in $targets) {
    Write-TalosInfo "$($t.Name)  vmid=$($t.Vmid)  node=$($t.Node)  status=$($t.Status)"
}

$missing = $allHostnames | Where-Object { $_ -notin $targets.Name }
foreach ($m in $missing) {
    Write-TalosWarn "$m not found — skipping"
}

# ─── Confirm ─────────────────────────────────────────────────────────────────
if (-not $Force) {
    Write-Host ""
    Write-Host "This PERMANENTLY DESTROYS the $($targets.Count) VMs listed above, including ALL their disks (Longhorn data, hostpath data, everything)." -ForegroundColor Yellow
    $answer = Read-Host "Type the cluster name '$($config.cluster.name)' to confirm"
    if ($answer -ne $config.cluster.name) {
        Write-TalosWarn "Aborted — nothing was removed."
        exit 1
    }
}

# ─── Stop and destroy ────────────────────────────────────────────────────────
Write-TalosStep 2 "Stopping and destroying VMs"

$removed = @()
foreach ($t in $targets) {
    if ($t.Status -eq 'running') {
        Write-TalosInfo "Stopping $($t.Name) (VMID $($t.Vmid))"
        Invoke-ProxmoxSsh -SshHost $t.SshHost -User $sshUser -Command "pvesh create /nodes/$($t.Node)/qemu/$($t.Vmid)/status/stop" -AllowFailure | Out-Null

        $elapsed = 0
        while ($elapsed -lt 120) {
            $status = (Invoke-ProxmoxSsh -SshHost $t.SshHost -User $sshUser -Command "pvesh get /nodes/$($t.Node)/qemu/$($t.Vmid)/status/current --output-format json" | Out-String | ConvertFrom-Json).status
            if ($status -eq 'stopped') { break }
            Start-Sleep -Seconds 5
            $elapsed += 5
        }
    }

    Write-TalosInfo "Destroying $($t.Name) (VMID $($t.Vmid)) incl. disks"
    Invoke-ProxmoxSsh -SshHost $t.SshHost -User $sshUser -Command "pvesh delete /nodes/$($t.Node)/qemu/$($t.Vmid) --purge 1 --destroy-unreferenced-disks 1" | Out-Null

    Invoke-ProxmoxSsh -SshHost $t.SshHost -User $sshUser -Command "rm -f '$snippetsPath/talos-$($t.Name).yaml'" -AllowFailure | Out-Null

    Write-TalosSuccess "$($t.Name) destroyed"
    $removed += "$($t.Name) (VMID $($t.Vmid))"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summaryLines = @("VMs destroyed:")
$summaryLines += $removed | ForEach-Object { "  $_" }
$summaryLines += ""
$summaryLines += "Redeploy: Deploy-TalosCluster.ps1, then Bootstrap-TalosCluster.ps1"

Write-TalosSummary "Cluster Removed" $summaryLines
