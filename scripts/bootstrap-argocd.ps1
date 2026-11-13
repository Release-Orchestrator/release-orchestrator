<#
.SYNOPSIS
Bootstrap ArgoCD with Argo Rollouts controller and optional self-management.

.DESCRIPTION
Applies the ArgoCD Project and bootstrap Applications via kubectl.
This must run AFTER ArgoCD is installed but BEFORE it manages itself.

.PARAMETER RepoUrl
Git repository URL for the manifest source.

.PARAMETER Revision
Git revision (branch/tag/commit) to track.
#>
param(
    [string]$RepoUrl = "https://github.com/Release-Orchestrator/release-orchestrator",
    [string]$Revision = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

Write-Log "Starting ArgoCD bootstrap..."

# 1. Apply Project (idempotent)
Write-Log "Applying AppProject..."
kubectl apply -f "argocd-apps/project.yaml"

# 2. Apply Argo Rollouts bootstrap app
Write-Log "Applying Argo Rollouts bootstrap Application..."
kubectl apply -f "argocd-apps/bootstrap/argo-rollouts.yaml"

# 3. Wait for Argo Rollouts controller to be ready
Write-Log "Waiting for Argo Rollouts controller deployment..."
kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=300s

# 4. Verify CRDs are registered
Write-Log "Verifying Argo Rollouts CRDs..."
$crds = @("rollouts.argoproj.io", "analysistemplates.argoproj.io", "analysisruns.argoproj.io", "experiments.argoproj.io")
foreach ($crd in $crds) {
    if (kubectl get crd $crd -o name 2>$null) {
        Write-Log "CRD $crd: REGISTERED"
    } else {
        Write-Log "CRD $crd: MISSING" "WARN"
    }
}

# 5. Verify ServiceMonitor created
Write-Log "Verifying ServiceMonitor..."
kubectl get servicemonitor argo-rollouts -n monitoring -o name 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Log "ServiceMonitor: CREATED"
} else {
    Write-Log "ServiceMonitor: NOT FOUND (Prometheus may not discover controller metrics)" "WARN"
}

Write-Log "ArgoCD bootstrap complete!"
Write-Log "Argo Rollouts controller is now managed by ArgoCD via GitOps."