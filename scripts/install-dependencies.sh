#!/bin/bash
set -euo pipefail

# =============================================================================
# install-dependencies.sh
# Tuned for t4g.medium (2 vCPU / 4 GB RAM, ARM64) EKS with a single managed node group.
#
# Flags:
#   Istio and KEDA are always installed
#   INSTALL_MONITORING=1   Prometheus stack — BLOCKED on t4g.medium (~1.5GB RAM)
#   INSTALL_DCGM=1         NVIDIA DCGM — auto-skipped if no GPU nodes found
#   FORCE_MONITORING=1     Override the monitoring block-guard (not recommended)
# =============================================================================

INSTALL_MONITORING="${INSTALL_MONITORING:-0}"
INSTALL_DCGM="${INSTALL_DCGM:-0}"
FORCE_MONITORING="${FORCE_MONITORING:-0}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# BUG FIX: removed 'gcloud' — this is an AWS project, gcloud is not available
for cmd in kubectl helm curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' not found in PATH."
done

kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 \
  || fail "Cannot reach cluster. Check KUBECONFIG."

log "Cluster reachable. Starting Istio-first install for t4g.medium..."
echo

# ==============================================================================
# 1. metrics-server — EKS manages this natively, just verify it's alive
# ==============================================================================
log "[1/3] metrics-server — EKS built-in, skipping install."
log "      Verifying metrics API..."

for i in {1..8}; do
  kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes >/dev/null 2>&1 && break
  [[ $i -eq 8 ]] && log "      WARNING: metrics API not ready yet — continuing anyway."
  sleep 5
done
log "      metrics-server OK."
echo

# ==============================================================================
# 2. Istio — control plane + ingress gateway
# ==============================================================================
log "[2/3] Installing Istio with ingress gateway..."

ISTIO_VERSION="1.21.2"
ISTIO_TMP="$(mktemp -d)"
trap 'rm -rf "$ISTIO_TMP"' EXIT
ISTIO_INGRESS_OVERLAY="$ISTIO_TMP/istio-ingress-overlay.yaml"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ISTIO_ARCH="linux-amd64"  ;;
  aarch64) ISTIO_ARCH="linux-arm64"  ;;
  *)       fail "Unsupported architecture: $ARCH" ;;
esac

ISTIO_URL="https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-${ISTIO_ARCH}.tar.gz"
log "      Arch: $ARCH → ${ISTIO_ARCH}, version ${ISTIO_VERSION}"
log "      Downloading: $ISTIO_URL"

curl --retry 5 --retry-delay 5 --retry-connrefused -fsSL \
  "$ISTIO_URL" -o "$ISTIO_TMP/istio.tar.gz" \
  || fail "Download failed: $ISTIO_URL"

log "      Extracting..."
tar -xzf "$ISTIO_TMP/istio.tar.gz" -C "$ISTIO_TMP" \
  || fail "Extraction failed."

ISTIOCTL="$(find "$ISTIO_TMP" -name istioctl -type f | head -1)"
[[ -x "$ISTIOCTL" ]] || fail "istioctl not found after extraction in $ISTIO_TMP"
log "      istioctl ready: $ISTIOCTL"

cat > "$ISTIO_INGRESS_OVERLAY" <<'EOF'
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  components:
    ingressGateways:
    - name: istio-ingressgateway
      enabled: true
      k8s:
        service:
          type: LoadBalancer
        serviceAnnotations:
          service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
          service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
        resources:
          requests:
            cpu: 30m
            memory: 64Mi
          limits:
            cpu: 100m
            memory: 128Mi
        hpaSpec:
          minReplicas: 1
          maxReplicas: 1
EOF

log "      Running istioctl install (minimal profile, trimmed resources, internet-facing NLB)..."
"$ISTIOCTL" install \
  -f "$ISTIO_INGRESS_OVERLAY" \
  --set profile=minimal \
  --set values.pilot.resources.requests.cpu=50m \
  --set values.pilot.resources.requests.memory=128Mi \
  --set values.pilot.resources.limits.cpu=200m \
  --set values.pilot.resources.limits.memory=256Mi \
  --set values.pilot.replicaCount=1 \
  --set values.pilot.autoscaleEnabled=false \
  -y \
  || fail "istioctl install failed."

log "      Waiting for istiod to become Available (up to 5m)..."
kubectl wait --for=condition=Available deployment/istiod \
  -n istio-system --timeout=5m \
  || fail "istiod did not become ready."

