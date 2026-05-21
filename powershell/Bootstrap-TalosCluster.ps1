#Requires -Modules powershell-yaml
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

Write-TalosBanner "Bootstrap Talos Cluster"

$talosConfig   = Resolve-Path (Join-Path $ConfigsPath $config.talos.talosConfigPath)
$kubeconfigOut = Join-Path $ConfigsPath $config.talos.kubeconfigPath

$cpNodes = @($config.cluster.controlplane.nodes)
$cpIPs   = @($cpNodes | ForEach-Object { $_.ip })

# ─── Wait for Talos API ──────────────────────────────────────────────────────
Write-TalosStep 1 "Waiting for Talos API (port 50000)"

$timeout = 600
foreach ($node in $cpNodes) {
    $elapsed = 0
    while ($true) {
        $result = Test-Connection -TargetName $node.ip -TcpPort 50000 -TimeoutSeconds 3 -ErrorAction SilentlyContinue
        if ($result) {
            Write-TalosSuccess "$($node.hostname) ($($node.ip)) ready"
            break
        }
        if ($elapsed -ge $timeout) {
            Write-Error "Timed out waiting for Talos API on $($node.hostname) ($($node.ip))"
            exit 1
        }
        if ($elapsed % 30 -eq 0 -and $elapsed -gt 0) {
            Write-TalosInfo "Still waiting for $($node.hostname)... (${elapsed}s)"
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
}

# ─── Bootstrap etcd ──────────────────────────────────────────────────────────
Write-TalosStep 2 "Bootstrapping etcd on $($cpNodes[0].hostname)"

$bootstrapIP = $cpIPs[0]
Write-TalosInfo "Target: $bootstrapIP"

$bootstrapOutput = & talosctl bootstrap --talosconfig $talosConfig --endpoints $bootstrapIP --nodes $bootstrapIP 2>&1

if ($LASTEXITCODE -ne 0) {
    if ($bootstrapOutput -match 'AlreadyExists') {
        Write-TalosWarn "etcd already bootstrapped — continuing"
    } else {
        Write-Error "talosctl bootstrap failed: $bootstrapOutput"
        exit 1
    }
} else {
    Write-TalosSuccess "etcd bootstrap initiated"
}

# ─── Wait for quorum ─────────────────────────────────────────────────────────
Write-TalosStep 3 "Waiting for etcd quorum ($($cpNodes.Count) members)"

$elapsed = 0
while ($true) {
    $rawOutput = & talosctl get members --talosconfig $talosConfig --endpoints $bootstrapIP --nodes $bootstrapIP --output json 2>$null

    $members = @()
    $buffer = ""
    foreach ($line in $rawOutput) {
        $buffer += $line
        try {
            $obj = $buffer | ConvertFrom-Json -ErrorAction Stop
            $members += $obj
            $buffer = ""
        } catch {
            # Incomplete JSON object — keep accumulating lines
        }
    }

    $cpMembers = $members | Where-Object { $_.spec.machineType -eq 'controlplane' -or $_.spec.type -eq 'controlplane' }
    Write-TalosInfo "$($cpMembers.Count)/$($cpNodes.Count) control plane members joined"

    if ($cpMembers.Count -ge $cpNodes.Count) {
        Write-TalosSuccess "All control plane members joined"
        break
    }

    if ($elapsed -ge $timeout) {
        Write-Error "Timed out waiting for etcd quorum"
        exit 1
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
}

# ─── Configure talosconfig ───────────────────────────────────────────────────
Write-TalosStep 4 "Configuring talosconfig endpoints"

& talosctl config endpoint $config.talos.vip --talosconfig $talosConfig
& talosctl config node @cpIPs --talosconfig $talosConfig
Write-TalosSuccess "Endpoint: $($config.talos.vip)"
Write-TalosInfo "Nodes: $($cpIPs -join ', ')"

# ─── Retrieve kubeconfig ─────────────────────────────────────────────────────
Write-TalosStep 5 "Retrieving kubeconfig"

& talosctl kubeconfig $kubeconfigOut --talosconfig $talosConfig --endpoints $bootstrapIP --nodes $bootstrapIP --force

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to retrieve kubeconfig (exit $LASTEXITCODE)"
    exit 1
}
Write-TalosSuccess "Saved to $kubeconfigOut"

# ─── Summary ─────────────────────────────────────────────────────────────────
$summaryLines = @("Control plane:")
$cpNodes | ForEach-Object {
    $summaryLines += "  $($_.hostname) -> $($_.ip)"
}
$summaryLines += ""
$summaryLines += "VIP: $($config.talos.vip)"
$summaryLines += ""
$summaryLines += "Access the cluster:"
$summaryLines += "  `$env:KUBECONFIG = '$kubeconfigOut'"
$summaryLines += "  kubectl get nodes"

Write-TalosSummary "Cluster Bootstrapped" $summaryLines
