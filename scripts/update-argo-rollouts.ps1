<#
.SYNOPSIS
Update Argo Rollouts controller version by re-rendering Helm chart.

.DESCRIPTION
Renders the Argo Rollouts Helm chart at a specific version and updates
the committed rendered.yaml. Commit and push to trigger ArgoCD sync.

.PARAMETER Version
Argo Rollouts Helm chart version (e.g., 2.43.12). Defaults to latest.

.PARAMETER AppVersion
Argo Rollouts app version (e.g., v1.10.2). Used for image tag reference.
#>
param(
    [string]$Version = "2.43.12",
    [string]$AppVersion = "v1.10.2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [$Level] $Message"
}

Write-Log "Updating Argo Rollouts to chart version $Version (app $AppVersion)..."

# Ensure Helm repo is up to date
Write-Log "Updating Helm repositories..."
helm repo update

# Render chart
$outputPath = "k8s-manifests/argo-rollouts/base/rendered.yaml"
Write-Log "Rendering chart to $outputPath..."

helm template argo-rollouts argo/argo-rollouts `
  --namespace argo-rollouts `
  --version $Version `
  --set controller.replicas=2 `
  --set controller.metrics.enabled=true `
  --set controller.metrics.serviceMonitor.enabled=true `
  --set controller.metrics.serviceMonitor.namespace=monitoring `
  --set controller.webhook.enabled=true `
  --set dashboard.enabled=false `
  --set crds.install=true `
  --set crds.keep=true `
  > $outputPath

if (-not (Test-Path $outputPath)) {
    Write-Log "ERROR: Failed to generate $outputPath" "ERROR"
    exit 1
}

$size = (Get-Item $outputPath).Length
Write-Log "Generated $outputPath ($([math]::Round($size/1KB, 1)) KB)"

# Show diff if git is available
if (git status --porcelain $outputPath 2>$null) {
    Write-Log "Changes detected:"
    git diff $outputPath | Select-Object -First 50
}

Write-Log "Next steps:"
Write-Log "  1. Review changes: git diff $outputPath"
Write-Log "  2. Commit: git add $outputPath && git commit -m \"chore: update argo-rollouts to chart v$Version (app $AppVersion)\""
Write-Log "  3. Push: git push"
Write-Log "  4. ArgoCD will auto-sync the controller"