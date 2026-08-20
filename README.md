# Release Orchestrator

Unified deployment stack for the Release Orchestrator platform. This repository
contains the single `docker-compose.yml` that boots the entire sample-app
foundation locally (a React frontend, an API gateway, and four independent
microservices, each with its own PostgreSQL database), plus the GitOps source of
truth (`k8s-manifests/` + `argocd-apps/`) that deploys the same stack to EKS
staging and production environments via ArgoCD.

## Stack

| Service         | Port   | Notes                                        |
|-----------------|--------|----------------------------------------------|
| frontend        | :5173  | React + Vite, nginx, proxies `/api/`         |
| api-gateway     | :8080  | Routes + JWT validation against auth-service |
| user-service    | (int)  | User CRUD, database-per-service              |
| order-service   | (int)  | Depends on user-service / payment-service    |
| payment-service | (int)  | Payment lifecycle                           |
| auth-service    | (int)  | JWT login/register, bcrypt credentials       |
| user-db         | :5432  | PostgreSQL 16                                |
| order-db        | :5434  | PostgreSQL 16                                |
| payment-db      | :5433  | PostgreSQL 16                                |
| auth-db         | :5435  | PostgreSQL 16                                |

Service containers are not published to the host; they communicate over the
compose network. Databases are published for debugging.

## Prerequisites

- Docker Engine with the Compose v2 plugin
- `git`

## Deploy

> Local development only — see "Kubernetes / GitOps deployment (EKS)" below for
> the cluster deployment.

Clone this repository together with the service repositories so the compose
build contexts resolve:

```bash
git clone https://github.com/Release-Orchestrator/release-orchestrator.git ~/release-platform
cd ~/release-platform

git clone https://github.com/Release-Orchestrator/user-service.git
git clone https://github.com/Release-Orchestrator/order-service.git
git clone https://github.com/Release-Orchestrator/payment-service.git
git clone https://github.com/Release-Orchestrator/auth-service.git
git clone https://github.com/Release-Orchestrator/api-gateway.git
git clone https://github.com/Release-Orchestrator/frontend.git

docker compose up --build
```

### JWT secret

Auth-service refuses to start without `JWT_SECRET`. A development default is
baked into the compose file; override it for any non-local environment:

```bash
cp .env.example .env        # then edit JWT_SECRET
docker compose up --build
```

## Endpoints (local dev)

- Frontend UI: http://localhost:5173
- API gateway: http://localhost:8080
- Health check: http://localhost:8080/health

## Kubernetes / GitOps deployment (EKS)

Same cluster, two namespaces (`staging` + `production`) served by **one**
ingress-nginx controller / load balancer. ArgoCD applies everything from this
repo — nothing is applied with `kubectl apply -k`.

### Layout

```
k8s-manifests/
└── <service>/
    ├── base/                    # Deployment/StatefulSet + Service (+ ConfigMap for frontend)
    │   ├── kustomization.yaml   # declares the GHCR image to patch
    │   ├── deployment.yaml      # postgres uses statefulset.yaml instead
    │   └── service.yaml
    └── overlays/
        ├── staging/             # 1 replica + ingress host staging.local
        └── production/          # 3 replicas + catch-all ingress (default host)
```

`argocd-apps/` defines the ArgoCD project and one Application per service per
environment. Images come from `ghcr.io/release-orchestrator/<service>`; the tag
is bumped by each service's CI `release` job on git tag via
`kustomize edit set image` and committed back to this repo.

### Postgres (StatefulSet + EBS volume)

postgres runs as a StatefulSet (`k8s-manifests/postgres/base/statefulset.yaml`):

- `volumeClaimTemplates` auto-provisions `data-postgres-0` (gp3, 2Gi) via the
  `gp3` StorageClass (`ebs.csi.aws.com`, `WaitForFirstConsumer`)
- `PGDATA=/var/lib/postgresql/data/pgdata` — subdirectory avoids the initdb
  `lost+found` error on a fresh mount
- `securityContext.fsGroup: 999`; headless `postgres` Service for stable DNS
- logical DB Services (`user-db`, `order-db`, `payment-db`, `auth-service-db`)
  still route to the pod

### Environment access

