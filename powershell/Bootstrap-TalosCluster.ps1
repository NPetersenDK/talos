#Requires -Modules powershell-yaml
param(
    [Parameter(Mandatory)]
    [string]$ConfigsPath
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

$ConfigsPath = Resolve-Path $ConfigsPath
$env = Get-TalosEnvironment -Path (Join-Path $ConfigsPath "environment.yaml")

$talosConfig  = Resolve-Path (Join-Path $ConfigsPath $env.talos.talosConfigPath)
$kubeconfigOut = Join-Path $ConfigsPath $env.talos.kubeconfigPath

# Collect control plane IPs directly from environment.yaml
$cpNodes = $env.cluster.controlplane.nodes
$cpIPs   = $cpNodes | ForEach-Object { $_.ip }

# ─── Wait for Talos API on all CP nodes (port 50000) ─────────────────────────
Write-Host "`nWaiting for Talos API (port 50000) on all control plane nodes..."
$timeout = 600
foreach ($node in $cpNodes) {
    $elapsed = 0
    while ($true) {
        $result = Test-Connection -TargetName $node.ip -TcpPort 50000 -TimeoutSeconds 3 -ErrorAction SilentlyContinue
        if ($result) {
            Write-Host "  $($node.hostname) ($($node.ip)) Talos API ready"
            break
        }
        if ($elapsed -ge $timeout) {
            Write-Error "Timed out waiting for Talos API on $($node.hostname) ($($node.ip))"
            exit 1
        }
        Start-Sleep -Seconds 10
        $elapsed += 10
    }
}

# ─── Bootstrap etcd on cp-1 ──────────────────────────────────────────────────
$bootstrapIP = $cpIPs[0]
Write-Host "`nBootstrapping etcd on $($cpNodes[0].hostname) ($bootstrapIP)..."
$bootstrapOutput = & talosctl bootstrap `
    --talosconfig $talosConfig `
    --endpoints $bootstrapIP `
    --nodes $bootstrapIP 2>&1

if ($LASTEXITCODE -ne 0) {
    if ($bootstrapOutput -match 'AlreadyExists') {
        Write-Host "  etcd already bootstrapped — continuing"
    } else {
        Write-Error "talosctl bootstrap failed: $bootstrapOutput"
        exit 1
    }
}

# ─── Wait for all members to join ────────────────────────────────────────────
Write-Host "`nWaiting for all $($cpNodes.Count) control plane nodes to join etcd..."
$elapsed = 0
while ($true) {
    $rawOutput = & talosctl get members `
        --talosconfig $talosConfig `
        --endpoints $bootstrapIP `
        --nodes $bootstrapIP `
        --output json 2>$null

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
    Write-Host "  $($cpMembers.Count)/$($cpNodes.Count) control plane members ready"

    if ($cpMembers.Count -ge $cpNodes.Count) { break }

    if ($elapsed -ge $timeout) {
        Write-Error "Timed out waiting for etcd quorum"
        exit 1
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
}

# ─── Retrieve kubeconfig ─────────────────────────────────────────────────────
Write-Host "`nRetrieving kubeconfig..."
& talosctl kubeconfig $kubeconfigOut `
    --talosconfig $talosConfig `
    --endpoints $bootstrapIP `
    --nodes $bootstrapIP `
    --force

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to retrieve kubeconfig (exit $LASTEXITCODE)"
    exit 1
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host "`n========================================="
Write-Host "Cluster bootstrapped successfully!"
Write-Host ""
Write-Host "Control plane IPs:"
$cpNodes | ForEach-Object {
    Write-Host "  $($_.hostname) -> $($_.ip)"
}
Write-Host ""
Write-Host "VIP: $($env.talos.vip)"
Write-Host ""
Write-Host "To access the cluster:"
Write-Host "  `$env:KUBECONFIG = '$kubeconfigOut'"
Write-Host "  kubectl get nodes"
Write-Host "========================================="
