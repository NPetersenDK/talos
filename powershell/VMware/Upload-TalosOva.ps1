#Requires -Modules VCF.PowerCLI, powershell-yaml
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

Write-TalosBanner "Upload Talos OVA"

# ─── Connect to vCenter ──────────────────────────────────────────────────────
Write-TalosStep 1 "Connecting to vCenter"
Connect-TalosVCenter -Server $config.vcenter.server
Write-TalosSuccess "Connected to $($config.vcenter.server)"

# ─── Get or create content library ───────────────────────────────────────────
Write-TalosStep 2 "Checking content library"

$library = Get-ContentLibrary -Name $config.library.name -Local -ErrorAction SilentlyContinue
if (-not $library) {
    Write-TalosInfo "Creating content library: $($config.library.name)"
    $ds = Get-Datastore -Name $config.vmware.datastore
    $library = New-ContentLibrary -Name $config.library.name -Datastore $ds
    Write-TalosSuccess "Created library: $($config.library.name)"
} else {
    Write-TalosSuccess "Library exists: $($config.library.name)"
}

# ─── Check / upload OVA ──────────────────────────────────────────────────────
Write-TalosStep 3 "Uploading OVA image"

$itemName = $config.schematic.libraryItemName
Write-TalosInfo "Item name: $itemName"
Write-TalosInfo "OVA URL:   $($config.schematic.ovaUrl)"

$existingItem = Get-ContentLibraryItem -ContentLibrary $library -Name $itemName -ErrorAction SilentlyContinue

if ($existingItem) {
    Write-TalosWarn "Library item '$itemName' already exists — skipping upload"
} else {
    $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$itemName.ova")

    Write-TalosInfo "Downloading OVA..."
    try {
        $curlPath = (Get-Command curl -ErrorAction SilentlyContinue)?.Source
        if ($curlPath) {
            & $curlPath -L --fail -o $tempPath $config.schematic.ovaUrl
            if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
        } else {
            Invoke-WebRequest -Uri $config.schematic.ovaUrl -OutFile $tempPath
        }
    } catch {
        Write-Error "Failed to download OVA: $_"
        exit 1
    }

    if (-not (Test-Path $tempPath)) {
        Write-Error "Download completed but file not found at: $tempPath"
        exit 1
    }

    Write-TalosInfo "Importing into library..."
    New-ContentLibraryItem -ContentLibrary $library -Name $itemName -Files $tempPath
    Write-TalosSuccess "Imported as '$itemName'"

    Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
    Write-TalosInfo "Temp file cleaned up"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-TalosSummary "OVA Ready" @(
    "Library:  $($config.library.name)",
    "Item:     $itemName",
    "Version:  $($config.schematic.version)",
    "",
    "Next: Deploy-TalosCluster.ps1"
)
