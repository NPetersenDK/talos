#Requires -Modules powershell-yaml
<#
.SYNOPSIS
    Removes one node (control plane or worker) and deletes its VM (VMware or Proxmox).

.DESCRIPTION
    Worker: Longhorn eviction, drain, talosctl reset, delete node, delete VM.
    Control plane: refuses to leave fewer than 3 etcd members, then drain, graceful reset
    (leaves etcd), delete node, delete VM.
    Add and verify the replacement first. Remove the node from environment.yaml afterwards.

.PARAMETER KeepVM
    Leave the VM in the hypervisor.

.PARAMETER Force
    Allow a control plane removal that leaves fewer than 3 etcd members.

.EXAMPLE
    .\Remove-TalosNode.ps1 -EnvironmentFile "C:\configs\environment.yaml" -Hostname talos-worker-3
#>
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentFile,

    [Parameter(Mandatory)]
    [string]$Hostname,

    [switch]$KeepVM,
    [switch]$Force
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

Write-TalosBanner "Remove Talos Node"

$tc = (Resolve-Path (Join-Path $ConfigsPath $config.talos.talosConfigPath)).Path
$kc = (Resolve-Path (Join-Path $ConfigsPath $config.talos.kubeconfigPath)).Path

function Invoke-Talos { & talosctl --talosconfig $tc @args }
function Invoke-Kube  { & kubectl --kubeconfig $kc @args }

# ─── Locate the node ─────────────────────────────────────────────────────────
$cpNodes = @($config.cluster.controlplane.nodes)
$wNodes  = @($config.cluster.worker.nodes)
$node    = $cpNodes + $wNodes | Where-Object { $_.hostname -eq $Hostname } | Select-Object -First 1
if (-not $node) { Write-Error "Node '$Hostname' not found in environment.yaml"; exit 1 }

$isCp      = [bool]($cpNodes | Where-Object { $_.hostname -eq $Hostname })
$isProxmox = $config.proxmox -and ($config.proxmox.locations.Keys -contains $node.location)
$otherCps  = @($cpNodes | Where-Object { $_.hostname -ne $Hostname })
if ($otherCps.Count -eq 0) { Write-Error "Cannot remove the only control plane"; exit 1 }
$viaIp = $otherCps[0].ip   # talosctl endpoint that is NOT the node being removed

Write-TalosInfo "Node:       $Hostname ($($node.ip))"
Write-TalosInfo "Role:       $(if ($isCp) { 'control plane' } else { 'worker' })"
Write-TalosInfo "Hypervisor: $(if ($isProxmox) { 'Proxmox' } else { 'VMware' }) (location $($node.location))"

# ─── Step 1: Safety checks ───────────────────────────────────────────────────
Write-TalosStep 1 "Safety checks"

Invoke-Kube get nodes | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "kubectl cannot reach the cluster (kubeconfig: $kc)"; exit 1 }

$inK8s = $true
Invoke-Kube get node $Hostname 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $inK8s = $false; Write-TalosWarn "$Hostname is not registered in Kubernetes - drain/delete will be skipped" }

if ($isCp) {
    $members = @(Invoke-Talos -e $viaIp -n $viaIp etcd members | Select-Object -Skip 1 | Where-Object { $_.Trim() })
    Write-TalosInfo "etcd members: $($members.Count)"
    if (($members -join "`n") -notmatch [regex]::Escape($Hostname)) {
        Write-TalosWarn "$Hostname is not an etcd member (already removed?)"
    }
    elseif ($members.Count - 1 -lt 3 -and -not $Force) {
        Write-Error "Removing $Hostname would leave $($members.Count - 1) etcd members (< 3). Add the replacement control plane first, or use -Force."
        exit 1
    }
}
else {
    $notReady = @(Invoke-Kube get nodes --no-headers | Where-Object { $_ -notmatch '\sReady\s' -and $_ -notmatch "^$Hostname\s" })
    if ($notReady.Count -gt 0) {
        Write-TalosWarn "Other nodes are not Ready:"
        $notReady | ForEach-Object { Write-TalosWarn "  $_" }
    }
}

Write-Host ""
Write-TalosWarn "This will drain, reset and DELETE the VM of $Hostname"
$typed = Read-Host "Type the hostname ($Hostname) to confirm"
if ($typed -ne $Hostname) { Write-TalosWarn "Not confirmed - aborting"; exit 1 }

