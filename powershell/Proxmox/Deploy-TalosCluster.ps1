#Requires -Modules powershell-yaml, Posh-SSH
param(
    # Path to your environment yaml file (e.g. C:\configs\environment.yaml).
    # Machine configs are read from talosfiles/ next to it.
    [Parameter(Mandatory)]
    [string]$EnvironmentFile
)

Import-Module (Join-Path $PSScriptRoot ".." "TalosHelper") -Force

if (-not (Test-Path $EnvironmentFile -PathType Leaf)) {
    Write-Error "Environment file not found: $EnvironmentFile`nPoint -EnvironmentFile directly at your environment yaml file"
    exit 1
}
$EnvironmentFile = (Resolve-Path $EnvironmentFile).Path
$ConfigsPath = Split-Path $EnvironmentFile -Parent
$config = Get-TalosEnvironment -Path $EnvironmentFile

Write-TalosBanner "Deploy Talos Cluster (Proxmox)"

$px = $config.proxmox
if (-not $px) {
    Write-Error "No 'proxmox' section found in environment.yaml"
    exit 1
}
$sshUser         = $px.sshUser ?? 'root'
$imageDir        = $px.imagePath ?? '/var/lib/vz/template/talos'
$snippetsStorage = $px.snippetsStorage ?? 'local'
$snippetsPath    = $px.snippetsPath ?? '/var/lib/vz/snippets'
$imageFile       = $config.schematic.nocloudImageFile

# ─── Helper functions ────────────────────────────────────────────────────────

$locationCache = @{}

function Get-ProxmoxLocation {
    param([string]$Key)
    if (-not $locationCache.ContainsKey($Key)) {
        $loc = $px.locations.$Key
        if (-not $loc) { throw "Unknown location key: '$Key'" }
        $locationCache[$Key] = @{
            Host    = $loc.host
            Storage = $loc.storage
            Bridge  = $loc.bridge
            Vlan    = $loc.vlan
            Mtu     = $loc.mtu
        }
    }
    return $locationCache[$Key]
}

function Deploy-TalosVM {
    param(
        [string]$VMName,
        [string]$ConfigPath,
        [int]$Cores,
        [int]$MemoryGB,
        [int]$DiskGB,
        # One Proxmox disk created per entry, in order (matches /dev/sdb, /dev/sdc, ...
        # as assigned by New-TalosNodeConfig from the same storage.datadisks list:
        # scsi0 = /dev/sda, scsi1 = /dev/sdb, ...).
        [int[]]$DataDisksGB = @(),
        [hashtable]$Location,
        [int]$Vmid
    )

    $pveHost = $Location.Host
    $storage = $Location.Storage

    if (-not $Vmid) {
        $Vmid = [int](Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "pvesh get /cluster/nextid")
    }

    Write-TalosInfo "Uploading machine config snippet"
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "mkdir -p '$snippetsPath'" | Out-Null
    Copy-ProxmoxFile -SshHost $pveHost -User $sshUser -LocalPath $ConfigPath -RemotePath "$snippetsPath/talos-$VMName.yaml"

    $net0 = "virtio,bridge=$($Location.Bridge)"
    if ($Location.Vlan) { $net0 += ",tag=$($Location.Vlan)" }
    if ($Location.Mtu)  { $net0 += ",mtu=$($Location.Mtu)" }

    Write-TalosInfo "Creating VM $Vmid`: $Cores vCPU, ${MemoryGB} GB RAM"
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm create $Vmid --name '$VMName' --machine q35 --bios ovmf --ostype l26 --cpu host --sockets 1 --cores $Cores --memory $($MemoryGB * 1024) --balloon 0 --scsihw virtio-scsi-pci --net0 '$net0' --agent enabled=1 --serial0 socket" | Out-Null

    # Secure boot disabled (pre-enrolled-keys=0): factory nocloud images are not
    # Microsoft-signed.
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm set $Vmid --efidisk0 '${storage}:1,efitype=4m,pre-enrolled-keys=0'" | Out-Null

    Write-TalosInfo "Importing OS disk from $imageDir/$imageFile"
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm set $Vmid --scsi0 '${storage}:0,import-from=$imageDir/$imageFile,discard=on'" | Out-Null

    # diskGB only grows the imported image; resize fails if target <= current.
    if ($DiskGB -gt 0) {
        Write-TalosInfo "Resizing OS disk to ${DiskGB} GB"
        Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm disk resize $Vmid scsi0 ${DiskGB}G" -AllowFailure | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-TalosWarn "diskGB (${DiskGB}) not larger than the image OS disk - keeping image size"
        }
    }

    # serial=dataN makes each disk identifiable from inside the guest
    # (/dev/disk/by-id/*dataN*) if slot/name mapping ever needs verifying.
    $i = 1
    foreach ($size in $DataDisksGB) {
        if ($size -gt 0) {
            Write-TalosInfo "Adding data disk scsi${i}: ${size} GB"
            Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm set $Vmid --scsi$i '${storage}:${size},discard=on,serial=data$i'" | Out-Null
            $i++
        }
    }

    Write-TalosInfo "Attaching cloud-init drive with machine config (nocloud user-data)"
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm set $Vmid --ide2 '${storage}:cloudinit' --cicustom 'user=${snippetsStorage}:snippets/talos-$VMName.yaml'" | Out-Null

    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm set $Vmid --boot order=scsi0" | Out-Null

    Write-TalosInfo "Powering on $VMName (VMID $Vmid)"
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "qm start $Vmid" | Out-Null

    return $Vmid
}