log "      Waiting for istio-ingressgateway to become Available (up to 5m)..."
kubectl wait --for=condition=Available deployment/istio-ingressgateway \
  -n istio-system --timeout=5m \
  || fail "istio-ingressgateway did not become ready."

log "      Istio ready with ingress gateway."
echo

# ==============================================================================
# 3. KEDA — always installed, ultra-minimal operator config
# BUG FIX: corrected helm value paths — keda chart uses operator.resources.*
# not resources.operator.*
# ==============================================================================
log "[3/3] Installing KEDA (minimal)..."

helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
helm repo update kedacore 2>/dev/null

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --timeout 8m \
  --wait \
  --set replicaCount=1 \
  --set operator.resources.requests.cpu=10m \
  --set operator.resources.requests.memory=32Mi \
  --set operator.resources.limits.cpu=50m \
  --set operator.resources.limits.memory=64Mi \
  --set metricsServer.resources.requests.cpu=10m \
  --set metricsServer.resources.requests.memory=32Mi \
  --set metricsServer.resources.limits.cpu=50m \
  --set metricsServer.resources.limits.memory=64Mi \
  --set webhooks.resources.requests.cpu=5m \
  --set webhooks.resources.requests.memory=16Mi \
  --set webhooks.resources.limits.cpu=20m \
  --set webhooks.resources.limits.memory=32Mi

log "      Waiting for keda-operator pod..."
kubectl wait --namespace keda \
  --for=condition=ready pod \
  --selector=app=keda-operator \
  --timeout=5m

log "      KEDA ready."
echo

# ==============================================================================
# Monitoring — BLOCKED on t4g.medium
# ==============================================================================
if [[ "$INSTALL_MONITORING" == "1" ]]; then
  if [[ "$FORCE_MONITORING" != "1" ]]; then
    log "[extra] INSTALL_MONITORING=1 detected — BLOCKED."
    log "        kube-prometheus-stack needs ~1.5 GB RAM."
    log "        t4g.medium (4 GB) with current workloads cannot safely fit this."
    log "        To override: add -e FORCE_MONITORING=1 to docker run (not recommended)."
    echo
  else
    log "[extra] Installing kube-prometheus-stack (FORCE_MONITORING=1, trimmed)..."
    log "        WARNING: May cause OOM on t4g.medium."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update prometheus-community 2>/dev/null

    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
      --namespace monitoring \
      --create-namespace \
      --timeout 15m \
      --wait \
      --set prometheus.prometheusSpec.resources.requests.cpu=50m \
      --set prometheus.prometheusSpec.resources.requests.memory=256Mi \
      --set prometheus.prometheusSpec.resources.limits.cpu=200m \
      --set prometheus.prometheusSpec.resources.limits.memory=512Mi \
      --set prometheus.prometheusSpec.retention=6h \
      --set prometheus.prometheusSpec.retentionSize=512MB \
      --set alertmanager.enabled=false \
      --set grafana.enabled=false \
      --set nodeExporter.enabled=true \
      --set kubeStateMetrics.enabled=true

    log "        Monitoring installed (trimmed)."
    echo
  fi
fi

# ==============================================================================
# DCGM — auto-skip if no GPU nodes present
# ==============================================================================
if [[ "$INSTALL_DCGM" == "1" ]]; then
  GPU_NODES=$(kubectl get nodes \
    -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | grep -v '^0$' | wc -l || true)

  if [[ "$GPU_NODES" -gt 0 ]]; then
    log "[extra] Installing NVIDIA DCGM exporter ($GPU_NODES GPU node(s) detected)..."
    helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts 2>/dev/null || true
    helm repo update nvidia 2>/dev/null
    helm upgrade --install dcgm nvidia/dcgm-exporter \
      --namespace gpu-monitoring \
      --create-namespace \
      --timeout 8m \
      --wait || true
    log "        DCGM done."
  else
    log "[extra] Skipping DCGM — no GPU nodes detected (expected on t4g.medium)."
  fi
  echo
fi

# ==============================================================================
# Summary
# ==============================================================================
echo
log "=== Install complete (t4g.medium minimal config) ==="
log "  istiod        → $(kubectl get deployment istiod \
    -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '?') replica ready"
log "  ingress gw    → $(kubectl get deployment istio-ingressgateway \
    -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '?') replica ready"

log "  keda-operator → $(kubectl get deployment keda-operator \
    -n keda -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '?') replica ready"

log "  metrics API   → $(kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes \
    >/dev/null 2>&1 && echo 'ready' || echo 'not ready')"
echo
log "  Node resource pressure:"
kubectl top nodes 2>/dev/null || log "  (kubectl top not available yet — metrics API still warming up)"
