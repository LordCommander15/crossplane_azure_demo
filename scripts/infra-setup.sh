#!/usr/bin/env bash
###############################################################################
# infra-setup.sh  (idempotent — safe to re-run)
#
# Bootstraps the entire platform end-to-end:
#    1. Azure Resource Group + AKS cluster
#    2. Argo CD  (Helm)
#    3. Crossplane (Helm)
#    4. GitHub repo credentials for Argo CD
#    5. Crossplane providers + functions
#    6. Azure Workload Identity + ProviderConfig
#    7. XRD + Composition (kubectl apply)
#    8. Argo CD root Application (app-of-apps bootstrap)
#    9. Azure Container Registry (ACR) — create + attach to AKS
#   10. PostgreSQL admin password secret
#   11. Wait for platform services (Harbor, ingress-nginx)
#   12. Configure Harbor proxy-cache project
#   13. Build & push dashboard image to ACR
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

#─── Configurable defaults ────────────────────────────────────────────────────
RESOURCE_GROUP="${RESOURCE_GROUP:-rg-platform-demo}"
CLUSTER_NAME="${CLUSTER_NAME:-aks-platform-demo}"
LOCATION="${LOCATION:-westeurope}"
K8S_VERSION="${K8S_VERSION:-1.34.2}"
NODE_COUNT="${NODE_COUNT:-1}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_B2s}"
ACR_NAME="${ACR_NAME:-acrplatformdemo}"
HARBOR_ADMIN_PASS="${HARBOR_ADMIN_PASS:-ChangeMeNow!}"
HARBOR_PF_PORT=8880
#──────────────────────────────────────────────────────────────────────────────

info()  { printf '\n\033[1;34m>>> %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARN: %s\033[0m\n' "$*"; }
error() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Cleanup function for background processes
cleanup() {
  [[ -n "${HARBOR_PF_PID:-}" ]] && kill "$HARBOR_PF_PID" 2>/dev/null || true
}
trap cleanup EXIT

###############################################################################
# Pre-flight checks
###############################################################################
for cmd in az kubectl helm; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is required but not found in PATH."
done

# Verify Azure login
az account show &>/dev/null || error "Not logged in to Azure. Run 'az login' first."

# Docker is optional — needed only for building & pushing the dashboard image
HAS_DOCKER=false
if command -v docker &>/dev/null; then
  HAS_DOCKER=true
else
  warn "'docker' not found — dashboard image build & push will be skipped."
  warn "Install Docker and re-run, or push the image manually."
fi

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
  --set 'server.ingress.enabled=true' \
  --set 'server.ingress.ingressClassName=nginx' \
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
# 7. Azure Workload Identity + ProviderConfig
###############################################################################
info "Configuring Azure Workload Identity for Crossplane"

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
IDENTITY_NAME="crossplane-identity"

# Check if managed identity already exists
if az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  info "Managed Identity '$IDENTITY_NAME' already exists"
else
  info "Creating Managed Identity: $IDENTITY_NAME"
  az identity create \
    --name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
fi

# Get identity details
IDENTITY_CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$RESOURCE_GROUP" --query principalId -o tsv)

info "Managed Identity Client ID: $IDENTITY_CLIENT_ID"

# Assign Contributor role to the managed identity (idempotent)
info "Assigning Contributor role to Managed Identity"
# Check if role already assigned
if ! az role assignment list \
  --assignee "$IDENTITY_PRINCIPAL_ID" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}" \
  --role "Contributor" \
  --query "[0].id" -o tsv &>/dev/null; then
  
  info "Waiting for identity propagation (15 seconds)..."
  sleep 15
  
  az role assignment create \
    --assignee "$IDENTITY_PRINCIPAL_ID" \
    --role "Contributor" \
    --scope "/subscriptions/${SUBSCRIPTION_ID}" \
    --output none || warn "Role assignment may already exist"
else
  info "Contributor role already assigned"
fi

