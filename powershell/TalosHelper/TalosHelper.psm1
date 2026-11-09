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

    # Proxmox (nocloud) nodes: the plain installer would switch them to talos.platform=metal.
    $config['schematic']['nocloudInstallerImage'] = "factory.talos.dev/nocloud-installer/$($config['schematic']['id']):$($config['schematic']['version'])"

    # Derive VMware installer image for gen config
    $config['schematic']['vmwareInstallerImage'] = "factory.talos.dev/vmware-installer/$($config['schematic']['id']):$($config['schematic']['version'])"

    # Derive library item name from version + schematic ID
    $config['schematic']['libraryItemName'] = "talos-$($config['schematic']['version'])-$($config['schematic']['id'])"

    # Derive Proxmox (nocloud) image URL and cached filename on the Proxmox node
    $config['schematic']['nocloudImageUrl'] = "https://factory.talos.dev/image/$($config['schematic']['id'])/$($config['schematic']['version'])/nocloud-amd64.raw.xz"
    $config['schematic']['nocloudImageFile'] = "talos-$($config['schematic']['version'])-$($config['schematic']['id'])-nocloud-amd64.raw"

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

# ─── MAC addresses (node.mac in environment.yaml is the source of truth) ─────

# Sets node.mac in environment.yaml by editing the text, so comments and line endings survive.
function Set-TalosNodeMac {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$Mac
    )

    if ($Mac -notmatch '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$') {
        throw "Invalid MAC address '$Mac' (want aa:bb:cc:dd:ee:ff)"
    }
    $Mac = $Mac.ToLower()

    $raw   = [System.IO.File]::ReadAllText($Path)
    $eol   = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($raw -split "\r?\n"))

    $hostPattern = '^(\s*)-\s+hostname:\s*["'']?' + [regex]::Escape($Hostname) + '["'']?\s*(#.*)?$'
    $start = -1
    $keyIndent = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $hostPattern) {
            $start = $i
            $keyIndent = $Matches[1].Length + 2
            break
        }
    }
    if ($start -lt 0) { throw "Node '$Hostname' not found in $Path" }

    # The block ends at the first line indented less than its keys.
    $end = $lines.Count
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        $l = $lines[$j]
        if ($l -match '^\s*$' -or $l -match '^\s*#') { continue }
        $indent = $l.Length - $l.TrimStart().Length
        if ($indent -lt $keyIndent) { $end = $j; break }
    }

    $macLine = (' ' * $keyIndent) + 'mac: "' + $Mac + '"'
    for ($k = $start + 1; $k -lt $end; $k++) {
        if ($lines[$k] -match '^\s*mac:') {
            $lines[$k] = $macLine
            [System.IO.File]::WriteAllText($Path, ($lines -join $eol))
            return
        }
    }

    # No mac yet: insert after the block's last key line.
    $at = $end
    while ($at -gt $start + 1 -and ($lines[$at - 1] -match '^\s*$' -or $lines[$at - 1] -match '^\s*#')) { $at-- }
    $lines.Insert($at, $macLine)
    [System.IO.File]::WriteAllText($Path, ($lines -join $eol))
}

# MAC of a running node's one physical NIC (type ether, no kind). Refuses unless exactly one.
function Get-TalosNodeMacLive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TalosConfig,
        [Parameter(Mandatory)][string]$Address
    )

    $out = & talosctl --talosconfig $TalosConfig -e $Address -n $Address get links -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "talosctl get links failed on ${Address}: $($out -join ' ')" }

    # talosctl prints one JSON object per resource, not an array.
    $text  = ($out | Out-String).Trim()
    $links = ('[' + ($text -replace '\}\s*\{', '},{') + ']') | ConvertFrom-Json

    $candidates = @($links | Where-Object {
        $_.spec.type -eq 'ether' -and [string]::IsNullOrEmpty($_.spec.kind) -and $_.spec.hardwareAddr
    })
    if ($candidates.Count -ne 1) {
        $found = ($candidates | ForEach-Object { "$($_.metadata.id)=$($_.spec.hardwareAddr)" }) -join ', '
        throw "Expected exactly one physical NIC on $Address, found $($candidates.Count) ($found). Set node.mac in environment.yaml by hand."
    }
    return $candidates[0].spec.hardwareAddr.ToLower()
}

# One node's machine config from environment.yaml + the base config (shared by Initialize,
# Proxmox deploy and Apply).
function New-TalosNodeConfigFromEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Node,
        [Parameter(Mandatory)][ValidateSet('controlplane', 'worker')][string]$Role,
        # Folder holding environment.yaml and talosfiles/
        [Parameter(Mandatory)][string]$ConfigsPath
    )

    $outputDir  = Join-Path $ConfigsPath "talosfiles"
    $machineDir = Join-Path $outputDir "machineconfigs"
    $base       = Join-Path $outputDir "$Role.yaml"
    if (-not (Test-Path $base)) {
        throw "Base config not found: $base. Run Initialize-TalosConfig.ps1 first (never with -RegenBase on a live cluster)."
    }
    if (-not (Test-Path $machineDir)) { New-Item -ItemType Directory -Path $machineDir | Out-Null }

    $net = $Config.cluster.network
    $out = Join-Path $machineDir "$($Node.hostname).yaml"
    $params = @{
        BaseConfigPath = $base
        Hostname       = $Node.hostname
        IP             = $Node.ip
        SubnetPrefix   = $net.subnetPrefix
        Gateway        = $net.gateway
        Nameservers    = @($net.nameservers)
        Mtu            = [int]($net.mtu ?? 0)
        InstallImage   = (Get-TalosInstallerImage -Config $Config -Node $Node)
        Mac            = $Node.mac
        OutputPath     = $out
    }
    if ($Role -eq 'controlplane') {
        $params.VIP = $Config.talos.vip
    }
    else {
        if ($Config.cluster.worker.storage) { $params.StorageConfig = $Config.cluster.worker.storage }
        $params.DataDiskGB = [int]($Config.cluster.worker.dataDiskGB ?? 0)
    }
    New-TalosNodeConfig @params | Out-Null
    return $out
}

