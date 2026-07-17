#Requires -Modules VCF.PowerCLI, powershell-yaml
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
if (Test-Path $ConfigsPath -PathType Leaf) {
    $ConfigsPath = Split-Path $ConfigsPath -Parent
}
$config = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

Write-TalosBanner "Deploy Talos Cluster"

# ─── Connect to vCenter ──────────────────────────────────────────────────────
Write-TalosStep 1 "Connecting to vCenter"
Connect-TalosVCenter -Server $config.vcenter.server
Write-TalosSuccess "Connected to $($config.vcenter.server)"

# ─── Helper functions ────────────────────────────────────────────────────────

function Deploy-TalosVM {
    param(
        [string]$VMName,
        [string]$ConfigPath,
        [int]$NumCpu,
        [int]$MemoryGB,
        [int]$DiskGB,
        # One VMware disk created per entry, in order (matches /dev/sdb, /dev/sdc, ...
        # as assigned by New-TalosNodeConfig from the same storage.datadisks list).
        [int[]]$DataDisksGB = @(),
        [string]$PortGroup,
        $LibraryItem,
        $TargetCluster,
        $TargetDatastore,
        $TargetFolder
    )

    $configBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ConfigPath))
    $configBase64 = [Convert]::ToBase64String($configBytes)

    Write-TalosInfo "Creating VM: $VMName"
    $vm = New-VM -Name $VMName -ContentLibraryItem $LibraryItem -ResourcePool $TargetCluster -Datastore $TargetDatastore -DiskStorageFormat Thin

    Write-TalosInfo "Setting resources: $NumCpu vCPU, ${MemoryGB} GB RAM"
    Set-VM -VM $vm -NumCpu $NumCpu -MemoryGB $MemoryGB -Confirm:$false | Out-Null

    # diskGB is optional and only grows the OS disk shipped with the OVA;
    # Set-HardDisk cannot shrink, so skip when target <= current size.
    $disk = Get-HardDisk -VM $vm | Select-Object -First 1
    $currentGB = [int][math]::Ceiling($disk.CapacityGB)
    if ($DiskGB -gt $currentGB) {
        Write-TalosInfo "Growing OS disk: ${currentGB} GB -> ${DiskGB} GB"
        Set-HardDisk -HardDisk $disk -CapacityGB $DiskGB -Confirm:$false | Out-Null
    } elseif ($DiskGB -gt 0 -and $DiskGB -lt $currentGB) {
        Write-TalosWarn "diskGB (${DiskGB}) is smaller than the template OS disk (${currentGB} GB) - keeping ${currentGB} GB"
    }

    foreach ($size in $DataDisksGB) {
        if ($size -gt 0) {
            Write-TalosInfo "Adding data disk: ${size} GB"
            New-HardDisk -VM $vm -CapacityGB $size -StorageFormat Thin -Confirm:$false | Out-Null
        }
    }

    $nic = Get-NetworkAdapter -VM $vm | Select-Object -First 1
    if ($nic) {
        $vdpg = Get-VDPortgroup -Name $PortGroup -ErrorAction SilentlyContinue
        if ($vdpg) {
            Set-NetworkAdapter -NetworkAdapter $nic -Portgroup $vdpg -Confirm:$false | Out-Null
        } else {
            Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $PortGroup -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-TalosInfo "Injecting machine config via guestinfo"
    New-AdvancedSetting -Entity $vm -Name "guestinfo.talos.config" -Value $configBase64 -Force -Confirm:$false | Out-Null
    New-AdvancedSetting -Entity $vm -Name "disk.enableUUID" -Value "TRUE" -Force -Confirm:$false | Out-Null

    Write-TalosInfo "Powering on $VMName"
    Start-VM -VM $vm | Out-Null

    if ($TargetFolder) {
        Move-VM -VM $vm -InventoryLocation $TargetFolder -Confirm:$false | Out-Null
    }

    return $vm
}

# ─── Validate configs ────────────────────────────────────────────────────────
Write-TalosStep 2 "Validating machine configs"

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

# ─── Resolve vSphere resources ───────────────────────────────────────────────
Write-TalosStep 3 "Resolving vSphere resources"

$library = Get-ContentLibrary -Name $config.library.name -Local
$item    = Get-ContentLibraryItem -ContentLibrary $library -Name $config.schematic.libraryItemName
Write-TalosSuccess "Library item: $($config.schematic.libraryItemName)"

$vmFolder = $null
if ($config.vmware.folder) {
    $vmFolder = Get-Folder -Name $config.vmware.folder -Type VM -ErrorAction SilentlyContinue
    if (-not $vmFolder) {
        $rootFolder = Get-Folder -Name 'vm' -Type VM | Select-Object -First 1
        $vmFolder = New-Folder -Name $config.vmware.folder -Location $rootFolder
        Write-TalosSuccess "Created VM folder: $($config.vmware.folder)"
    } else {
        Write-TalosSuccess "VM folder: $($config.vmware.folder)"
    }
}

$createdVMs  = @()
$locationCache = @{}

function Get-ClusterLocation {
    param([string]$Key)
    if (-not $locationCache.ContainsKey($Key)) {
        $loc = $config.vmware.locations.$Key
        if (-not $loc) { throw "Unknown location key: '$Key'" }
        $locationCache[$Key] = @{
            Cluster   = Get-Cluster   -Name $loc.cluster
            Datastore = Get-Datastore -Name $loc.datastore
            PortGroup = $loc.portgroup
        }
    }
    return $locationCache[$Key]
}

# ─── Pre-flight check ────────────────────────────────────────────────────────
Write-TalosStep 4 "Pre-flight check"

$allHostnames = @(
    ($config.cluster.controlplane.nodes | ForEach-Object { $_.hostname })
    ($config.cluster.worker.nodes       | ForEach-Object { $_.hostname })
)
$existing = $allHostnames | Where-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue }
if ($existing) {
    Write-Error "The following VMs already exist — remove them before redeploying:`n  $($existing -join "`n  ")"
    exit 1
}
Write-TalosSuccess "No conflicting VMs found"

# ─── Deploy control plane ────────────────────────────────────────────────────
Write-TalosStep 5 "Deploying control plane nodes"

$cp = $config.cluster.controlplane
foreach ($node in $cp.nodes) {
    $vmName     = $node.hostname
    $loc        = Get-ClusterLocation -Key $node.location
    $nodeConfig = Join-Path $machineDir "$($node.hostname).yaml"

    Write-Host ""
    Write-TalosInfo "$vmName  ip=$($node.ip)  location=$($node.location)"

    Deploy-TalosVM -VMName $vmName -ConfigPath $nodeConfig -NumCpu $cp.cpu -MemoryGB $cp.memoryGB -DiskGB $cp.diskGB -PortGroup $loc.PortGroup -LibraryItem $item -TargetCluster $loc.Cluster -TargetDatastore $loc.Datastore -TargetFolder $vmFolder

    Write-TalosSuccess "$vmName deployed"
    $createdVMs += "$vmName ($($node.ip))"
}

# ─── Deploy workers ──────────────────────────────────────────────────────────
Write-TalosStep 6 "Deploying worker nodes"

$w = $config.cluster.worker
foreach ($node in $w.nodes) {
    $vmName     = $node.hostname
    $loc        = Get-ClusterLocation -Key $node.location
    $nodeConfig = Join-Path $machineDir "$($node.hostname).yaml"

    Write-Host ""
    Write-TalosInfo "$vmName  ip=$($node.ip)  location=$($node.location)"

    # Prefer storage.datadisks (one VM disk per entry, in order); fall back to
    # legacy single dataDiskGB for older environment.yaml files.
    $dataDisksGB = @()
    if ($w.storage -and $w.storage.datadisks) {
        $dataDisksGB = @($w.storage.datadisks | ForEach-Object { [int]$_.sizeGB })
    } elseif ($w.dataDiskGB) {
        $dataDisksGB = @([int]$w.dataDiskGB)
    }

    Deploy-TalosVM -VMName $vmName -ConfigPath $nodeConfig -NumCpu $w.cpu -MemoryGB $w.memoryGB -DiskGB $w.diskGB -DataDisksGB $dataDisksGB -PortGroup $loc.PortGroup -LibraryItem $item -TargetCluster $loc.Cluster -TargetDatastore $loc.Datastore -TargetFolder $vmFolder

    Write-TalosSuccess "$vmName deployed"
    $createdVMs += "$vmName ($($node.ip))"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summaryLines = @("VMs created and powered on:")
$summaryLines += $createdVMs | ForEach-Object { "  $_" }
$summaryLines += ""
$summaryLines += "Next: Bootstrap-TalosCluster.ps1"

Write-TalosSummary "Cluster Deployed" $summaryLines
