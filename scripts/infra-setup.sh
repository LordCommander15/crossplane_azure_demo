#!/usr/bin/env bash
###############################################################################
# infra-setup.sh  (idempotent — safe to re-run)
#
# Bootstraps the entire platform end-to-end:
#   1. Azure Resource Group + AKS cluster (1×B2s, OIDC + Workload Identity)
#   2. Argo CD  (Helm)
#   3. Crossplane (Helm)
#   4. GitHub repo credentials for Argo CD
#   5. Crossplane providers + Azure ProviderConfig (Service Principal)
#   6. XRD + Composition (kubectl apply)
#   7. Argo CD root Application (app-of-apps bootstrap)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

#─── Configurable defaults ────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-platform-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-platform-demo}"
LOCATION="${LOCATION:-westeurope}"
K8S_VERSION="${K8S_VERSION:-1.34.2}"
NODE_COUNT=1
NODE_VM_SIZE="Standard_B2s"
#──────────────────────────────────────────────────────────────────────────────

info()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
error() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

###############################################################################
# Pre-flight checks
###############################################################################
for cmd in az kubectl helm; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is required but not found in PATH."
done

###############################################################################
# 1. Azure Resource Group
###############################################################################
info "Creating Resource Group: $RESOURCE_GROUP ($LOCATION)"
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

###############################################################################
# 2. AKS Cluster (idempotent — skips if already exists)
###############################################################################
if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" &>/dev/null; then
  info "AKS cluster $CLUSTER_NAME already exists — skipping creation"
else
  info "Creating AKS cluster: $CLUSTER_NAME (${NODE_COUNT}× ${NODE_VM_SIZE})"
  az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CLUSTER_NAME" \
    --location "$LOCATION" \
    --kubernetes-version "$K8S_VERSION" \
    --node-count "$NODE_COUNT" \
    --node-vm-size "$NODE_VM_SIZE" \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --generate-ssh-keys \
    --output none
fi

info "Fetching kubeconfig"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --overwrite-existing

###############################################################################
# 3. Install Argo CD (Helm)
###############################################################################
info "Installing Argo CD"
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

kubectl create namespace argocd 2>/dev/null || true

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set 'configs.params.server\.insecure=true' \
  --wait --timeout 5m

###############################################################################
# 4. Install Crossplane (Helm)
###############################################################################
info "Installing Crossplane"
helm repo add crossplane-stable https://charts.crossplane.io/stable 2>/dev/null || true
helm repo update crossplane-stable

kubectl create namespace crossplane-system 2>/dev/null || true

helm upgrade --install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --wait --timeout 5m

###############################################################################
# 5. GitHub Repo Credentials for Argo CD
###############################################################################
info "Configuring Argo CD repository credentials"

if kubectl get secret argocd-repo-creds -n argocd &>/dev/null; then
  info "Argo CD repo credentials already exist — skipping"
else
  read -rp "Enter your GitHub Repo URL (e.g. https://github.com/org/repo.git): " GITHUB_REPO_URL
  [[ -z "$GITHUB_REPO_URL" ]] && error "Repo URL cannot be empty."

  read -rsp "Enter your GitHub Personal Access Token (PAT): " GITHUB_PAT
  echo
  [[ -z "$GITHUB_PAT" ]] && error "PAT cannot be empty."

  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
type: Opaque
stringData:
  type: git
  url: "${GITHUB_REPO_URL}"
  username: git
  password: "${GITHUB_PAT}"
EOF
fi

###############################################################################
# 6. Crossplane Providers + Function
###############################################################################
info "Installing Crossplane providers and functions"

kubectl apply -f - <<'EOF'
apiVersion: pkg.crossplane.io/v1beta1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-patch-and-transform:v0.7.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-dbforpostgresql
spec:
  package: xpkg.upbound.io/upbound/provider-azure-dbforpostgresql:v1.10.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-azure-management
spec:
  package: xpkg.upbound.io/upbound/provider-azure-management:v1.10.0
EOF

info "Waiting for providers to become healthy (up to 5 min)..."
# Wait for each provider individually — avoids hanging on stale/deleted providers
for p in function-patch-and-transform provider-azure-dbforpostgresql provider-azure-management; do
  if kubectl get provider "$p" &>/dev/null; then
    info "  Waiting for $p..."
    kubectl wait "provider/$p" --for=condition=Healthy --timeout=300s || \
      warn "Provider $p did not become healthy in time — check: kubectl describe provider $p"
  fi
done
# The family provider is auto-installed as a dependency; wait for it too
if kubectl get provider upbound-provider-family-azure &>/dev/null; then
  info "  Waiting for upbound-provider-family-azure..."
  kubectl wait "provider/upbound-provider-family-azure" --for=condition=Healthy --timeout=300s || true
fi

###############################################################################
# 7. Azure Service Principal + ProviderConfig
###############################################################################
info "Configuring Azure credentials for Crossplane"

if kubectl get secret azure-creds -n crossplane-system &>/dev/null; then
  info "Azure credentials secret already exists — skipping SP creation"
else
  SUBSCRIPTION_ID=$(az account show --query id -o tsv)

  info "Creating Service Principal: crossplane-sp"
  SP_OUTPUT=$(az ad sp create-for-rbac \
    --name crossplane-sp \
    --role Contributor \
    --scopes "/subscriptions/${SUBSCRIPTION_ID}" \
    -o json 2>/dev/null) || {
      # SP may already exist — try to reset its password
      warn "SP may already exist, resetting credentials"
      APP_ID=$(az ad sp list --display-name crossplane-sp --query '[0].appId' -o tsv)
      SP_OUTPUT=$(az ad sp credential reset --id "$APP_ID" -o json)
    }

  kubectl create secret generic azure-creds \
    -n crossplane-system \
    --from-literal=credentials="$SP_OUTPUT"
fi

kubectl apply -f - <<'EOF'
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: azure-creds
      key: credentials
EOF

###############################################################################
# 8. Apply XRD + Composition
###############################################################################
info "Applying Crossplane XRD and Composition"
kubectl apply -f "$REPO_ROOT/infrastructure/definitions/"
kubectl apply -f "$REPO_ROOT/infrastructure/compositions/"

###############################################################################
# 9. Bootstrap Argo CD — root Application (app-of-apps)
###############################################################################
info "Applying Argo CD root Application"
kubectl apply -f "$REPO_ROOT/bootstrap/root.yaml"

###############################################################################
# Done
###############################################################################
info "Platform bootstrap complete!"
echo ""
echo "  To reconnect later, run:"
echo "    az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME"
echo ""
echo "  Argo CD initial admin password:"
echo "    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "  Port-forward to Argo CD UI:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    Open https://localhost:8080"
echo ""
