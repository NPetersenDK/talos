param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$Location,

    [Parameter(Mandatory)]
    [string]$ClusterName,

    [Parameter()]
    [string]$KubeContext
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

Write-TalosBanner "Onboard Cluster to Azure Arc"

# ─── Prerequisites ───────────────────────────────────────────────────────────
Write-TalosStep 1 "Checking prerequisites"

if (-not (Get-Module -ListAvailable -Name Az.ConnectedKubernetes)) {
    Write-TalosInfo "Az.ConnectedKubernetes not found — installing (CurrentUser scope)"
    Install-Module -Name Az.ConnectedKubernetes -Force -Scope CurrentUser -ErrorAction Stop
}
Import-Module Az.ConnectedKubernetes -ErrorAction Stop
Write-TalosSuccess "Az.ConnectedKubernetes ready"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-TalosWarn "kubectl not found on PATH — Arc agent status check will be skipped"
    $kubectlAvailable = $false
} else {
    Write-TalosSuccess "kubectl found"
    $kubectlAvailable = $true
}

# ─── Azure login / subscription ──────────────────────────────────────────────
Write-TalosStep 2 "Azure login and subscription"

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-TalosInfo "No active Azure session — launching interactive login"
    Connect-AzAccount -ErrorAction Stop
}

Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$ctx = Get-AzContext
Write-TalosSuccess "Account:      $($ctx.Account.Id)"
Write-TalosInfo   "Subscription: $($ctx.Subscription.Name) ($SubscriptionId)"

# ─── Register providers ──────────────────────────────────────────────────────
Write-TalosStep 3 "Registering resource providers"

$providers = @(
    'Microsoft.Kubernetes',
    'Microsoft.KubernetesConfiguration',
    'Microsoft.ExtendedLocation'
)

foreach ($ns in $providers) {
    $state = (Get-AzResourceProvider -ProviderNamespace $ns).RegistrationState | Select-Object -First 1
    if ($state -eq 'Registered') {
        Write-TalosSuccess "$ns already registered"
    } 
    else {
        Write-TalosInfo "Registering $ns ..."
        Register-AzResourceProvider -ProviderNamespace $ns | Out-Null
    }
}

Write-TalosInfo "Waiting for all providers to reach Registered state (up to 10 min)"
$timeout = 600
$elapsed = 0
$pending = $providers

while ($pending.Count -gt 0 -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    $pending = $pending | Where-Object {
        ((Get-AzResourceProvider -ProviderNamespace $_).RegistrationState | Select-Object -First 1) -ne 'Registered'
    }
    if ($pending.Count -gt 0 -and $elapsed % 60 -eq 0) {
        Write-TalosInfo "Still waiting for: $($pending -join ', ') (${elapsed}s)"
    }
}

if ($pending.Count -gt 0) {
    Write-Error "Provider registration timed out for: $($pending -join ', ')"
    exit 1
}
Write-TalosSuccess "All providers registered"

# ─── Resource group ──────────────────────────────────────────────────────────
Write-TalosStep 4 "Resource group"

$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($rg) {
    Write-TalosSuccess "Resource group '$ResourceGroupName' already exists ($($rg.Location))"
} else {
    Write-TalosInfo "Creating resource group '$ResourceGroupName' in $Location"
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
    Write-TalosSuccess "Resource group created"
}

# ─── Connect cluster ─────────────────────────────────────────────────────────
Write-TalosStep 5 "Connecting cluster to Azure Arc"

$connectParams = @{
    ClusterName       = $ClusterName
    ResourceGroupName = $ResourceGroupName
    Location          = $Location
}
if ($KubeContext) {
    $connectParams['KubeContext'] = $KubeContext
    Write-TalosInfo "Using kube context: $KubeContext"
}

try {
    $result = New-AzConnectedKubernetes @connectParams -ErrorAction Stop
    Write-TalosSuccess "Connected: $($result.Name) — $($result.ConnectivityStatus)"
} catch {
    Write-Error "Failed to connect cluster: $_"
    exit 1
}

# ─── Verify connection ───────────────────────────────────────────────────────
Write-TalosStep 6 "Verifying connection"

$connected = Get-AzConnectedKubernetes -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
if ($connected) {
    foreach ($c in $connected) {
        Write-TalosSuccess "$($c.Name)  location=$($c.Location)  status=$($c.ConnectivityStatus)"
    }
} else {
    Write-TalosWarn "No connected clusters found in '$ResourceGroupName'"
}

# ─── Arc agents ──────────────────────────────────────────────────────────────
Write-TalosStep 7 "Arc agents in azure-arc namespace"

if ($kubectlAvailable) {
    $kubectlArgs = @('get', 'deployments,pods', '-n', 'azure-arc')
    if ($KubeContext) { $kubectlArgs += @('--context', $KubeContext) }
    & kubectl @kubectlArgs
} else {
    Write-TalosWarn "kubectl unavailable — skipping agent check"
    Write-TalosInfo "Run: kubectl get deployments,pods -n azure-arc"
}

# ─── Summary ─────────────────────────────────────────────────────────────────
$summaryLines = @(
    "Cluster:       $ClusterName",
    "Resource group: $ResourceGroupName",
    "Location:      $Location",
    "Subscription:  $($ctx.Subscription.Name) ($SubscriptionId)",
    "",
    "To remove the Arc resource:",
    "  Remove-AzConnectedKubernetes -ClusterName $ClusterName -ResourceGroupName $ResourceGroupName"
)

Write-TalosSummary "Cluster Onboarded to Azure Arc" $summaryLines