# Get OIDC issuer URL from AKS
info "Retrieving OIDC issuer URL from AKS"
OIDC_ISSUER=$(az aks show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_NAME" \
  --query "oidcIssuerProfile.issuerUrl" -o tsv)

[[ -z "$OIDC_ISSUER" ]] && error "OIDC issuer not found. Ensure AKS was created with --enable-oidc-issuer"

info "OIDC Issuer: $OIDC_ISSUER"

# Wait for provider service accounts to be created and discover their actual names
# (Crossplane adds a revision hash suffix to SA names, e.g. provider-azure-dbforpostgresql-<hash>)
info "Waiting for Crossplane provider service accounts to be created (may take 2-3 minutes)"
declare -a DISCOVERED_SAS=()
for i in {1..120}; do
  mapfile -t DISCOVERED_SAS < <(
    kubectl get sa -n crossplane-system --no-headers -o custom-columns=":metadata.name" 2>/dev/null \
      | grep -E "^(provider-azure-dbforpostgresql|provider-azure-management|upbound-provider-family-azure)-"
  )

  if [[ ${#DISCOVERED_SAS[@]} -ge 2 ]]; then
    info "Discovered ${#DISCOVERED_SAS[@]} provider service account(s):"
    for sa in "${DISCOVERED_SAS[@]}"; do
      echo "    $sa"
    done
    break
  fi

  if [[ $((i % 10)) -eq 0 ]]; then
    echo "  Still waiting... ($i/120 seconds)"
  fi
  sleep 1
done

if [[ ${#DISCOVERED_SAS[@]} -lt 2 ]]; then
  error "Timed out waiting for provider service accounts. Check: kubectl get sa -n crossplane-system"
fi

# Give providers a moment to fully initialize
sleep 5

# Create federated identity credentials using the actual SA names (with hash suffix)
info "Creating federated identity credentials for Crossplane providers"

for PROVIDER_SA in "${DISCOVERED_SAS[@]}"; do
  FED_CRED_NAME="fed-${PROVIDER_SA}"
  # Azure federated credential names are limited to 120 characters
  FED_CRED_NAME="${FED_CRED_NAME:0:120}"

  if az identity federated-credential show \
    --name "$FED_CRED_NAME" \
    --identity-name "$IDENTITY_NAME" \
    --resource-group "$RESOURCE_GROUP" &>/dev/null; then
    info "  Federated credential for $PROVIDER_SA already exists"
  else
    info "  Creating federated credential for $PROVIDER_SA"
    az identity federated-credential create \
      --name "$FED_CRED_NAME" \
      --identity-name "$IDENTITY_NAME" \
      --resource-group "$RESOURCE_GROUP" \
      --issuer "$OIDC_ISSUER" \
      --subject "system:serviceaccount:crossplane-system:${PROVIDER_SA}" \
      --audience api://AzureADTokenExchange \
      --output none
  fi
done

# Annotate service accounts with the managed identity client ID
info "Annotating Crossplane provider service accounts with Workload Identity"
for PROVIDER_SA in "${DISCOVERED_SAS[@]}"; do
  info "  Configuring $PROVIDER_SA"
  kubectl annotate serviceaccount "$PROVIDER_SA" \
    -n crossplane-system \
    azure.workload.identity/client-id="$IDENTITY_CLIENT_ID" \
    azure.workload.identity/tenant-id="$TENANT_ID" \
    --overwrite

  kubectl label serviceaccount "$PROVIDER_SA" \
    -n crossplane-system \
    azure.workload.identity/use=true \
    --overwrite
done

# Add Workload Identity pod label to provider deployments so the AKS
# mutating webhook injects the OIDC projected token volume.
# (The webhook filters on pod label azure.workload.identity/use=true)
info "Adding Workload Identity pod label to provider deployments"
for PROVIDER_SA in "${DISCOVERED_SAS[@]}"; do
  DEP_NAME="$PROVIDER_SA"   # deployment name matches SA name
  if kubectl get deployment "$DEP_NAME" -n crossplane-system &>/dev/null; then
    kubectl patch deployment "$DEP_NAME" -n crossplane-system --type=merge \
      -p '{"spec":{"template":{"metadata":{"labels":{"azure.workload.identity/use":"true"}}}}}' 2>/dev/null || true
    info "  Patched deployment $DEP_NAME"
  fi
done

# Restart provider pods to pick up the new service account annotations + pod labels
info "Restarting provider pods to apply Workload Identity configuration"
kubectl delete pods -n crossplane-system -l pkg.crossplane.io/provider --wait=false 2>/dev/null || true

# Apply ProviderConfig - OIDCTokenFile tells the provider to use Workload Identity
info "Applying ProviderConfig for Workload Identity"
kubectl apply -f - <<EOF
apiVersion: azure.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: OIDCTokenFile
  subscriptionID: "${SUBSCRIPTION_ID}"
  tenantID: "${TENANT_ID}"
  clientID: "${IDENTITY_CLIENT_ID}"
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
# 9. Azure Container Registry (ACR)
###############################################################################
info "Setting up Azure Container Registry: $ACR_NAME"
if az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" &>/dev/null; then
  info "ACR $ACR_NAME already exists — skipping creation"
else
  az acr create \
    --name "$ACR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --sku Basic \
    --location "$LOCATION" \
    --output none
fi

ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --query loginServer -o tsv)
info "ACR login server: $ACR_LOGIN_SERVER"

# Attach ACR to AKS (grants AcrPull role to kubelet identity — idempotent)
info "Attaching ACR to AKS cluster"
az aks update \
  --name "$CLUSTER_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --attach-acr "$ACR_NAME" \
  --output none 2>/dev/null || info "ACR already attached"

###############################################################################
# 10. Create PostgreSQL admin password secret
###############################################################################
info "Creating PostgreSQL admin password secret"
if kubectl get secret dashboard-db-pg-password -n crossplane-system &>/dev/null; then
  info "Secret dashboard-db-pg-password already exists — skipping"
else
  PG_PASSWORD=$(openssl rand -base64 24)
  kubectl create secret generic dashboard-db-pg-password \
    --namespace crossplane-system \
    --from-literal=password="$PG_PASSWORD"
  info "PostgreSQL password stored in secret dashboard-db-pg-password"
fi

###############################################################################
# 11. Wait for platform services (Harbor, ingress-nginx)
###############################################################################
info "Waiting for Argo CD to sync platform services (this may take 3-5 minutes)..."

# Wait for the namespaces to be created by Argo CD
for ns in harbor ingress dashboard; do
  info "  Waiting for namespace '$ns'..."
  for i in {1..120}; do
    kubectl get namespace "$ns" &>/dev/null && break
    [[ $((i % 15)) -eq 0 ]] && echo "    Still waiting for namespace $ns... ($i/120s)"
    sleep 1
  done
done

# Wait for Harbor pods to be ready
info "Waiting for Harbor to be ready (may take 3-5 minutes)..."
for i in {1..300}; do
  READY_PODS=$(kubectl get pods -n harbor --no-headers 2>/dev/null \
    | grep -c "Running" || true)
  if [[ $READY_PODS -ge 5 ]]; then
    info "Harbor is running ($READY_PODS pods ready)"
    break
  fi
  if [[ $((i % 30)) -eq 0 ]]; then
    echo "    Harbor pods ready: $READY_PODS (waiting... $i/300s)"
  fi
  sleep 1
done

# Wait for ingress-nginx
info "Waiting for ingress-nginx controller..."
kubectl wait --for=condition=Available deployment -l app.kubernetes.io/name=ingress-nginx \
  -n ingress --timeout=180s 2>/dev/null || \
  warn "ingress-nginx not ready yet — it will continue syncing in the background"

# Discover the LoadBalancer external IP for nip.io hostnames
info "Waiting for ingress-nginx LoadBalancer external IP..."
LB_IP=""
for i in {1..120}; do
  LB_IP=$(kubectl get svc -n ingress -l app.kubernetes.io/name=ingress-nginx \
    -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [[ -n "$LB_IP" ]] && break
  [[ $((i % 15)) -eq 0 ]] && echo "    Still waiting for external IP... ($i/120s)"
  sleep 1
done

if [[ -n "$LB_IP" ]]; then
  info "LoadBalancer IP: $LB_IP"
  ARGOCD_HOST="argocd.${LB_IP}.nip.io"
  HARBOR_HOST="harbor.${LB_IP}.nip.io"
  DASHBOARD_HOST="dashboard.${LB_IP}.nip.io"

  # Update Argo CD ingress with the discovered hostname
  info "Configuring Argo CD ingress: $ARGOCD_HOST"
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --set 'configs.params.server\.insecure=true' \
    --set 'server.ingress.enabled=true' \
    --set 'server.ingress.ingressClassName=nginx' \
    --set "server.ingress.hostname=${ARGOCD_HOST}" \
    --wait --timeout 5m

  # Update Harbor and dashboard values with the real IP
  info "Updating Harbor and dashboard values with nip.io hostnames"
  sed -i "s|core: harbor\..*\.nip\.io|core: ${HARBOR_HOST}|" \
    "$REPO_ROOT/platform/services/harbor/values.yaml"
  sed -i "s|externalURL: http://harbor\..*\.nip\.io|externalURL: http://${HARBOR_HOST}|" \
    "$REPO_ROOT/platform/services/harbor/values.yaml"
  sed -i "s|host: dashboard\..*\.nip\.io|host: ${DASHBOARD_HOST}|" \
    "$REPO_ROOT/apps/dashboard/helm-chart/values.yaml"

  # Commit + push updated hostnames so Argo CD picks them up
  info "Committing updated nip.io hostnames to Git"
  git -C "$REPO_ROOT" add -A
  git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null || \
    git -C "$REPO_ROOT" commit -m "auto: update nip.io hostnames to ${LB_IP}" --quiet
  git -C "$REPO_ROOT" push --quiet 2>/dev/null || warn "Git push failed — push manually after script completes"

  # Force Argo CD to re-sync Harbor and Dashboard with updated hostnames
  info "Syncing Argo CD apps with updated hostnames"
  kubectl patch application platform-harbor -n argocd --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || true
  kubectl patch application app-dashboard -n argocd --type merge \
    -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' 2>/dev/null || true
  sleep 10  # give Argo CD a moment to pick up the sync
else
  warn "Could not discover LoadBalancer IP — ingress hostnames not configured."
  warn "Run: kubectl get svc -n ingress  to find the IP, then update values manually."
fi

###############################################################################
# 12. Configure Harbor proxy-cache project
###############################################################################
info "Setting up Harbor proxy-cache for Docker Hub"

# Port-forward Harbor service in background
kubectl port-forward svc/harbor -n harbor "${HARBOR_PF_PORT}:80" &>/dev/null &
HARBOR_PF_PID=$!
sleep 5

# Wait for Harbor API to respond
HARBOR_API="http://localhost:${HARBOR_PF_PORT}/api/v2.0"
HARBOR_UP=false
for i in {1..30}; do
  if curl -sf "${HARBOR_API}/health" &>/dev/null; then
    HARBOR_UP=true
    break
  fi
  sleep 2
done

if $HARBOR_UP; then
  info "Harbor API is accessible"

  # Create Docker Hub registry endpoint
  if curl -sf -u "admin:${HARBOR_ADMIN_PASS}" "${HARBOR_API}/registries" \
    | grep -q '"name":"dockerhub"'; then
    info "  Docker Hub registry endpoint already exists"
  else
    info "  Creating Docker Hub registry endpoint"
    curl -sf -u "admin:${HARBOR_ADMIN_PASS}" \
      -X POST "${HARBOR_API}/registries" \
      -H "Content-Type: application/json" \
      -d '{"name":"dockerhub","type":"docker-hub","url":"https://hub.docker.com"}' \
      || warn "Failed to create Docker Hub registry endpoint"
  fi

  # Get registry ID
  REGISTRY_ID=$(curl -sf -u "admin:${HARBOR_ADMIN_PASS}" "${HARBOR_API}/registries" \
    | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "1")

  # Create proxy-cache project
  if curl -sf -u "admin:${HARBOR_ADMIN_PASS}" "${HARBOR_API}/projects?name=dockerhub-proxy" \
    | grep -q '"name":"dockerhub-proxy"'; then
    info "  Proxy-cache project 'dockerhub-proxy' already exists"
  else
    info "  Creating proxy-cache project 'dockerhub-proxy'"
    curl -sf -u "admin:${HARBOR_ADMIN_PASS}" \
      -X POST "${HARBOR_API}/projects" \
      -H "Content-Type: application/json" \
      -d "{\"project_name\":\"dockerhub-proxy\",\"registry_id\":${REGISTRY_ID},\"metadata\":{\"public\":\"true\"}}" \
      || warn "Failed to create proxy-cache project"
  fi

  # Create a local 'dashboard' project for direct pushes
  if curl -sf -u "admin:${HARBOR_ADMIN_PASS}" "${HARBOR_API}/projects?name=dashboard" \
    | grep -q '"name":"dashboard"'; then
    info "  Local project 'dashboard' already exists"
  else
    info "  Creating local project 'dashboard'"
    curl -sf -u "admin:${HARBOR_ADMIN_PASS}" \
      -X POST "${HARBOR_API}/projects" \
      -H "Content-Type: application/json" \
      -d '{"project_name":"dashboard","metadata":{"public":"true"}}' \
      || warn "Failed to create local project"
  fi
else
  warn "Harbor API not reachable — proxy-cache setup skipped. Configure manually later."
fi

###############################################################################
# 13. Build & push dashboard image to ACR
###############################################################################
if $HAS_DOCKER; then
  IMAGE_TAG="$(date +%Y%m%d)-$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)"
  ACR_IMAGE="${ACR_LOGIN_SERVER}/dashboard/dashboard"

  info "Logging in to ACR"
  az acr login --name "$ACR_NAME" 2>/dev/null || warn "ACR login failed — image push will be skipped"

  info "Building dashboard image"
  docker build \
    -t "${ACR_IMAGE}:${IMAGE_TAG}" \
    -t "${ACR_IMAGE}:latest" \
    "$REPO_ROOT/apps/dashboard"

  info "Pushing dashboard image to ACR"
  docker push "${ACR_IMAGE}:${IMAGE_TAG}" || warn "Push of tag ${IMAGE_TAG} failed"
  docker push "${ACR_IMAGE}:latest" || warn "Push of tag latest failed"

  info "Image pushed to ACR:"
  echo "    ${ACR_IMAGE}:${IMAGE_TAG}"
  echo "    ${ACR_IMAGE}:latest"
else
  warn "Docker not available — skipping image build."
  warn "Build and push manually:"
  warn "  az acr login --name $ACR_NAME"
  warn "  docker build -t ${ACR_LOGIN_SERVER:-acrplatformdemo.azurecr.io}/dashboard/dashboard:latest apps/dashboard/"
  warn "  docker push ${ACR_LOGIN_SERVER:-acrplatformdemo.azurecr.io}/dashboard/dashboard:latest"
fi

# Clean up port-forward
[[ -n "${HARBOR_PF_PID:-}" ]] && kill "$HARBOR_PF_PID" 2>/dev/null || true
unset HARBOR_PF_PID

###############################################################################
# Done
###############################################################################
info "Platform bootstrap complete!"
echo ""
echo "  ── Azure ──────────────────────────────────────────────────────────"
echo "    Resource Group : $RESOURCE_GROUP"
echo "    AKS Cluster    : $CLUSTER_NAME"
echo "    ACR            : ${ACR_LOGIN_SERVER:-$ACR_NAME}"
echo "    Managed Identity: $IDENTITY_NAME (Client ID: $IDENTITY_CLIENT_ID)"
echo ""
echo "  ── Reconnect ────────────────────────────────────────────────────"
echo "    az aks get-credentials --resource-group $RESOURCE_GROUP --name $CLUSTER_NAME"
echo ""
if [[ -n "${LB_IP:-}" ]]; then
echo "  ── Ingress URLs (via nip.io) ─────────────────────────────────────"
echo "    Argo CD   : http://${ARGOCD_HOST}"
echo "    Harbor    : http://${HARBOR_HOST}  (admin / ${HARBOR_ADMIN_PASS})"
echo "    Dashboard : http://${DASHBOARD_HOST}"
echo ""
fi
echo "  ── Argo CD ──────────────────────────────────────────────────────"
echo "    Admin password:"
echo "      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "  ── Verify ─────────────────────────────────────────────────────────"
echo "    kubectl get ingress -A                     # Ingress resources"
echo "    kubectl get applications -n argocd         # Argo CD apps"
echo "    kubectl get providers                      # Crossplane providers"
echo "    kubectl get postgresqlinstances -A         # DB claims"
echo "    kubectl get pods -n dashboard              # Dashboard app"
echo "    kubectl get pods -n harbor                 # Harbor"
echo "    kubectl get pods -n ingress                # Ingress controller"
echo ""
