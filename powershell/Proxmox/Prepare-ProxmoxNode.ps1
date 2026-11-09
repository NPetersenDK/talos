#Requires -Modules Posh-SSH
<#
.SYNOPSIS
    Prepares a fresh Proxmox VE node over SSH for Talos VMs.

.DESCRIPTION
    1. apt: Enterprise to pve-no-subscription, update.
    2. IOMMU + vfio for GPU passthrough.
    3. The unused NVMe as VM storage (LVM-thin, or ZFS).
    4. The second NIC as a VLAN-aware bridge (vmbr1); prompts for VLANs, created as SDN VNets.
    5. Offers a reboot (needed for IOMMU).
    Idempotent. The management NIC (vmbr0) is never touched.

.EXAMPLE
    .\Prepare-ProxmoxNode.ps1 -PveHost 10.0.6.21

.EXAMPLE
    .\Prepare-ProxmoxNode.ps1 -PveHost pve02.example.local -StorageType zfs -SkipGpu
#>
param(
    # Management IP / hostname of the new Proxmox node.
    [Parameter(Mandatory)]
    [string]$PveHost,

    [string]$SshUser = 'root',

    # PCI address of the NIC that becomes the VLAN trunk (Intel I226-V).
    [string]$NicPciAddress = '0000:03:00.0',

    [string]$BridgeName = 'vmbr1',

    # MTU on the VLAN NIC and bridge (jumbo frames). The switch port and every
    # VLAN used must also allow it.
    [ValidateRange(1500, 9216)]
    [int]$Mtu = 9000,

    # Proxmox storage ID created on the free NVMe disk.
    [string]$StorageName = 'vmdata',

    [ValidateSet('lvmthin', 'zfs')]
    [string]$StorageType = 'lvmthin',

    # SDN zone (max 8 chars) that holds the VLAN VNets.
    [ValidatePattern('^[a-z][a-z0-9]{0,7}$')]
    [string]$SdnZone = 'vlans',

    [switch]$SkipRepos,
    [switch]$SkipUpgrade,
    [switch]$SkipGpu,
    [switch]$SkipStorage,
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot ".." "TalosHelper") -Force

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Invoke-Pve {
    param([string]$Command, [int]$TimeoutSeconds = 600, [switch]$AllowFailure)
    Invoke-ProxmoxSsh -SshHost $PveHost -User $SshUser -Command $Command -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
}

# Runs a multi-line bash script on the node. Variables are injected as a preamble
# so the script body can stay a literal here-string.
function Invoke-PveScript {
    param([string]$Script, [hashtable]$Vars = @{}, [int]$TimeoutSeconds = 600, [switch]$AllowFailure)
    $pre = ($Vars.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value -replace "'", "'\''")'" }) -join "`n"
    $body = "set -e`n$pre`n$Script" -replace "`r", ''
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($body))
    Invoke-Pve -Command "echo '$b64' | base64 -d | bash 2>&1" -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure
}

function Read-Confirm {
    param([string]$Question, [bool]$Default = $true)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $answer = Read-Host "$Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer -match '^(y|yes|j|ja)$'
}

