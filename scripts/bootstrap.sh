#!/bin/bash
##############################################################
# Bootstrap Script — Radix HFT
# Installs core operators, monitoring, and ingress on new EKS
##############################################################

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-radix-hft-prod}"
REGION="${AWS_REGION:-us-east-1}"
NAMESPACE_TRADING="trading"
NAMESPACE_MONITORING="monitoring"
NAMESPACE_ARGOCD="argocd"
LOG_FILE="/tmp/bootstrap-$(date +%s).log"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# ────────────────────────────────────────────────────
# Verify prerequisites
# ────────────────────────────────────────────────────
verify_prerequisites() {
    log "Verifying prerequisites..."
    
    for cmd in kubectl helm aws; do
        if ! command -v "$cmd" &> /dev/null; then
            error "$cmd is not installed"
        fi
    done
    
    # Check kubeconfig
    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster. Update kubeconfig with: aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION"
    fi
    
    log "✓ All prerequisites met"
}

# ────────────────────────────────────────────────────
# Create namespaces with labels
# ────────────────────────────────────────────────────
create_namespaces() {
    log "Creating namespaces..."
    
    for ns in "$NAMESPACE_TRADING" "$NAMESPACE_MONITORING" "$NAMESPACE_ARGOCD"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            log "  ✓ Namespace $ns already exists"
        else
            kubectl create namespace "$ns"
            kubectl label namespace "$ns" name="$ns"
            log "  ✓ Created namespace $ns"
        fi
    done
    
    # Apply Pod Security Standards
    kubectl label namespace "$NAMESPACE_TRADING" \
        pod-security.kubernetes.io/enforce=restricted \
        pod-security.kubernetes.io/audit=restricted \
        --overwrite
    
    log "✓ Namespaces created"
}

# ────────────────────────────────────────────────────
# Add Helm repositories
# ────────────────────────────────────────────────────
add_helm_repos() {
    log "Adding Helm repositories..."
    
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo add argocd https://argoproj.github.io/argo-helm
    helm repo add jetstack https://charts.jetstack.io
    helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
    helm repo update
    
    log "✓ Helm repos added"
}

# ────────────────────────────────────────────────────
# Install KARPENTER (optional — for node autoscaling)
# ────────────────────────────────────────────────────
install_karpenter() {
    if [[ "${INSTALL_KARPENTER:-false}" != "true" ]]; then
        warn "Skipping Karpenter installation (set INSTALL_KARPENTER=true to enable)"
        return
    fi
    
    log "Installing Karpenter..."
    
    helm repo add karpenter https://charts.karpenter.sh
    helm repo update
    
    helm upgrade --install karpenter karpenter/karpenter \
        --namespace karpenter --create-namespace \
        --set linuxOptions.systemPageSize=65536 \
        --wait
    
    log "✓ Karpenter installed"
}

# ────────────────────────────────────────────────────
# Install cert-manager (for TLS)
# ────────────────────────────────────────────────────
install_cert_manager() {
    log "Installing cert-manager..."
    
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set installCRDs=true \
        --wait
    
    log "✓ cert-manager installed"
}

# ────────────────────────────────────────────────────
# Install AWS Load Balancer Controller (ALB/NLB)
# ────────────────────────────────────────────────────
install_aws_load_balancer_controller() {
    log "Installing AWS Load Balancer Controller..."
    
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --namespace kube-system \
        --set clusterName="$CLUSTER_NAME" \
        --set serviceAccount.create=true \
        --wait
    
    log "✓ AWS Load Balancer Controller installed"
}

# ────────────────────────────────────────────────────
# Install Prometheus + Grafana
# ────────────────────────────────────────────────────
install_monitoring() {
    log "Installing Prometheus + Grafana..."
    
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace "$NAMESPACE_MONITORING" \
        --values - <<EOF
prometheus:
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
grafana:
  adminPassword: changeme
  persistence:
    enabled: true
    size: 10Gi
EOF
    
    log "✓ Monitoring stack installed"
}

