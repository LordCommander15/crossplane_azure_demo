# Crossplane Azure Demo — Global Warning System

## What This Project Does

This project deploys a **complete cloud-native platform** on Azure Kubernetes Service (AKS) using **GitOps** principles. It provisions infrastructure, platform services, and an application — all from a single bootstrap script and a Git repository.

The end result is a **Flask dashboard** ("Global Warning System") that connects to a **managed Azure PostgreSQL** database, with the entire stack managed declaratively through Git.

---

## What Gets Deployed

| Component | Purpose |
|-----------|---------|
| **AKS Cluster** | Kubernetes cluster on Azure (1-node, Standard_B2s) |
| **Argo CD** | GitOps controller — watches this Git repo and syncs all resources |
| **Crossplane** | Infrastructure-as-code inside Kubernetes — provisions Azure resources |
| **ingress-nginx** | Ingress controller — routes external HTTP traffic to services |
| **Harbor** | Container registry with Docker Hub proxy-cache |
| **Dashboard App** | Flask web app showing database connectivity status |
| **Azure PostgreSQL** | Managed Flexible Server provisioned by Crossplane |

---

## How It Is Deployed

Everything is deployed by running a single script from WSL:

```
./scripts/infra-setup.sh
```

The script performs these steps:

1. Creates an Azure Resource Group and AKS cluster
2. Installs Argo CD and Crossplane via Helm
3. Configures GitHub credentials for Argo CD
4. Installs Crossplane Azure providers with Workload Identity
5. Applies the PostgreSQL XRD (custom API) and Composition
6. Creates Azure Container Registry (ACR) and attaches to AKS
7. Builds and pushes the dashboard Docker image to ACR
8. Creates the PostgreSQL admin password secret
9. Applies the Argo CD root Application — this triggers the GitOps cascade
10. Waits for platform services (Harbor, ingress-nginx) and configures nip.io hostnames
11. Waits for PostgreSQL Flexible Server to provision (~5-10 min)
12. Creates connection secret in dashboard namespace (workaround for Crossplane v2)
13. Configures Harbor proxy-cache for Docker Hub

After the script completes, the dashboard should show a successful database connection.

---

## Role of Each Component

### Argo CD — GitOps Continuous Delivery

Argo CD watches this Git repository and **automatically syncs** Kubernetes resources to match what's in Git. If someone manually changes something in the cluster, Argo CD detects the drift and reverts it (self-heal).

It uses the **App-of-Apps** pattern:
- A single **root Application** points to `bootstrap/sets/`
- Inside that folder, **ApplicationSets** auto-discover and deploy:
  - `infrastructure/*` — Crossplane providers, XRDs, Compositions
  - `platform/services/*` — Harbor, ingress-nginx (vendored Helm charts)
  - `apps/*` — The dashboard application

### Crossplane — Infrastructure as Code (Inside Kubernetes)

Crossplane extends Kubernetes with **custom resource types** that provision cloud infrastructure. In this project:

- **XRD (XPostgreSQLInstance)** — defines a platform API: "I want a PostgreSQL database with X GB storage and version Y"
- **Composition** — implements that API by creating Azure resources: Resource Group + Flexible Server + Firewall Rule
- **Providers** — Crossplane plugins that know how to talk to Azure APIs
- **Workload Identity** — passwordless authentication from Crossplane pods to Azure

Developers don't need to know Azure — they just create a `PostgreSQLInstance` claim and Crossplane handles the rest.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  WSL (Your Machine)                                                         │
│                                                                             │
│  ./scripts/infra-setup.sh ──► az cli ──► Azure                              │
│  docker build ──► dashboard:latest (local image)                            │
│  docker push  ──► Harbor (in-cluster registry)                              │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ kubectl / helm
               ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Azure Cloud                                                                │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  AKS Cluster (aks-platform-demo)                                      │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Argo CD (namespace: argocd)                                    │  │  │