function Read-Choice {
    param([string]$Title, [string[]]$Options)
    Write-Host ""
    Write-Host $Title
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host "  [$($i + 1)] $($Options[$i])" }
    while ($true) {
        $n = 0
        if ([int]::TryParse((Read-Host "Choose 1-$($Options.Count)"), [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
            return $n - 1
        }
    }
}

Write-TalosBanner "Prepare Proxmox Node"
Write-TalosInfo "Node: $SshUser@$PveHost"

$needsReboot = $false
$summary = [System.Collections.Generic.List[string]]::new()

$pveVersion = (Invoke-Pve "pveversion").Trim()
Write-TalosInfo $pveVersion

# ─── Step 1: Repositories (community instead of Enterprise) ──────────────────
if (-not $SkipRepos) {
    Write-TalosStep 1 "Switching to pve-no-subscription repository"

    $out = Invoke-PveScript @'
codename=$(. /etc/os-release; echo "$VERSION_CODENAME")

# Disable every enterprise repo (pve, ceph) by renaming - apt ignores *.disabled
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [ -e "$f" ] || continue
  if grep -q 'enterprise.proxmox.com' "$f"; then
    mv "$f" "$f.disabled"
    echo "disabled $(basename "$f")"
  fi
done

if ! grep -rqs 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/ --include='*.list' --include='*.sources' --include='sources.list'; then
  cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOT
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $codename
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOT
  echo "added pve-no-subscription ($codename)"
else
  echo "pve-no-subscription already present"
fi
'@
    $out | ForEach-Object { Write-TalosInfo $_ }

    Write-TalosInfo "apt update..."
    Invoke-Pve "DEBIAN_FRONTEND=noninteractive apt-get update" -TimeoutSeconds 300 | Out-Null

    if (-not $SkipUpgrade) {
        if (Read-Confirm "Run apt dist-upgrade now?") {
            Write-TalosInfo "dist-upgrade (this can take a while)..."
            Invoke-Pve "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade" -TimeoutSeconds 1800 | Out-Null
            $needsReboot = $true
        }
    }
    Write-TalosSuccess "Repositories configured"
    $summary.Add("Repos:    pve-no-subscription (Enterprise disabled)")
}

# ─── Step 2: GPU passthrough ─────────────────────────────────────────────────
if (-not $SkipGpu) {
    Write-TalosStep 2 "GPU passthrough (IOMMU + vfio)"

    $gpuLines = @(Invoke-Pve "lspci -Dnn | grep -E '\[(0300|0302|0380)\]' || true") | Where-Object { $_ }
    $gpus = foreach ($l in $gpuLines) {
        if ($l -match '^(?<addr>\S+)\s+(?<desc>.*)\[(?<id>[0-9a-f]{4}:[0-9a-f]{4})\]') {
            [pscustomobject]@{ Address = $Matches.addr; Desc = $Matches.desc.Trim(); Id = $Matches.id }
        }
    }

    if (-not $gpus) {
        Write-TalosWarn "No GPU found on the node - skipping passthrough"
    }
    else {
        $gpus = @($gpus)
        $pick = if ($gpus.Count -eq 1) { 0 } else { Read-Choice "Which GPU should be passed through?" ($gpus | ForEach-Object { "$($_.Address)  $($_.Desc) [$($_.Id)]" }) }
        $gpu = $gpus[$pick]
        Write-TalosInfo "GPU: $($gpu.Address)  $($gpu.Desc) [$($gpu.Id)]"

        $slot = $gpu.Address -replace '\.\d+$', ''
        $fnLines = @(Invoke-Pve "lspci -Dnn -s '$slot.'")
        $ids = @($fnLines | ForEach-Object { if ($_ -match '\[(?<id>[0-9a-f]{4}:[0-9a-f]{4})\]') { $Matches.id } } | Sort-Object -Unique)
        Write-TalosInfo "Functions bound to vfio-pci: $($ids -join ', ')"

        $vendor = (Invoke-Pve "grep -m1 vendor_id /proc/cpuinfo").Trim()
        $iommuParams = if ($vendor -match 'AuthenticAMD') { 'iommu=pt' } else { 'intel_iommu=on iommu=pt' }

        $changed = Invoke-PveScript @'
changed=0

# ── kernel cmdline: systemd-boot (proxmox-boot-tool) or GRUB ──
if proxmox-boot-tool status 2>&1 | grep -qiE 'configured with: uefi|systemd-boot'; then
  for p in $PARAMS; do
    grep -qw -- "$p" /etc/kernel/cmdline || { sed -i "1s/\$/ $p/" /etc/kernel/cmdline; changed=1; }
  done
  [ "$changed" = 1 ] && proxmox-boot-tool refresh >/dev/null
else
  for p in $PARAMS; do
    grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=.*(\"| )$p(\"| )" /etc/default/grub || { sed -i "s/^\(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*\)\"/\1 $p\"/" /etc/default/grub; changed=1; }
  done
  [ "$changed" = 1 ] && update-grub >/dev/null 2>&1
fi

# ── vfio modules ──
for m in vfio vfio_iommu_type1 vfio_pci; do
  grep -qx "$m" /etc/modules || { echo "$m" >> /etc/modules; changed=1; }
done

# ── bind GPU to vfio-pci before the host drivers can grab it ──
cat > /tmp/vfio.conf <<EOT
# Managed by Prepare-ProxmoxNode.ps1
options vfio-pci ids=$IDS disable_vga=1
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidiafb pre: vfio-pci
softdep radeon pre: vfio-pci
softdep amdgpu pre: vfio-pci
softdep i915 pre: vfio-pci
softdep xe pre: vfio-pci
EOT
cmp -s /tmp/vfio.conf /etc/modprobe.d/vfio.conf || { cp /tmp/vfio.conf /etc/modprobe.d/vfio.conf; changed=1; }
rm -f /tmp/vfio.conf

[ "$changed" = 1 ] && update-initramfs -u -k all >/dev/null 2>&1
echo $changed
'@ -Vars @{ PARAMS = $iommuParams; IDS = ($ids -join ',') } -TimeoutSeconds 600

        if (($changed | Select-Object -Last 1) -eq '1') { $needsReboot = $true }

        if ($gpu.Id -match '^8086') {
            Write-TalosWarn "This is an Intel GPU - if it is the host's only display, the console goes blank after reboot"
        }
        Write-TalosSuccess "IOMMU/vfio configured ($iommuParams)"
        $summary.Add("GPU:      $($gpu.Address) [$($ids -join ', ')] bound to vfio-pci")
        $summary.Add("          VM config: hostpci0: $($slot -replace '^0000:',''),pcie=1  (q35 + OVMF)")
    }
}

# ─── Step 3: VM storage on the free NVMe disk ────────────────────────────────
if (-not $SkipStorage) {
    Write-TalosStep 3 "VM storage on unused NVMe disk"

    $exists = Invoke-Pve "pvesm status --storage '$StorageName' >/dev/null 2>&1" -AllowFailure
    if ($LASTEXITCODE -eq 0) {
        Write-TalosWarn "Storage '$StorageName' already exists - skipping"
    }
    else {
        $diskLines = @(Invoke-PveScript @'
for d in $(lsblk -dnpr -o NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1}'); do
  size=$(lsblk -dnr -o SIZE "$d")
  model=$(lsblk -dn -o MODEL "$d" | sed 's/ *$//')
  mounts=$(lsblk -nr -o MOUNTPOINTS "$d" | grep -c . || true)
  pv=$(pvs --noheadings -o pv_name 2>/dev/null | grep -c "^ *$d" || true)
  zfs=$(zpool status -P 2>/dev/null | grep -c "$d" || true)
  parts=$(lsblk -nr -o NAME "$d" | tail -n +2 | wc -l)
  echo "$d|$size|$model|$((mounts+pv+zfs))|$parts"
done
'@) | Where-Object { $_ }

        $disks = foreach ($l in $diskLines) {
            $p = $l -split '\|'
            [pscustomobject]@{ Device = $p[0]; Size = $p[1]; Model = $p[2]; InUse = [int]$p[3] -gt 0; Partitions = [int]$p[4] }
        }
        $free = @($disks | Where-Object { -not $_.InUse })

        Write-TalosInfo "NVMe disks found: $(@($disks).Count)"
        foreach ($d in $disks) { Write-TalosInfo ("  {0}  {1}  {2}  {3}" -f $d.Device, $d.Size, $d.Model, $(if ($d.InUse) { '(in use - OS)' } else { '(free)' })) }

        if ($free.Count -eq 0) {
            Write-TalosWarn "No free NVMe disk - skipping storage"
        }
        else {
            $disk = if ($free.Count -eq 1) { $free[0] } else { $free[(Read-Choice "Which disk should become '$StorageName'?" ($free | ForEach-Object { "$($_.Device)  $($_.Size)  $($_.Model)" }))] }

            Write-Host ""
            Write-TalosWarn "ALL DATA on $($disk.Device) ($($disk.Size), $($disk.Model)) will be destroyed"
            if ($disk.Partitions -gt 0) { Write-TalosWarn "The disk currently has $($disk.Partitions) partition(s)" }
            $typed = Read-Host "Type the device name ($($disk.Device)) to confirm, or press Enter to skip"

            if ($typed -ne $disk.Device) {
                Write-TalosWarn "Not confirmed - skipping storage"
            }
            else {
                Invoke-PveScript @'
wipefs -a "$DISK" >/dev/null
command -v sgdisk >/dev/null && sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true

if [ "$TYPE" = "zfs" ]; then
  dev="$DISK"
  for l in /dev/disk/by-id/nvme-eui.* /dev/disk/by-id/nvme-*; do
    [ -e "$l" ] && [ "$(readlink -f "$l")" = "$DISK" ] && { dev="$l"; break; }
  done
  zpool create -f -o ashift=12 "$NAME" "$dev"
  zfs set compression=lz4 atime=off "$NAME"
  pvesm add zfspool "$NAME" --pool "$NAME" --content images,rootdir
else
  pvcreate -y "$DISK" >/dev/null
  vgcreate "$NAME" "$DISK" >/dev/null
  lvcreate -y -l 95%FREE -T "$NAME/data" >/dev/null
  pvesm add lvmthin "$NAME" --vgname "$NAME" --thinpool data --content images,rootdir
fi
'@ -Vars @{ DISK = $disk.Device; NAME = $StorageName; TYPE = $StorageType } -TimeoutSeconds 300 | Out-Null

                Write-TalosSuccess "Storage '$StorageName' ($StorageType) created on $($disk.Device)"
                $summary.Add("Storage:  $StorageName ($StorageType) on $($disk.Device)")
            }
        }
    }
}

# ─── Step 4: Second NIC as VLAN trunk + VLAN VNets ───────────────────────────
if (-not $SkipNetwork) {
    Write-TalosStep 4 "VLAN bridge on second NIC"

    $addr = if ($NicPciAddress -match '^[0-9a-f]{4}:') { $NicPciAddress } else { "0000:$NicPciAddress" }
    $nic = (Invoke-Pve "ls /sys/bus/pci/devices/$addr/net/ 2>/dev/null | head -1" -AllowFailure | Select-Object -First 1)
    if (-not $nic) { throw "No network interface found at PCI address $addr (check -NicPciAddress)" }
    $nic = $nic.Trim()
    Write-TalosInfo "NIC at ${addr}: $nic"

    $result = Invoke-PveScript @'
IF=/etc/network/interfaces

if grep -q "^iface $BRIDGE " "$IF"; then
  # Block already written (maybe by an earlier failed run) - make sure it is actually up
  ip link show "$BRIDGE" >/dev/null 2>&1 || ifreload -a
  state=exists
else
  # Never steal a NIC that another bridge (e.g. management) already uses
  if grep -E '^\s*bridge-ports' "$IF" | grep -qw "$NIC"; then
    echo "ERROR: $NIC is already used by another bridge"; exit 1
  fi
  cp "$IF" "$IF.bak.$(date +%s)"
  {
    echo ""
    grep -q "^iface $NIC " "$IF" || printf 'auto %s\niface %s inet manual\n\n' "$NIC" "$NIC"
    printf 'auto %s\niface %s inet manual\n\tbridge-ports %s\n\tbridge-stp off\n\tbridge-fd 0\n\tbridge-vlan-aware yes\n\tbridge-vids 2-4094\n#VLAN trunk (Prepare-ProxmoxNode)\n' "$BRIDGE" "$BRIDGE" "$NIC"
  } >> "$IF"
  # SDN include: modern PVE already has 'source /etc/network/interfaces.d/*'
  grep -qE '^source.*interfaces\.d/(\*|sdn)' "$IF" || echo 'source /etc/network/interfaces.d/*' >> "$IF"
  ifreload -a
  state=created
fi

# MTU on both the physical port and the bridge (bridge uses the lowest port MTU)
reload=0
for dev in "$NIC" "$BRIDGE"; do
  if ! grep -A6 "^iface $dev " "$IF" | sed '/^$/q' | grep -q '^\s*mtu '; then
    sed -i "s/^iface $dev inet manual\$/&\n\tmtu $MTU/" "$IF"
    reload=1
  fi
done
[ "$reload" = 1 ] && ifreload -a

ip link show "$BRIDGE" >/dev/null
echo "$state"
'@ -Vars @{ BRIDGE = $BridgeName; NIC = $nic; MTU = $Mtu } -AllowFailure

    if ($LASTEXITCODE -ne 0) { throw "Bridge setup failed (exit $LASTEXITCODE):`n$($result -join "`n")" }
    if (($result | Select-Object -Last 1) -eq 'exists') { Write-TalosWarn "$BridgeName already exists - leaving as is" }
    else { Write-TalosSuccess "$BridgeName created (VLAN-aware, port $nic, MTU $Mtu, no IP)" }
    $summary.Add("Network:  $BridgeName on $nic (VLAN-aware trunk, MTU $Mtu)")

    # SDN zone
    Invoke-Pve "pvesh get /cluster/sdn/zones/$SdnZone >/dev/null 2>&1" -AllowFailure | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Pve "pvesh create /cluster/sdn/zones --zone $SdnZone --type vlan --bridge $BridgeName" | Out-Null
        Write-TalosSuccess "SDN zone '$SdnZone' created on $BridgeName"
    }

    $existingJson = (Invoke-Pve "pvesh get /cluster/sdn/vnets --output-format json") -join ''
    $existing = @($existingJson | ConvertFrom-Json)

    Write-Host ""
    $created = 0
    while ($true) {
        $question = if ($created -eq 0) { "Add a VLAN?" } else { "Add another VLAN?" }
        if (-not (Read-Confirm $question ($created -eq 0))) { break }

        $name = (Read-Host "VLAN name (max 8 chars, a-z0-9, e.g. servers)").Trim().ToLower()
        if ($name -notmatch '^[a-z][a-z0-9]{0,7}$') { Write-TalosWarn "Invalid name - lowercase letters/digits, starts with a letter, max 8 chars"; continue }
        if ($existing.vnet -contains $name) { Write-TalosWarn "VNet '$name' already exists"; continue }

        $id = 0
        if (-not [int]::TryParse((Read-Host "VLAN ID for '$name' (2-4094)"), [ref]$id) -or $id -lt 2 -or $id -gt 4094) { Write-TalosWarn "Invalid VLAN ID"; continue }
        if ($existing.tag -contains $id) { Write-TalosWarn "VLAN ID $id is already used by another VNet"; continue }

        Invoke-Pve "pvesh create /cluster/sdn/vnets --vnet $name --zone $SdnZone --tag $id --alias '$name'" | Out-Null
        $existing += [pscustomobject]@{ vnet = $name; tag = $id }
        $summary.Add("VLAN:     $name = $id")
        $created++
        Write-TalosSuccess "VNet '$name' (VLAN $id) created"
    }

    if ($created -gt 0) {
        Invoke-Pve "pvesh set /cluster/sdn" | Out-Null
        Write-TalosSuccess "SDN configuration applied"
    }
}

# ─── Step 5: Reboot ──────────────────────────────────────────────────────────
Write-TalosSummary "Node Prepared" (@($summary) + @(
        "",
        $(if ($needsReboot) { "Reboot required (IOMMU/vfio/kernel changes)" } else { "No reboot required" }),
        "After reboot check the GPU IOMMU group:  find /sys/kernel/iommu_groups -type l | sort -V",
        "",
        "Next: Prepare-TalosImage.ps1"
    ))

if ($needsReboot -and (Read-Confirm "Reboot $PveHost now?" $false)) {
    Invoke-Pve "nohup sh -c 'sleep 2; reboot' >/dev/null 2>&1 &" -AllowFailure | Out-Null
    Write-TalosInfo "Reboot triggered"
}
