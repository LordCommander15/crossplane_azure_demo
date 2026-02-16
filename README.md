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
6. Applies the Argo CD root Application — this triggers the GitOps cascade
7. Creates the PostgreSQL admin password secret
8. Waits for platform services and configures Harbor
9. Builds the dashboard Docker image locally

After the script, you push the image to Harbor and Argo CD handles the rest.

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
│  │  │    └─► FirewallRule (allow Azure services)                       │  │  │
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
│  │    - SKU: Standard_B1ms                                                │  │
│  │    - Version: 16                                                       │  │
│  │    - Storage: 32 GiB                                                   │  │
│  │    - Location: westeurope                                              │  │
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
