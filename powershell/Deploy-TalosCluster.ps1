#Requires -Modules VCF.PowerCLI, powershell-yaml
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
$env = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

Connect-TalosVCenter -Server $env.vcenter.server

function New-NodeConfig {
    param(
        [string]$BaseConfigPath,
        [string]$Hostname,
        [string]$IP,
        [string]$SubnetPrefix,
        [string]$Gateway,
        [string[]]$Nameservers,
        [string]$VIP = $null
    )

    $iface = @{
        interface = "eth0"
        dhcp      = $false
        mtu       = 9000
        addresses = @("$IP/$SubnetPrefix")
        routes    = @(
            @{
                network = "0.0.0.0/0"
                gateway = $Gateway
            }
        )
    }

    if ($VIP) {
        $iface.vip = @{ ip = $VIP }
    }

    $patch = @{
        machine = @{
            network = @{
                interfaces  = @($iface)
                nameservers = $Nameservers
            }
        }
        cluster = @{
            network = @{
                cni = @{ name = "none" }
            }
            proxy = @{ disabled = $true }
        }
    }

    $hostnameConfig = @{
        apiVersion = "v1alpha1"
        kind       = "HostnameConfig"
        hostname   = $Hostname
        auto       = "off"
    }

    $tempPatch = [System.IO.Path]::GetTempFileName() + ".yaml"
    $tempOut   = [System.IO.Path]::GetTempFileName() + ".yaml"

    $yaml  = ($patch | ConvertTo-Yaml)
    $yaml += "`n---`n"
    $yaml += ($hostnameConfig | ConvertTo-Yaml)
    $yaml | Set-Content -Path $tempPatch -Encoding UTF8

    & talosctl machineconfig patch $BaseConfigPath `
        --patch "@$tempPatch" `
        --output $tempOut

    Remove-Item $tempPatch -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tempOut)) {
        throw "Failed to generate node config for $Hostname"
    }

    return $tempOut
}

function Deploy-TalosVM {
    param(
        [string]$VMName,
        [string]$ConfigPath,
        [int]$NumCpu,
        [int]$MemoryGB,
        [int]$DiskGB,
        [string]$PortGroup,
        $LibraryItem,
        $TargetCluster,
        $TargetDatastore,
        $TargetFolder
    )

    $configBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $ConfigPath))
    $configBase64 = [Convert]::ToBase64String($configBytes)

    Write-Host "  Creating VM: $VMName"
    $vm = New-VM -Name $VMName `
        -ContentLibraryItem $LibraryItem `
        -ResourcePool $TargetCluster `
        -Datastore $TargetDatastore `
        -DiskStorageFormat Thin

    Write-Host "  Setting resources: $NumCpu vCPU, ${MemoryGB} GB RAM"
    Set-VM -VM $vm -NumCpu $NumCpu -MemoryGB $MemoryGB -Confirm:$false | Out-Null

    $disk = Get-HardDisk -VM $vm | Select-Object -First 1
    Write-Host "  Configuring disk: ${DiskGB} GB thin provisioned"
    Set-HardDisk -HardDisk $disk -CapacityGB $DiskGB -Confirm:$false | Out-Null

    $nic = Get-NetworkAdapter -VM $vm | Select-Object -First 1
    if ($nic) {
        $vdpg = Get-VDPortgroup -Name $PortGroup -ErrorAction SilentlyContinue
        if ($vdpg) {
            Set-NetworkAdapter -NetworkAdapter $nic -Portgroup $vdpg -Confirm:$false | Out-Null
        } else {
            Set-NetworkAdapter -NetworkAdapter $nic -NetworkName $PortGroup -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
    }

    Write-Host "  Injecting machine config via guestinfo"
    New-AdvancedSetting -Entity $vm -Name "guestinfo.talos.config" -Value $configBase64 -Force -Confirm:$false | Out-Null
    New-AdvancedSetting -Entity $vm -Name "disk.enableUUID" -Value "TRUE" -Force -Confirm:$false | Out-Null

    Write-Host "  Powering on $VMName"
    Start-VM -VM $vm | Out-Null

    if ($TargetFolder) {
        Move-VM -VM $vm -InventoryLocation $TargetFolder -Confirm:$false | Out-Null
    }

    return $vm
}

# Resolve base config paths
$cpConfigPath     = Join-Path $ConfigsPath $env.cluster.controlplane.configPath
$workerConfigPath = Join-Path $ConfigsPath $env.cluster.worker.configPath

if (-not (Test-Path $cpConfigPath)) {
    Write-Error "Control plane config not found: $cpConfigPath`nRun 'talosctl gen config' first (see README Step 2)"
    exit 1
}
if (-not (Test-Path $workerConfigPath)) {
    Write-Error "Worker config not found: $workerConfigPath`nRun 'talosctl gen config' first (see README Step 2)"
    exit 1
}