# ─── Validate configs ────────────────────────────────────────────────────────
Write-TalosStep 1 "Validating machine configs"

$machineDir = Join-Path $ConfigsPath "talosfiles" "machineconfigs"
if (-not (Test-Path $machineDir)) {
    Write-Error "Machine configs not found: $machineDir`nRun Initialize-TalosConfig.ps1 first"
    exit 1
}

$allNodes = @(
    $config.cluster.controlplane.nodes
    $config.cluster.worker.nodes
)
foreach ($node in $allNodes) {
    $nodeCfg = Join-Path $machineDir "$($node.hostname).yaml"
    if (-not (Test-Path $nodeCfg)) {
        Write-Error "Missing config: $nodeCfg`nRun Initialize-TalosConfig.ps1 first"
        exit 1
    }
    Write-TalosSuccess "$($node.hostname).yaml"
}

# ─── Pre-flight check ────────────────────────────────────────────────────────
Write-TalosStep 2 "Pre-flight check"

$hosts = @($allNodes | ForEach-Object { (Get-ProxmoxLocation -Key $_.location).Host } | Sort-Object -Unique)

foreach ($pveHost in $hosts) {
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "test -f '$imageDir/$imageFile'" -AllowFailure | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Talos image not found on ${pveHost}: $imageDir/$imageFile`nRun Prepare-TalosImage.ps1 first"
        exit 1
    }
    Write-TalosSuccess "Image present on $pveHost"
}

$allHostnames = @($allNodes | ForEach-Object { $_.hostname })
$existingNames = @()
foreach ($pveHost in $hosts) {
    $json = Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "pvesh get /cluster/resources --type vm --output-format json"
    $existingNames += ($json -join "`n" | ConvertFrom-Json) | ForEach-Object { $_.name }
}
$existing = $allHostnames | Where-Object { $existingNames -contains $_ }
if ($existing) {
    Write-Error "The following VMs already exist — remove them before redeploying:`n  $($existing -join "`n  ")"
    exit 1
}
Write-TalosSuccess "No conflicting VMs found"

$createdVMs = @()

# ─── Deploy control plane ────────────────────────────────────────────────────
Write-TalosStep 3 "Deploying control plane nodes"

$cp = $config.cluster.controlplane
foreach ($node in $cp.nodes) {
    $vmName     = $node.hostname
    $loc        = Get-ProxmoxLocation -Key $node.location
    $nodeConfig = Join-Path $machineDir "$($node.hostname).yaml"

    Write-Host ""
    Write-TalosInfo "$vmName  ip=$($node.ip)  location=$($node.location)"

    $vmid = Deploy-TalosVM -VMName $vmName -ConfigPath $nodeConfig -Cores $cp.cpu -MemoryGB $cp.memoryGB -DiskGB $cp.diskGB -Location $loc -Vmid ([int]($node.vmid ?? 0))

    Write-TalosSuccess "$vmName deployed (VMID $vmid)"
    $createdVMs += "$vmName ($($node.ip), VMID $vmid)"
}

# ─── Deploy workers ──────────────────────────────────────────────────────────
Write-TalosStep 4 "Deploying worker nodes"

$w = $config.cluster.worker
foreach ($node in $w.nodes) {
    $vmName     = $node.hostname
    $loc        = Get-ProxmoxLocation -Key $node.location
    $nodeConfig = Join-Path $machineDir "$($node.hostname).yaml"

    Write-Host ""
    Write-TalosInfo "$vmName  ip=$($node.ip)  location=$($node.location)"

    # Prefer storage.datadisks (one disk per entry, in order); fall back to
    # legacy single dataDiskGB for older environment.yaml files.
    $dataDisksGB = @()
    if ($w.storage -and $w.storage.datadisks) {
        $dataDisksGB = @($w.storage.datadisks | ForEach-Object { [int]$_.sizeGB })
    } elseif ($w.dataDiskGB) {
        $dataDisksGB = @([int]$w.dataDiskGB)
    }

    $vmid = Deploy-TalosVM -VMName $vmName -ConfigPath $nodeConfig -Cores $w.cpu -MemoryGB $w.memoryGB -DiskGB $w.diskGB -DataDisksGB $dataDisksGB -Location $loc -Vmid ([int]($node.vmid ?? 0))

    Write-TalosSuccess "$vmName deployed (VMID $vmid)"
    $createdVMs += "$vmName ($($node.ip), VMID $vmid)"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summaryLines = @("VMs created and powered on:")
$summaryLines += $createdVMs | ForEach-Object { "  $_" }
$summaryLines += ""
$summaryLines += "Next: Bootstrap-TalosCluster.ps1"

Write-TalosSummary "Cluster Deployed" $summaryLines