# ─── Step 2: Longhorn evacuation (workers) ───────────────────────────────────
if (-not $isCp -and $inK8s) {
    Write-TalosStep 2 "Evacuating Longhorn replicas"

    Invoke-Kube get namespace longhorn-system 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-TalosInfo "No longhorn-system namespace - skipping"
    }
    else {
        $patchFile = [System.IO.Path]::GetTempFileName()
        '{"spec":{"allowScheduling":false,"evictionRequested":true}}' | Set-Content -Path $patchFile -Encoding UTF8
        Invoke-Kube -n longhorn-system patch nodes.longhorn.io $Hostname --type merge --patch-file $patchFile | Out-Null
        Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -ne 0) { Write-Error "Could not request Longhorn eviction for $Hostname"; exit 1 }

        $deadline = (Get-Date).AddMinutes(90)
        while ($true) {
            $json = (Invoke-Kube -n longhorn-system get replicas.longhorn.io -o json) -join "`n"
            $left = @(($json | ConvertFrom-Json).items | Where-Object { $_.spec.nodeID -eq $Hostname }).Count
            if ($left -eq 0) { break }
            if ((Get-Date) -gt $deadline) { Write-Error "Timed out waiting for Longhorn to move $left replica(s) off $Hostname"; exit 1 }
            Write-TalosInfo "$left replica(s) still on $Hostname..."
            Start-Sleep -Seconds 30
        }
        Write-TalosSuccess "No Longhorn replicas left on $Hostname"
    }
}

# ─── Step 3: Drain ───────────────────────────────────────────────────────────
Write-TalosStep 3 "Draining $Hostname"
if ($inK8s) {
    Invoke-Kube drain $Hostname --ignore-daemonsets --delete-emptydir-data --timeout=15m
    if ($LASTEXITCODE -ne 0) { Write-Error "Drain failed - nothing has been reset yet"; exit 1 }
    Write-TalosSuccess "Drained"
}

# ─── Step 4: Reset (leaves etcd on control planes) ───────────────────────────
Write-TalosStep 4 "Resetting Talos on $Hostname"
Invoke-Talos -e $viaIp -n $node.ip reset --graceful=true
if ($LASTEXITCODE -ne 0) { Write-Error "talosctl reset failed"; exit 1 }
Write-TalosSuccess "Node reset"

# ─── Step 5: Remove from Kubernetes ──────────────────────────────────────────
Write-TalosStep 5 "Removing node from Kubernetes"
Invoke-Kube delete node $Hostname --ignore-not-found | Out-Null

if ($isCp) {
    $members = @(Invoke-Talos -e $viaIp -n $viaIp etcd members)
    if (($members -join "`n") -match [regex]::Escape($Hostname)) {
        Write-TalosWarn "$Hostname still listed as etcd member - remove manually: talosctl etcd remove-member <ID>"
    }
    else {
        Write-TalosSuccess "$Hostname no longer an etcd member ($(@($members | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count) left)"
    }

    $remaining = @($otherCps | ForEach-Object { $_.ip })
    Invoke-Talos config endpoint $remaining 2>&1 | Out-Null
    Invoke-Talos config node $remaining 2>&1 | Out-Null
    Write-TalosInfo "talosconfig endpoints now: $($remaining -join ', ')"
}
Write-TalosSuccess "Node object deleted"

# ─── Step 6: Delete the VM ───────────────────────────────────────────────────
Write-TalosStep 6 "Deleting VM"
if ($KeepVM) {
    Write-TalosInfo "-KeepVM set - VM left in place"
}
elseif ($isProxmox) {
    $px      = $config.proxmox
    $sshUser = $px.sshUser ?? 'root'
    $snippetsPath = $px.snippetsPath ?? '/var/lib/vz/snippets'
    $pveHost = $px.locations.($node.location).host

    $json = Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "pvesh get /cluster/resources --type vm --output-format json"
    $vm = (($json -join "`n") | ConvertFrom-Json) | Where-Object { $_.name -eq $Hostname } | Select-Object -First 1
    if (-not $vm) {
        Write-TalosWarn "No VM named $Hostname found on Proxmox"
    }
    else {
        Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm stop $($vm.vmid)" -AllowFailure | Out-Null
        Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm destroy $($vm.vmid) --purge --destroy-unreferenced-disks 1" | Out-Null
        Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "rm -f '$snippetsPath/talos-$Hostname.yaml'" | Out-Null
        Write-TalosSuccess "Proxmox VM $($vm.vmid) ($Hostname) destroyed"
    }
}
else {
    Connect-TalosVCenter -Server $config.vcenter.server | Out-Null
    $vm = Get-VM -Name $Hostname -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-TalosWarn "No VM named $Hostname found in vCenter"
    }
    else {
        if ($vm.PowerState -eq 'PoweredOn') { Stop-VM -VM $vm -Confirm:$false | Out-Null }
        Remove-VM -VM $vm -DeletePermanently -Confirm:$false
        Write-TalosSuccess "VMware VM $Hostname deleted"
    }
}

Write-TalosSummary "Node Removed" @(
    "$Hostname ($($node.ip)) removed from the cluster.",
    "",
    "Now remove it from environment.yaml (cluster.$(if ($isCp) { 'controlplane' } else { 'worker' }).nodes)."
)