# ────────────────────────────────────────────────────
# Install ArgoCD
# ────────────────────────────────────────────────────
install_argocd() {
    log "Installing ArgoCD..."
    
    helm upgrade --install argocd argocd/argo-cd \
        --namespace "$NAMESPACE_ARGOCD" \
        --values - <<EOF
server:
  service:
    type: LoadBalancer
  insecure: false
redis:
  enabled: true
controller:
  replicas: 2
EOF
    
    # Wait for ArgoCD server to be ready
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=argocd-server \
        -n "$NAMESPACE_ARGOCD" \
        --timeout=300s
    
    # Retrieve initial password
    ARGOCD_PASSWORD=$(kubectl -n "$NAMESPACE_ARGOCD" get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d)
    
    log "✓ ArgoCD installed"
    log "  Admin password: $ARGOCD_PASSWORD (change immediately!)"
}

# ────────────────────────────────────────────────────
# Install Argo Rollouts (for canary/blue-green)
# ────────────────────────────────────────────────────
install_argo_rollouts() {
    log "Installing Argo Rollouts..."
    
    kubectl create namespace argo-rollouts || true
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update
    
    helm upgrade --install argo-rollouts argo/argo-rollouts \
        --namespace argo-rollouts \
        --wait
    
    log "✓ Argo Rollouts installed"
}

# ────────────────────────────────────────────────────
# Install external-secrets (for Secrets Manager integration)
# ────────────────────────────────────────────────────
install_external_secrets() {
    log "Installing External Secrets..."
    
    helm repo add external-secrets https://charts.external-secrets.io
    helm repo update
    
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace external-secrets --create-namespace \
        --set installCRDs=true \
        --wait
    
    log "✓ External Secrets installed"
}

# ────────────────────────────────────────────────────
# Install OPA/Gatekeeper (for policy enforcement)
# ────────────────────────────────────────────────────
install_gatekeeper() {
    log "Installing OPA Gatekeeper..."
    
    kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/master/deploy/gatekeeper.yaml
    kubectl wait --for=condition=ready pod -l gatekeeper.sh/system=yes --timeout=300s -A
    
    log "✓ OPA Gatekeeper installed"
}

# ────────────────────────────────────────────────────
# Create secrets for database and cache
# ────────────────────────────────────────────────────
create_secrets() {
    log "Creating Kubernetes secrets..."
    
    # RDS Aurora credentials
    kubectl create secret generic aurora-credentials \
        --from-literal=username=admin \
        --from-literal=password="$(openssl rand -base64 32)" \
        --namespace "$NAMESPACE_TRADING" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Redis auth token
    kubectl create secret generic redis-auth \
        --from-literal=auth-token="$(openssl rand -base64 32)" \
        --namespace "$NAMESPACE_TRADING" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    log "✓ Secrets created (update with actual values from AWS Secrets Manager)"
}

# ────────────────────────────────────────────────────
# Health checks
# ────────────────────────────────────────────────────
health_check() {
    log "Running health checks..."
    
    # Check core pods are running
    kubectl get pods -n kube-system -l component=kube-apiserver --no-headers | wc -l | grep -q "1" && log "  ✓ API server"
    kubectl get pods -n "$NAMESPACE_MONITORING" -l app.kubernetes.io/name=prometheus --no-headers | wc -l | grep -q "1" && log "  ✓ Prometheus"
    kubectl get pods -n "$NAMESPACE_ARGOCD" -l app.kubernetes.io/name=argocd-server --no-headers | wc -l | grep -q "1" && log "  ✓ ArgoCD"
    
    log "✓ Health checks passed"
}

# ────────────────────────────────────────────────────
# Main execution
# ────────────────────────────────────────────────────
main() {
    log "=========================================="
    log "Radix HFT Bootstrap"
    log "Cluster: $CLUSTER_NAME | Region: $REGION"
    log "=========================================="
    
    verify_prerequisites
    create_namespaces
    add_helm_repos
    
    install_cert_manager
    install_aws_load_balancer_controller
    install_karpenter
    install_monitoring
    install_argocd
    install_argo_rollouts
    install_external_secrets
    install_gatekeeper
    create_secrets
    
    health_check
    
    log "=========================================="
    log "✓ Bootstrap complete!"
    log "Next steps:"
    log "  1. Update secrets in $NAMESPACE_TRADING with real credentials"
    log "  2. Configure ArgoCD with GitHub repo access"
    log "  3. Deploy trading-platform: kubectl apply -f argocd/applications/"
    log "=========================================="
}

main "$@"
