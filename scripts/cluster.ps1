<#
.SYNOPSIS
  Manage the Release-Orchestrator EKS demo cluster: create / destroy / status.

.DESCRIPTION
  Idempotent - safe to run repeatedly. Designed for a cluster that is
  destroyed after each work session and recreated on demand.
  Does NOT need Docker; images are built and pushed by GitHub Actions CI.

.PARAMETER Action
  create   provision cluster, tooling and deploy the platform (default)
  destroy  delete the cluster and everything inside it
  status   show cluster, ArgoCD apps and pods

.PARAMETER JwtSecret
  JWT secret used by auth-service (dev default; override for anything real).

.PARAMETER DbPassword
  Postgres superuser password (dev default; must match order/payment defaults).

.EXAMPLE
  .\scripts\cluster.ps1 create
  .\scripts\cluster.ps1 destroy
  .\scripts\cluster.ps1 status
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("create", "destroy", "status")]
    [string]$Action = "create",

    [string]$JwtSecret  = "dev-jwt-secret-change-me",
    [string]$DbPassword = "postgres"
)

# ---------- configuration ----------
$ClusterName            = "release-platform"
$Region                 = "ap-south-1"
$EksctlConfig           = Join-Path $PSScriptRoot "eksctl-config.yaml"
$RepoRoot               = Split-Path $PSScriptRoot -Parent
$ArgocdAppsDir          = Join-Path $RepoRoot "argocd-apps"
$ArgocdNamespace        = "argocd"
$IngressNamespace       = "ingress-nginx"
$RepoUrl                = "https://github.com/Release-Orchestrator/release-orchestrator"
$RepoRevision           = "main"
$ClusterAutoscalerIam   = "arn:aws:iam::aws:policy/AmazonEKSClusterAutoscalerPolicy"

# Pin chart versions here for reproducibility. Empty string = latest chart.
$ArgoChartVersion              = ""
$IngressNginxChartVersion      = ""
$ClusterAutoscalerChartVersion = ""

# ---------- helpers ----------
function Assert-NativeSuccess {
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE"
    }
}

