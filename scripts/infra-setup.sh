#!/usr/bin/env bash
###############################################################################
# infra-setup.sh
#
# Bootstraps the entire platform:
#   1. Azure Resource Group + AKS cluster (1×B2s, OIDC + Workload Identity)
#   2. Argo CD  (Helm)
#   3. Crossplane (Helm)
#   4. GitHub repo credentials for Argo CD
###############################################################################
set -euo pipefail

#─── Configurable defaults ────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-platform-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-platform-demo}"
LOCATION="${LOCATION:-westeurope}"
K8S_VERSION="${K8S_VERSION:-1.30}"
NODE_COUNT=1
NODE_VM_SIZE="Standard_B2s"
#──────────────────────────────────────────────────────────────────────────────

info()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
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
# 2. AKS Cluster
###############################################################################
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
echo "  Next step: apply the root bootstrap Application:"
echo "    kubectl apply -f bootstrap/root.yaml"
echo ""
