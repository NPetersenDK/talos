#Requires -Modules powershell-yaml, Posh-SSH
param(
    # Path to your environment yaml file (e.g. C:\configs\environment.yaml).
    [Parameter(Mandatory)]
    [string]$EnvironmentFile
)

Import-Module (Join-Path $PSScriptRoot ".." "TalosHelper") -Force

if (-not (Test-Path $EnvironmentFile -PathType Leaf)) {
    Write-Error "Environment file not found: $EnvironmentFile`nPoint -EnvironmentFile directly at your environment yaml file"
    exit 1
}
$EnvironmentFile = (Resolve-Path $EnvironmentFile).Path
$config = Get-TalosEnvironment -Path $EnvironmentFile

Write-TalosBanner "Prepare Talos Image (Proxmox)"

$px        = $config.proxmox
if (-not $px) {
    Write-Error "No 'proxmox' section found in environment.yaml"
    exit 1
}
$sshUser   = $px.sshUser ?? 'root'
$imageDir  = $px.imagePath ?? '/var/lib/vz/template/talos'
$imageFile = $config.schematic.nocloudImageFile
$imageUrl  = $config.schematic.nocloudImageUrl

Write-TalosInfo "Image URL:  $imageUrl"
Write-TalosInfo "Image file: $imageDir/$imageFile"

# ─── Download image on every Proxmox host referenced by a location ────────────
Write-TalosStep 1 "Downloading nocloud image on Proxmox hosts"

$hosts = @($px.locations.Values | ForEach-Object { $_.host } | Sort-Object -Unique)

foreach ($pveHost in $hosts) {
    Write-Host ""
    Write-TalosInfo "Host: $pveHost"

    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "mkdir -p '$imageDir'" | Out-Null

    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "test -f '$imageDir/$imageFile'" -AllowFailure | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-TalosWarn "Image already present on $pveHost — skipping download"
        continue
    }

    Write-TalosInfo "Downloading and decompressing (this can take a while)..."
    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "curl -sL --fail -o '$imageDir/$imageFile.xz' '$imageUrl' && xz -d -f '$imageDir/$imageFile.xz'" -TimeoutSeconds 3600 | Out-Null

    Invoke-ProxmoxSsh -SshHost $pveHost -User $sshUser -Command "test -f '$imageDir/$imageFile'" | Out-Null
    Write-TalosSuccess "Image ready on $pveHost"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-TalosSummary "Image Ready" @(
    "Hosts:   $($hosts -join ', ')",
    "Image:   $imageDir/$imageFile",
    "Version: $($config.schematic.version)",
    "",
    "Next: Deploy-TalosCluster.ps1"
)