function Test-RequiredTools {
    $required = @("aws", "eksctl", "kubectl", "helm", "argocd", "git")
    $missing = @()
    foreach ($t in $required) {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
    }
    if ($missing.Count -gt 0) {
        throw "Missing required tools: $($missing -join ', '). Install them and re-run."
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function New-Secret {
    param([string]$Name, [string]$Namespace, [hashtable]$Entries)
    $literals = @()
    foreach ($k in $Entries.Keys) { $literals += "--from-literal=$k=$($Entries[$k])" }
    $yaml = & kubectl create secret generic $Name -n $Namespace --dry-run=client -o yaml @literals
    Assert-NativeSuccess
    $yaml | & kubectl apply -f -
    Assert-NativeSuccess
    Write-Host "  secret '$Name' ($Namespace) applied"
}

# ---------- actions ----------
function Invoke-Create {
    Write-Step "Verifying AWS identity"
    & aws sts get-caller-identity
    Assert-NativeSuccess

    Write-Step "Checking cluster '$ClusterName'"
    & eksctl get cluster --name $ClusterName --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Creating cluster '$ClusterName' (takes ~10-15 min)"
        & eksctl create cluster -f $EksctlConfig
        Assert-NativeSuccess
    } else {
        Write-Host "  cluster already exists - skipping creation"
    }

    Write-Step "Updating kubeconfig"
    & aws eks update-kubeconfig --name $ClusterName --region $Region
    Assert-NativeSuccess

    Write-Step "Ensuring OIDC provider (for IAM roles for service accounts)"
    & eksctl utils associate-iam-oidc-provider --cluster $ClusterName --region $Region --approve 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  OIDC already associated or skipped - continuing" }

    Write-Step "Creating IAM service account for cluster-autoscaler"
    & eksctl create iamserviceaccount --cluster $ClusterName --region $Region `
        --name cluster-autoscaler --namespace kube-system `
        --attach-policy-arn $ClusterAutoscalerIam `
        --override-existing-serviceaccounts --approve 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "  cluster-autoscaler SA already exists - continuing" }

    Write-Step "Adding helm repositories"
    & helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>&1 | Out-Null
    & helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>&1 | Out-Null
    & helm repo add argocd https://argoproj.github.io/argo-helm 2>&1 | Out-Null
    & helm repo update 2>&1 | Out-Null

    Write-Step "Installing cluster-autoscaler (enables node autoscaling min 1 / max 2)"
    $caArgs = @("upgrade", "--install", "cluster-autoscaler", "autoscaler/cluster-autoscaler",
        "--namespace", "kube-system",
        "--set", "autoDiscovery.clusterName=$ClusterName",
        "--set", "awsRegion=$Region",
        "--set", "rbac.serviceAccount.create=false",
        "--set", "rbac.serviceAccount.name=cluster-autoscaler")
    if ($ClusterAutoscalerChartVersion) { $caArgs += @("--version", $ClusterAutoscalerChartVersion) }
    & helm @caArgs
    Assert-NativeSuccess

    Write-Step "Installing ingress-nginx"
    $inArgs = @("upgrade", "--install", "ingress-nginx", "ingress-nginx/ingress-nginx",
        "--namespace", $IngressNamespace, "--create-namespace",
        "--set", "controller.publishService.enabled=true")
    if ($IngressNginxChartVersion) { $inArgs += @("--version", $IngressNginxChartVersion) }
    & helm @inArgs
    Assert-NativeSuccess

    Write-Step "Installing ArgoCD"
    $arArgs = @("upgrade", "--install", "argocd", "argocd/argo-cd",
        "--namespace", $ArgocdNamespace, "--create-namespace",
        "--set", "server.service.type=ClusterIP")
    if ($ArgoChartVersion) { $arArgs += @("--version", $ArgoChartVersion) }
    & helm @arArgs
    Assert-NativeSuccess

    Write-Step "Waiting for ArgoCD to be ready"
    & kubectl -n $ArgocdNamespace rollout status deployment/argocd-server --timeout=300s
    Assert-NativeSuccess
    & kubectl -n $ArgocdNamespace rollout status deployment/argocd-repo-server --timeout=300s
    Assert-NativeSuccess
    & kubectl -n $ArgocdNamespace rollout status deployment/argocd-application-controller --timeout=300s
    Assert-NativeSuccess

    Write-Step "Applying platform secrets (dev defaults)"
    New-Secret "user-service-secrets" "staging" @{ "database-url" = "postgres://postgres:$DbPassword@user-db:5432/user_db?sslmode=disable" }
    New-Secret "auth-service-secrets" "staging" @{ "jwt-secret" = $JwtSecret; "db-password" = $DbPassword }
    New-Secret "user-service-secrets" "production" @{ "database-url" = "postgres://postgres:$DbPassword@user-db:5432/user_db?sslmode=disable" }
    New-Secret "auth-service-secrets" "production" @{ "jwt-secret" = $JwtSecret; "db-password" = $DbPassword }

    Write-Step "Applying ArgoCD app-of-apps (project + staging apps)"
    & kubectl apply -f (Join-Path $ArgocdAppsDir "project.yaml")
    Assert-NativeSuccess
    & kubectl apply -f (Join-Path $ArgocdAppsDir "staging")
    Assert-NativeSuccess

    Write-Step "Waiting for ingress LoadBalancer address (up to 5 min)"
    $lb = ""
    for ($i = 0; $i -lt 30; $i++) {
        $lb = & kubectl -n $IngressNamespace get svc ingress-nginx-controller -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>$null
        if ($LASTEXITCODE -eq 0 -and $lb) { break }
        Start-Sleep -Seconds 10
    }

    Write-Step "Logging in to ArgoCD and syncing apps"
    $pf = Start-Process kubectl -ArgumentList @("-n", $ArgocdNamespace, "port-forward", "svc/argocd-server", "8080:443") -PassThru -WindowStyle Hidden
    try {
        Start-Sleep -Seconds 8
        $adminPassword = ""
        $pwB64 = & kubectl -n $ArgocdNamespace get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>$null
        if ($pwB64) { $adminPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pwB64)) }
        if ($adminPassword) {
            & argocd login localhost:8080 --insecure --username admin --password $adminPassword
            Assert-NativeSuccess
            & argocd app list -o name
        } else {
            Write-Host "  could not read admin password - login manually with:"
            Write-Host "  kubectl -n argocd port-forward svc/argocd-server 8080:443"
            Write-Host "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
        }
    } finally {
        Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
    }

    Write-Step "Summary"
    if ($lb) { Write-Host "  LB URL     : http://$lb" } else { Write-Host "  LB URL     : (still provisioning - check: kubectl -n $IngressNamespace get svc ingress-nginx-controller)" }
    Write-Host "  Frontend   : http://$lb/"
    Write-Host "  API        : http://$lb/api"
    Write-Host "  ArgoCD UI  : kubectl -n argocd port-forward svc/argocd-server 8080:443  ->  https://localhost:8080"
    Write-Host "  ArgoCD user: admin"
    Write-Host "  Next sync  : argocd app list / argocd app sync <name>"
}

function Invoke-Destroy {
    Write-Step "Checking cluster '$ClusterName'"
    & eksctl get cluster --name $ClusterName --region $Region | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  cluster does not exist - nothing to destroy"
        return
    }
    $ans = Read-Host "Destroy cluster '$ClusterName'? This deletes ALL data, secrets and the ingress LB DNS. Type 'yes' to confirm"
    if ($ans -ne "yes") { Write-Host "  aborted"; return }
    & eksctl delete cluster -f $EksctlConfig
    Assert-NativeSuccess
    Write-Host "  cluster '$ClusterName' deleted"
}

function Invoke-Status {
    Write-Step "Cluster"
    & eksctl get cluster --name $ClusterName --region $Region
    if ($LASTEXITCODE -ne 0) { Write-Host "  (no cluster)"; return }

    Write-Step "Nodes"
    & kubectl get nodes -o wide

    Write-Step "ArgoCD applications"
    & kubectl -n $ArgocdNamespace get applications

    Write-Step "Pods (all namespaces)"
    & kubectl get pods -A -o wide

    Write-Step "Ingress LoadBalancer"
    & kubectl -n $IngressNamespace get svc ingress-nginx-controller
}

# ---------- main ----------
Write-Host "Release-Orchestrator cluster script - action: $Action" -ForegroundColor Green
Test-RequiredTools

switch ($Action) {
    "create"  { Invoke-Create }
    "destroy" { Invoke-Destroy }
    "status"  { Invoke-Status }
}
