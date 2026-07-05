#Requires -Modules powershell-yaml

function Get-TalosEnvironment {
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (-not $Path) {
        $Path = Join-Path $PSScriptRoot ".." "environment.yaml"
    }

    if (-not (Test-Path $Path)) {
        throw "Environment file not found: $Path"
    }

    $raw = Get-Content -Path $Path -Raw
    $config = ConvertFrom-Yaml $raw

    # Derive OVA URL from schematic ID and version
    $config['schematic']['ovaUrl'] = "https://factory.talos.dev/image/$($config['schematic']['id'])/$($config['schematic']['version'])/vmware-amd64.ova"

    # Derive installer image for upgrades
    $config['schematic']['installerImage'] = "factory.talos.dev/installer/$($config['schematic']['id']):$($config['schematic']['version'])"

    # Derive VMware installer image for gen config
    $config['schematic']['vmwareInstallerImage'] = "factory.talos.dev/vmware-installer/$($config['schematic']['id']):$($config['schematic']['version'])"

    # Derive library item name from version + schematic ID
    $config['schematic']['libraryItemName'] = "talos-$($config['schematic']['version'])-$($config['schematic']['id'])"

    # Validate: no duplicate hostnames across all nodes
    $allNodes = @($config['cluster']['controlplane']['nodes']) + @($config['cluster']['worker']['nodes'])
    $duplicates = $allNodes | Group-Object { $_['hostname'] } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
    if ($duplicates) {
        throw "Duplicate hostnames found in environment.yaml: $($duplicates -join ', ')"
    }

    return $config
}

function Connect-TalosVCenter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Server
    )

    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

    # Check if already connected to the right server
    if ($global:DefaultVIServer -and $global:DefaultVIServer.Name -eq $Server -and $global:DefaultVIServer.IsConnected) {
        Write-Host "Already connected to vCenter: $Server"
        return $global:DefaultVIServer
    }

    Write-Host "Connecting to vCenter: $Server"
    return Connect-VIServer -Server $Server
}

# ─── Formatting Helpers ──────────────────────────────────────────────────────

function Write-TalosBanner {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Cyan
    Write-Host ""
}

function Write-TalosStep {
    param(
        [int]$Number,
        [string]$Message
    )
    Write-Host "  [$Number] " -ForegroundColor DarkCyan -NoNewline
    Write-Host $Message -ForegroundColor White
}

function Write-TalosSuccess {
    param([string]$Message)
    Write-Host "   ✓ " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-TalosWarn {
    param([string]$Message)
    Write-Host "   ⚠ " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-TalosInfo {
    param([string]$Message)
    Write-Host "     " -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

function Write-TalosSummary {
    param(
        [string]$Title,
        [string[]]$Lines
    )
    Write-Host ""
    Write-Host "Done: $Title" -ForegroundColor Green
    foreach ($line in $Lines) {
        Write-Host "  $line"
    }
    Write-Host ""
}

# ─── Config Generation ───────────────────────────────────────────────────────

function New-TalosNodeConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BaseConfigPath,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$IP,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string[]]$Nameservers,
        [string]$VIP = $null,
        [string]$OutputPath = $null,
        # Optional storage config (from environment.yaml cluster.worker.storage)
        # Preferred: hashtable with key 'datadisks' -> array of @{ sizeGB; mountpoint },
        # one VMware disk per entry (/dev/sdb, /dev/sdc, ...).
        # Legacy: hashtable with keys 'mountPath' / 'hostpathDir' + -DataDiskGB,
        # for a single second disk (still supported for older environment.yaml files).
        [hashtable]$StorageConfig = $null,
        # Legacy: when set (and StorageConfig has no 'datadisks'), configures a
        # single second disk at /dev/sdb using StorageConfig['mountPath'].
        [int]$DataDiskGB = 0
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

    $machine = @{
        network = @{
            interfaces  = @($iface)
            nameservers = $Nameservers
        }
        nodeLabels = @{
            "bgp-policy" = "default"
        }
    }

    # ── Storage: additional disks ───────────────────────────────────────────
    # Preferred path: one VMware disk per StorageConfig.datadisks entry
    # (/dev/sdb, /dev/sdc, ...), each mounted at its own mountpoint. Longhorn's
    # own default disk path (/var/lib/longhorn) doesn't need a kubelet
    # extraMount — Longhorn's Helm chart bind-mounts that path into its own
    # pods independently. Any other mountpoint (e.g. generic hostpath storage)
    # gets a kubelet extraMount so hostPath volumes can see it.
    if ($StorageConfig -and $StorageConfig['datadisks']) {
        $devLetters  = @('b', 'c', 'd', 'e', 'f', 'g', 'h')
        $disks       = @()
        $extraMounts = @()
        $i = 0
        foreach ($dataDisk in @($StorageConfig['datadisks'])) {
            $mountpoint = $dataDisk['mountpoint']
            if (-not $mountpoint) { continue }
            if ($i -ge $devLetters.Count) {
                throw "Too many datadisks entries (max $($devLetters.Count) supported)"
            }
            $disks += @{
                device     = "/dev/sd$($devLetters[$i])"
                partitions = @(@{ mountpoint = $mountpoint })
            }
            if ($mountpoint -ne '/var/lib/longhorn') {
                $extraMounts += @{
                    destination = $mountpoint
                    type        = "bind"
                    source      = $mountpoint
                    options     = @("bind", "rshared", "rw")
                }
            }
            $i++
        }
        if ($disks.Count -gt 0) {
            $machine['disks'] = $disks
        }
        if ($extraMounts.Count -gt 0) {
            $machine['kubelet'] = @{ extraMounts = $extraMounts }
        }
    }
    # Legacy path: single second disk via -DataDiskGB + StorageConfig.mountPath
    elseif ($DataDiskGB -gt 0 -and $StorageConfig -and $StorageConfig['mountPath']) {
        $machine['disks'] = @(
            @{
                device     = "/dev/sdb"
                partitions = @(
                    @{ mountpoint = $StorageConfig['mountPath'] }
                )
            }
        )

        if ($StorageConfig['hostpathDir']) {
            $hostpathDir = $StorageConfig['hostpathDir']
            $machine['kubelet'] = @{
                extraMounts = @(
                    @{
                        destination = $hostpathDir
                        type        = "bind"
                        source      = $hostpathDir
                        options     = @("bind", "rshared", "rw")
                    }
                )
            }
        }
    }

    $patch = @{
        machine = $machine
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
    if (-not $OutputPath) {
        $OutputPath = [System.IO.Path]::GetTempFileName() + ".yaml"
    }

    $yaml  = ($patch | ConvertTo-Yaml)
    $yaml += "`n---`n"
    $yaml += ($hostnameConfig | ConvertTo-Yaml)
    $yaml | Set-Content -Path $tempPatch -Encoding UTF8

    & talosctl machineconfig patch $BaseConfigPath --patch "@$tempPatch" --output $OutputPath

    Remove-Item $tempPatch -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutputPath)) {
        throw "Failed to generate node config for $Hostname"
    }

    return $OutputPath
}

Export-ModuleMember -Function Get-TalosEnvironment, Connect-TalosVCenter,
    Write-TalosBanner, Write-TalosStep, Write-TalosSuccess, Write-TalosWarn,
    Write-TalosInfo, Write-TalosSummary, New-TalosNodeConfig