| Env | URL | Routing |
|-----|-----|---------|
| Production | `http://<LB-IP>/` | catch-all (default host) |
| Staging | `http://staging.local/` | Host-header `staging.local` |

Add `<LB-IP> staging.local` to the hosts file (Windows:
`C:\Windows\System32\drivers\etc\hosts`) to open staging in a browser.

### Bootstrap (fresh cluster)

```
eksctl create cluster --name release-orch --region ap-south-2 --nodegroup-name standard-nodes --node-type t3.medium --nodes 2

# OIDC + EBS CSI driver (the postgres PVC requires it)
eksctl utils associate-iam-oidc-provider --cluster release-orch --region ap-south-2 --approve
eksctl create iamserviceaccount --name ebs-csi-driver --namespace kube-system \
  --cluster release-orch --region ap-south-2 \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --approve
eksctl create addon --name aws-ebs-csi-driver --cluster release-orch --region ap-south-2 --force

# ingress-nginx + ArgoCD
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add argocd https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
helm upgrade --install argocd argocd/argo-cd --namespace argocd --create-namespace --set server.service.type=ClusterIP

# secrets BEFORE applying apps (images are private, so ghcr-secret is mandatory)
kubectl create namespace staging production
kubectl create secret docker-registry ghcr-secret -n staging \
  --docker-server=ghcr.io --docker-username=<USER> --docker-password=<PAT-read:packages>
kubectl create secret docker-registry ghcr-secret -n production \
  --docker-server=ghcr.io --docker-username=<USER> --docker-password=<PAT-read:packages>
kubectl create secret generic user-service-secrets -n staging \
  --from-literal=database-url="postgres://postgres:postgres@user-db:5432/user_db?sslmode=disable"
kubectl create secret generic auth-service-secrets -n staging \
  --from-literal=jwt-secret="dev-jwt-secret-change-me" --from-literal=db-password=postgres
# repeat the two generic secrets for production with prod values

# GitOps deploy
kubectl apply -f argocd-apps/project.yaml
kubectl apply -f argocd-apps/staging        # auto-sync
kubectl apply -f argocd-apps/production     # manual sync (argocd app sync / UI)
```

### Release flow

1. Tag a service repo: `git tag v1.2 && git push origin main && git push origin v1.2`
2. CI builds `ghcr.io/release-orchestrator/<svc>:v1.2`, pushes it, and bumps the
   image tag in this repo (`k8s-manifests/<svc>/base/kustomization.yaml`)
3. ArgoCD auto-syncs **staging**; promote to **production** by syncing the prod
   app (manual approval step)

### Teardown (avoid orphaned EBS volumes)

Delete the ArgoCD apps and namespaces BEFORE the cluster so the EBS CSI
controller frees the volumes while it is still alive:

```
kubectl delete -f argocd-apps/staging
kubectl delete -f argocd-apps/production
kubectl delete ns staging production
eksctl delete cluster --name release-orch --region ap-south-2

aws ec2 describe-volumes --region ap-south-2 \
  --filters Name=tag:kubernetes.io/cluster/release-orch,Values=owned \
  --query 'Volumes[*].{ID:VolumeId,State:State}'
```

Any volume left `available` is orphaned — delete it manually with
`aws ec2 delete-volume --volume-id <id> --region ap-south-2`.

### Troubleshooting

- **ImagePullBackOff / 401** → `ghcr-secret` missing in that namespace (images
  are private)
- **502 timeout (not a fast refusal)** → a Service's port and the URL another
  service uses to reach it don't match (e.g. the gateway calls
  `order-service:8080`, so that Service must listen on 8080)
- **postgres initdb `lost+found` error** → PGDATA must point at a subdirectory
  (`/var/lib/postgresql/data/pgdata`)
- **Service unreachable** → compare `kubectl get svc -n <ns>` ports with
  `kubectl get endpoints -n <ns>`

## Repositories

- [frontend](https://github.com/Release-Orchestrator/frontend)
- [api-gateway](https://github.com/Release-Orchestrator/api-gateway)
- [user-service](https://github.com/Release-Orchestrator/user-service)
- [order-service](https://github.com/Release-Orchestrator/order-service)
- [payment-service](https://github.com/Release-Orchestrator/payment-service)
- [auth-service](https://github.com/Release-Orchestrator/auth-service)