│  │  │                                                                  │  │  │
│  │  │  Watches GitHub repo ◄──────── Git push triggers sync           │  │  │
│  │  │    │                                                             │  │  │
│  │  │    ├─► root Application                                          │  │  │
│  │  │    │     └─► bootstrap/sets/                                     │  │  │
│  │  │    │           ├─► infrastructure ApplicationSet                 │  │  │
│  │  │    │           ├─► platform-services ApplicationSet              │  │  │
│  │  │    │           └─► applications ApplicationSet                   │  │  │
│  │  │    │                                                             │  │  │
│  │  │    ├─► Syncs infrastructure/* ──► Crossplane providers, XRD,     │  │  │
│  │  │    │                               Composition                   │  │  │
│  │  │    ├─► Syncs platform/services/* ──► Harbor, ingress-nginx       │  │  │
│  │  │    └─► Syncs apps/* ──► Dashboard Helm chart + DB claim          │  │  │
│  │  └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Crossplane (namespace: crossplane-system)                      │  │  │
│  │  │                                                                  │  │  │
│  │  │  Providers: azure-dbforpostgresql, azure-management              │  │  │
│  │  │    │                                                             │  │  │
│  │  │    │  Workload Identity (passwordless)                           │  │  │
│  │  │    ▼                                                             │  │  │
│  │  │  ProviderConfig ──► Azure APIs                                   │  │  │
│  │  │    │                                                             │  │  │
│  │  │    ├─► ResourceGroup (rg-dashboard-db)                           │  │  │
│  │  │    ├─► FlexibleServer (PostgreSQL 16, Standard_B1ms)             │  │  │
│  │  │    └─► FirewallRule (allow all IPs for demo)                     │  │  │
│  │  └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐  │  │
│  │  │  ingress-nginx (namespace: ingress)                              │  │  │
│  │  │                                                                  │  │  │
│  │  │  Azure Load Balancer ◄── External IP (e.g. 40.74.14.21)         │  │  │
│  │  │    │                                                             │  │  │
│  │  │    ├─► argocd.40.74.14.21.nip.io    ──► Argo CD UI              │  │  │
│  │  │    ├─► harbor.40.74.14.21.nip.io    ──► Harbor Registry         │  │  │
│  │  │    └─► dashboard.40.74.14.21.nip.io ──► Dashboard App           │  │  │
│  │  └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                        │  │
│  │  ┌─────────────────────┐    ┌──────────────────────────────────────┐  │  │
│  │  │  Harbor              │    │  Dashboard App                      │  │  │
│  │  │  (namespace: harbor) │    │  (namespace: dashboard)             │  │  │
│  │  │                      │    │                                      │  │  │
│  │  │  - Container registry│    │  Flask + Gunicorn                    │  │  │
│  │  │  - DockerHub proxy   │    │    │                                 │  │  │
│  │  │  - dashboard project │    │    │ DB connection from              │  │  │
│  │  │    (stores app image)│    │    │ Crossplane secret               │  │  │
│  │  └─────────────────────┘    │    ▼                                 │  │  │
│  │                              │  PostgreSQLInstance claim            │  │  │
│  │                              │    └─► connection secret             │  │  │
│  │                              │         (host, port, user, pass)     │  │  │
│  │                              └──────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                              │                               │
│                                              │ Azure API                     │
│                                              ▼                               │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Azure Managed Services                                                │  │
│  │                                                                        │  │
│  │  PostgreSQL Flexible Server (managed by Crossplane)                    │  │
│  │    - SKU: Standard_B1ms (Burstable tier)                               │  │
│  │    - Version: 16.11                                                    │  │
│  │    - Storage: 32 GiB                                                   │  │
│  │    - Location: uksouth (avoids LocationIsOfferRestricted)              │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow: User Request → Dashboard → Database

```
Browser
  │
  │  HTTP GET http://dashboard.<IP>.nip.io
  ▼
Azure Load Balancer (port 80)
  │
  ▼
ingress-nginx controller
  │  routes by hostname
  ▼
Dashboard Service (ClusterIP, port 80 → 8080)
  │
  ▼
Dashboard Pod (Flask/Gunicorn)
  │
  │  psycopg2 connection using env vars from
  │  Crossplane connection secret (dashboard-db-conn)
  ▼
Azure PostgreSQL Flexible Server
  (provisioned by Crossplane, managed by Azure)
```

---

## GitOps Flow: Git Push → Cluster Update

```
Developer pushes to GitHub
  │
  ▼
Argo CD detects new commit (polls every 3 min)
  │
  ▼
Argo CD compares desired state (Git) vs live state (cluster)
  │
  ├─► Infrastructure changes? → re-apply Crossplane XRD/Composition
  ├─► Platform changes?       → re-deploy Harbor/ingress-nginx Helm charts
  └─► App changes?            → re-deploy dashboard Helm chart
        │
        └─► If db-claim.yaml changed → Crossplane updates Azure PostgreSQL
```

---

## Repository Structure

```
crossplane_azure_demo/
├── scripts/
│   └── infra-setup.sh              # One-command bootstrap script
├── bootstrap/
│   ├── root.yaml                    # Argo CD root app (app-of-apps)
│   └── sets/
│       ├── infrastructure.yaml      # Syncs infrastructure/*
│       ├── platform-services.yaml   # Syncs platform/services/*
│       └── applications.yaml        # Syncs apps/*
├── infrastructure/
│   ├── definitions/                 # XRD — platform API for PostgreSQL
│   ├── compositions/                # How XRD maps to Azure resources
│   └── providers/                   # Crossplane Azure providers
├── platform/services/
│   ├── harbor/                      # Container registry (vendored chart)
│   └── ingress/                     # ingress-nginx (vendored chart)
├── apps/dashboard/
│   ├── app.py                       # Flask application
│   ├── Dockerfile                   # Container image build
│   └── helm-chart/                  # Helm chart with DB claim
└── .github/workflows/
    └── ci.yaml                      # CI: lint, validate, build & push
```

---

## Deployment Results

After running `./scripts/infra-setup.sh`, you should see the dashboard displaying:

```
🌍 Global Warning System
Dashboard v1.0

✔ Database connected (PostgreSQL 16.11 on x86_64-pc-linux-gnu)

Host: <server-name>.postgres.database.azure.com:5432
```

### Example Deployment Output

```
── Azure ──────────────────────────────────────────────────────────
  Resource Group : rg-platform-demo
  AKS Cluster    : aks-platform-demo  (region: westeurope)
  ACR            : acrplatformdemo.azurecr.io
  PG Location    : uksouth  (separate from AKS region)
  Managed Identity: crossplane-identity

── Ingress URLs (via nip.io) ─────────────────────────────────────
  Argo CD   : http://argocd.<LB-IP>.nip.io
  Harbor    : http://harbor.<LB-IP>.nip.io  (admin / ChangeMeNow!)
  Dashboard : http://dashboard.<LB-IP>.nip.io

── Verify ─────────────────────────────────────────────────────────
  kubectl get ingress -A                     # Ingress resources
  kubectl get applications -n argocd         # Argo CD apps
  kubectl get providers                      # Crossplane providers
  kubectl get postgresqlinstances -A         # DB claims
  kubectl get pods -n dashboard              # Dashboard app
```

---

## Troubleshooting

### PostgreSQL Location Restrictions

Azure blocks PostgreSQL Flexible Server creation in some regions (e.g., `westeurope`) with error `LocationIsOfferRestricted`. The default `PG_LOCATION` is set to `uksouth` to avoid this.

To change the region:
```bash
PG_LOCATION=swedencentral ./scripts/infra-setup.sh
```

### Connection Secret Not Appearing

Crossplane v2 may not automatically propagate connection secrets from the XR to the claim namespace. The bootstrap script includes a workaround that:

1. Waits for the secret to appear in the `dashboard` namespace
2. If it doesn't appear within 100 seconds, copies it from `crossplane-system`
3. Fixes the username format for Azure Flexible Server (`pgadmin` instead of `pgadmin@servername`)

### Firewall Rule for AKS

The composition includes a firewall rule that allows all IPs (`0.0.0.0` – `255.255.255.255`) for demo purposes. In production, restrict this to your AKS outbound IPs or use Private Endpoints.

### Dashboard Shows "Database unreachable"

Check these in order:

1. **PostgreSQL is ready:**
   ```bash
   kubectl get flexibleserver -o wide
   ```

2. **Connection secret exists:**
   ```bash
   kubectl get secret dashboard-db-conn -n dashboard
   ```

3. **Secret has correct keys:**
   ```bash
   kubectl get secret dashboard-db-conn -n dashboard -o jsonpath='{.data}' | base64 -d
   ```

4. **Firewall allows AKS:**
   ```bash
   kubectl get flexibleserverfirewallrule
   ```

5. **Restart dashboard to pick up new secret:**
   ```bash
   kubectl rollout restart deployment -n dashboard
   ```