# Installer image for a node: Proxmox (nocloud) nodes use the plain installer,
# VMware nodes the vmware-installer variant. A node is a Proxmox node when its
# location is defined under proxmox.locations.
function Get-TalosInstallerImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Node
    )
    $isProxmox = $Config.proxmox -and $Config.proxmox.locations -and ($Config.proxmox.locations.Keys -contains $Node.location)
    if ($isProxmox) { return $Config.schematic.nocloudInstallerImage }
    return $Config.schematic.vmwareInstallerImage
}

# Sessions and credential are cached for the lifetime of the module (one
# password prompt per script run, one connection per host).
$script:ProxmoxCredential  = $null
$script:ProxmoxSshSessions = @{}

function Get-ProxmoxSshSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [string]$User = 'root'
    )

    Import-Module Posh-SSH -ErrorAction Stop

    $key = "$User@$SshHost"
    $session = $script:ProxmoxSshSessions[$key]
    if ($session -and $session.Session.IsConnected) {
        return $session
    }

    if (-not $script:ProxmoxCredential -or $script:ProxmoxCredential.UserName -ne $User) {
        $script:ProxmoxCredential = Get-Credential -UserName $User -Message "SSH password for $User on Proxmox host(s)"
        if (-not $script:ProxmoxCredential) {
            throw "No credential provided for Proxmox SSH"
        }
    }

    $session = New-SSHSession -ComputerName $SshHost -Credential $script:ProxmoxCredential -AcceptKey -ErrorAction Stop
    $script:ProxmoxSshSessions[$key] = $session
    return $session
}

function Invoke-ProxmoxSsh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [string]$User = 'root',
        [Parameter(Mandatory)][string]$Command,
        # Long-running commands (image download) need more than the 60s default
        [int]$TimeoutSeconds = 600,
        # Return output without throwing on non-zero exit (caller checks $LASTEXITCODE)
        [switch]$AllowFailure
    )

    $session = Get-ProxmoxSshSession -SshHost $SshHost -User $User
    $result  = Invoke-SSHCommand -SSHSession $session -Command $Command -TimeOut $TimeoutSeconds

    # Preserve the $LASTEXITCODE contract callers rely on
    $global:LASTEXITCODE = $result.ExitStatus

    if ($result.ExitStatus -ne 0 -and -not $AllowFailure) {
        throw "SSH command failed on $SshHost (exit $($result.ExitStatus)): $Command`n$($result.Output -join "`n")`n$($result.Error -join "`n")"
    }
    return $result.Output
}

function Copy-ProxmoxFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SshHost,
        [string]$User = 'root',
        [Parameter(Mandatory)][string]$LocalPath,
        [Parameter(Mandatory)][string]$RemotePath
    )

    # Write file content over the existing SSH session instead of opening a
    # separate SCP/SFTP connection; machine configs are small text files.
    $content = Get-Content -Path $LocalPath -Raw
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($content))
    Invoke-ProxmoxSsh -SshHost $SshHost -User $User -Command "echo '$b64' | base64 -d > '$RemotePath'" | Out-Null
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
        # Interface MTU; 0 = omit from config (Talos/kernel default, 1500).
        # Only set >1500 when the hypervisor NIC and physical network support it.
        [int]$Mtu = 0,
        [string]$VIP = $null,
        [string]$OutputPath = $null,
        # Overrides machine.install.image (installer used for upgrades/reinstalls).
        # Needed when the base config carries a different installer than this node
        # should use (e.g. Proxmox nodes in a cluster whose base config is VMware).
        [string]$InstallImage = $null,
        # NIC MAC (aa:bb:cc:dd:ee:ff) the static address is bound to. Required.
        [string]$Mac = $null,
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

    # Bind to the MAC, never the NIC name: Talos 1.14 renames eth0 to ens18 and a name-bound
    # config then matches nothing (node falls back to DHCP). No MAC, no config: no guessing.
    if (-not $Mac) {
        throw "No MAC address for $Hostname. Set node.mac in environment.yaml (Proxmox deploy and Apply-TalosConfig.ps1 fill it in)."
    }
    $iface = @{
        dhcp      = $false
        addresses = @("$IP/$SubnetPrefix")
        routes    = @(
            @{
                network = "0.0.0.0/0"
                gateway = $Gateway
            }
        )
    }
    if ($Mac -notmatch '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$') {
        throw "Invalid MAC address '$Mac' for $Hostname (want aa:bb:cc:dd:ee:ff)"
    }
    $iface.deviceSelector = @{ hardwareAddr = $Mac.ToLower() }

    if ($Mtu -gt 0) {
        $iface.mtu = $Mtu
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

    if ($InstallImage) {
        $machine['install'] = @{ image = $InstallImage }
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
    Invoke-ProxmoxSsh, Copy-ProxmoxFile,
    Write-TalosBanner, Write-TalosStep, Write-TalosSuccess, Write-TalosWarn,
    Write-TalosInfo, Write-TalosSummary, New-TalosNodeConfig, Get-TalosInstallerImage,
    Set-TalosNodeMac, Get-TalosNodeMacLive, New-TalosNodeConfigFromEnvironment
