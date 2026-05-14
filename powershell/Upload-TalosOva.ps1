#Requires -Modules VCF.PowerCLI, powershell-yaml
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
$env = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

Connect-TalosVCenter -Server $env.vcenter.server

# Get or create content library
$library = Get-ContentLibrary -Name $env.library.name -Local -ErrorAction SilentlyContinue
if (-not $library) {
    Write-Host "Creating content library: $($env.library.name)"
    $ds = Get-Datastore -Name $env.vmware.datastore
    $library = New-ContentLibrary -Name $env.library.name -Datastore $ds
} else {
    Write-Host "Content library '$($env.library.name)' already exists"
}

# Check if this version already exists
$itemName = $env.schematic.libraryItemName
$existingItem = Get-ContentLibraryItem -ContentLibrary $library -Name $itemName -ErrorAction SilentlyContinue

if ($existingItem) {
    Write-Host "Library item '$itemName' already exists — skipping upload"
} else {
    $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "$itemName.ova")

    Write-Host "Downloading OVA for $itemName ..."
    try {
        $curlPath = (Get-Command curl -ErrorAction SilentlyContinue)?.Source
        if ($curlPath) {
            & $curlPath -L --fail -o $tempPath $env.schematic.ovaUrl
            if ($LASTEXITCODE -ne 0) { throw "curl exited with code $LASTEXITCODE" }
        } else {
            Invoke-WebRequest -Uri $env.schematic.ovaUrl -OutFile $tempPath 
        }
    } catch {
        Write-Error "Failed to download OVA: $_"
        exit 1
    }

    if (-not (Test-Path $tempPath)) {
        Write-Error "Download completed but file not found at: $tempPath"
        exit 1
    }

    Write-Host "Importing OVA into library '$($env.library.name)' as '$itemName' ..."
    New-ContentLibraryItem -ContentLibrary $library -Name $itemName -Files $tempPath

    Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
    Write-Host "Temporary OVA file removed"
}

Write-Host "Done. Library item '$itemName' is ready in '$($env.library.name)'."
