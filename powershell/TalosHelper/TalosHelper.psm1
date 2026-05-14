#Requires -Modules powershell-yaml, VCF.PowerCLI

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
    $config.schematic.ovaUrl = "https://factory.talos.dev/image/$($config.schematic.id)/$($config.schematic.version)/vmware-amd64.ova"

    # Derive installer image for upgrades
    $config.schematic.installerImage = "factory.talos.dev/installer/$($config.schematic.id):$($config.schematic.version)"

    # Derive library item name from version
    $config.schematic.libraryItemName = "talos-$($config.schematic.version)"

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

Export-ModuleMember -Function Get-TalosEnvironment, Connect-TalosVCenter
