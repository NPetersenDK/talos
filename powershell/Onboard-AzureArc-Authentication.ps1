param(
    [Parameter()]
    [string]$EntraGroupId,

    [Parameter()]
    [string]$KubeContext
)

Import-Module (Join-Path $PSScriptRoot "TalosHelper") -Force

Write-TalosBanner "Azure Arc - Entra Authentication Setup"

# ─── Prerequisites ────────────────────────────────────────────────────────────
Write-TalosStep 1 "Checking prerequisites"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error "kubectl not found on PATH — cannot continue"
    exit 1
}
Write-TalosSuccess "kubectl found"

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx) {
    Write-TalosInfo "No active Azure session — launching interactive login"
    Connect-AzAccount -ErrorAction Stop
}
Write-TalosSuccess "Azure session: $($ctx.Account.Id)"

# ─── Resolve Entra identity ───────────────────────────────────────────────────
Write-TalosStep 2 "Resolving Entra identity"

if ($EntraGroupId) {
    $entityId = $EntraGroupId
    $entityDesc = "group"
    $bindingFlag = "--group"
} else {
    $upn = (Get-AzContext).Account.Id
    $entityId = (Get-AzADUser -UserPrincipalName $upn -ErrorAction Stop).Id
    if (-not $entityId) {
        Write-Error "Could not resolve signed-in user '$upn' — ensure Az.Resources is available"
        exit 1
    }
    $entityDesc = "signed-in user ($upn)"
    $bindingFlag = "--user"
}

Write-TalosSuccess "Resolved $entityDesc ($entityId)"

# ─── Create ClusterRoleBinding ────────────────────────────────────────────────
Write-TalosStep 3 "Creating ClusterRoleBinding"

$kubectlCtxArgs = @()
if ($KubeContext) { $kubectlCtxArgs = @('--context', $KubeContext) }

$crbExists = kubectl get clusterrolebinding entra-user-binding @kubectlCtxArgs 2>$null
if ($crbExists) {
    Write-TalosWarn "ClusterRoleBinding entra-user-binding already exists — deleting and recreating"
    kubectl delete clusterrolebinding entra-user-binding @kubectlCtxArgs | Out-Null
}

kubectl create clusterrolebinding entra-user-binding --clusterrole cluster-admin $bindingFlag $entityId @kubectlCtxArgs | Out-Null
Write-TalosSuccess "ClusterRoleBinding created for Entra $entityDesc"

# ─── Summary ──────────────────────────────────────────────────────────────────
$summaryLines = @(
    "Identity: $entityDesc ($entityId)",
    "Role:     cluster-admin",
    "",
    "Portal:   open the Kubernetes resources view in the Azure Portal — no token needed",
    "CLI:      az connectedk8s proxy -n <cluster-name> -g <resource-group>"
)

Write-TalosSummary "Entra Authentication Configured" $summaryLines