$library   = Get-ContentLibrary -Name $env.library.name -Local
$item      = Get-ContentLibraryItem -ContentLibrary $library -Name $env.schematic.libraryItemName

# Ensure VM folder exists
$vmFolder = $null
if ($env.vmware.folder) {
    $vmFolder = Get-Folder -Name $env.vmware.folder -Type VM -ErrorAction SilentlyContinue
    if (-not $vmFolder) {
        Write-Host "Creating VM folder: $($env.vmware.folder)"
        $rootFolder = Get-Folder -Name 'vm' -Type VM | Select-Object -First 1
        $vmFolder = New-Folder -Name $env.vmware.folder -Location $rootFolder
    } else {
        Write-Host "VM folder already exists: $($env.vmware.folder)"
    }
}

$net         = $env.cluster.network
$nameservers = @($net.nameservers)
$createdVMs  = @()
$locationCache = @{}

function Get-ClusterLocation {
    param([string]$Key)
    if (-not $locationCache.ContainsKey($Key)) {
        $loc = $env.vmware.locations.$Key
        if (-not $loc) { throw "Unknown location key: '$Key'" }
        $locationCache[$Key] = @{
            Cluster   = Get-Cluster   -Name $loc.cluster
            Datastore = Get-Datastore -Name $loc.datastore
            PortGroup = $loc.portgroup
        }
    }
    return $locationCache[$Key]
}

# Pre-flight: check no VMs already exist
Write-Host "`nChecking for existing VMs..."
$allHostnames = @(
    ($env.cluster.controlplane.nodes | ForEach-Object { $_.hostname })
    ($env.cluster.worker.nodes       | ForEach-Object { $_.hostname })
)
$existing = $allHostnames | Where-Object { Get-VM -Name $_ -ErrorAction SilentlyContinue }
if ($existing) {
    Write-Error "The following VMs already exist — remove them before redeploying:`n  $($existing -join "`n  ")"
    exit 1
}
Write-Host "  All clear — no existing VMs found"

# Deploy control plane nodes
Write-Host "`n--- Control Plane Nodes ---"
$cp = $env.cluster.controlplane
foreach ($node in $cp.nodes) {
    $vmName = $node.hostname
    $loc    = Get-ClusterLocation -Key $node.location

    Write-Host "`n[$vmName] hostname=$($node.hostname) ip=$($node.ip) location=$($node.location)"

    $nodeConfig = New-NodeConfig `
        -BaseConfigPath $cpConfigPath `
        -Hostname $node.hostname `
        -IP $node.ip `
        -SubnetPrefix $net.subnetPrefix `
        -Gateway $net.gateway `
        -Nameservers $nameservers `
        -VIP $env.talos.vip

    try {
        Deploy-TalosVM -VMName $vmName `
            -ConfigPath $nodeConfig `
            -NumCpu $cp.cpu -MemoryGB $cp.memoryGB -DiskGB $cp.diskGB `
            -PortGroup $loc.PortGroup `
            -LibraryItem $item -TargetCluster $loc.Cluster -TargetDatastore $loc.Datastore `
            -TargetFolder $vmFolder
    } finally {
        Remove-Item $nodeConfig -Force -ErrorAction SilentlyContinue
    }

    $createdVMs += "$vmName ($($node.ip))"
}

# Deploy worker nodes
Write-Host "`n--- Worker Nodes ---"
$w = $env.cluster.worker
foreach ($node in $w.nodes) {
    $vmName = $node.hostname
    $loc    = Get-ClusterLocation -Key $node.location

    Write-Host "`n[$vmName] hostname=$($node.hostname) ip=$($node.ip) location=$($node.location)"

    $nodeConfig = New-NodeConfig `
        -BaseConfigPath $workerConfigPath `
        -Hostname $node.hostname `
        -IP $node.ip `
        -SubnetPrefix $net.subnetPrefix `
        -Gateway $net.gateway `
        -Nameservers $nameservers

    try {
        Deploy-TalosVM -VMName $vmName `
            -ConfigPath $nodeConfig `
            -NumCpu $w.cpu -MemoryGB $w.memoryGB -DiskGB $w.diskGB `
            -PortGroup $loc.PortGroup `
            -LibraryItem $item -TargetCluster $loc.Cluster -TargetDatastore $loc.Datastore `
            -TargetFolder $vmFolder
    } finally {
        Remove-Item $nodeConfig -Force -ErrorAction SilentlyContinue
    }

    $createdVMs += "$vmName ($($node.ip))"
}

# Summary
Write-Host "`n========================================="
Write-Host "Cluster VMs created and powered on:"
$createdVMs | ForEach-Object { Write-Host "  - $_" }
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Wait for control plane nodes to boot (watch VM consoles)"
Write-Host "  2. Run Bootstrap-TalosCluster.ps1 to bootstrap the cluster"
Write-Host "========================================="
