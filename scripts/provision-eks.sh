#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="/app/Terraform"

CLUSTER_NAME="q0-cluster"
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
KUBECONFIG_FILE="/app/eks/kubeconfig"
EXTERNAL_KUBECONFIG_FILE="/app/eks/external-kubeconfig"
APP_NAMESPACE="demo"
ISTIO_GATEWAY_NAMESPACE="istio-system"

# Credentials from environment (set by entrypoint or docker run -e)
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set}"
export AWS_DEFAULT_REGION="$REGION"

echo "=== AWS BYOC Provisioning Script ==="
echo "Working Directory: $SCRIPT_DIR"
echo "Cluster Name     : $CLUSTER_NAME"
echo "Region           : $REGION"
echo

# ====================== PREFLIGHT ======================
for cmd in aws terraform kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd is not installed or not in PATH"
    exit 1
  fi
done
echo "All required tools found."

# ====================== STEP 1: TERRAFORM ======================
echo "Step 1/7: Applying Terraform infrastructure..."
cd "$TF_DIR"
terraform init -input=false -upgrade
terraform apply -auto-approve -input=false

echo "  Enforcing EKS upgrade policy: STANDARD..."
CURRENT_SUPPORT_TYPE="$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.upgradePolicy.supportType' \
  --output text 2>/dev/null || echo "UNKNOWN")"

if [[ "$CURRENT_SUPPORT_TYPE" != "STANDARD" ]]; then
  aws eks update-cluster-config \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --upgrade-policy supportType=STANDARD >/dev/null

  echo "  Waiting for cluster to return to Active after upgrade policy update..."
  aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$REGION"

  UPDATED_SUPPORT_TYPE="$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --query 'cluster.upgradePolicy.supportType' \
    --output text 2>/dev/null || echo "UNKNOWN")"

  if [[ "$UPDATED_SUPPORT_TYPE" != "STANDARD" ]]; then
    echo "ERROR: Failed to set EKS upgrade policy to STANDARD. Current value: $UPDATED_SUPPORT_TYPE"
    exit 1
  fi
else
  echo "  EKS upgrade policy already STANDARD."
fi

# ====================== STEP 2: KUBECONFIG SETUP ======================
echo "Step 2/7: Setting up Kubernetes credentials..."
cd "$SCRIPT_DIR"

echo "  Getting EKS credentials..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --kubeconfig "$KUBECONFIG_FILE"

chmod 600 "$KUBECONFIG_FILE"
export KUBECONFIG="$KUBECONFIG_FILE"
echo "  Kubeconfig generated: $KUBECONFIG_FILE"

echo "  Verifying connection (with retry)..."
for attempt in 1 2 3 4 5; do
  if kubectl get nodes --no-headers &>/dev/null; then
    echo "  Successfully connected to EKS cluster!"
    break
  fi
  echo "  Attempt $attempt/5 — cluster API not ready yet, waiting 15s..."
  sleep 15
done

echo "  Waiting for all nodes to be Ready (up to 10 minutes)..."
kubectl wait --for=condition=Ready nodes --all --timeout=10m || true

# ====================== STEP 3: INSTALL CLUSTER DEPENDENCIES ======================
echo "Step 3/7: Installing cluster dependencies..."
export KUBECONFIG="$KUBECONFIG_FILE"

bash "/app/scripts/install-dependencies.sh"
echo "Dependencies installed."

# ====================== STEP 4: DEPLOY APPLICATION ======================
echo "Step 4/7: Deploying echo app with Istio routing..."

kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $APP_NAMESPACE
  labels:
    istio-injection: enabled
YAML

kubectl apply --validate=false -f - <<'APPEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-app
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: ealen/echo-server:latest
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 10m
            memory: 32Mi
          limits:
            cpu: 100m
            memory: 64Mi
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: demo
spec:
  selector:
    app: echo
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: byoc-gateway
  namespace: demo
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: byoc-virtualservice
  namespace: demo
spec:
  hosts:
  - "*"
  gateways:
  - byoc-gateway
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: echo-service.demo.svc.cluster.local
        port:
          number: 80
APPEOF

# ====================== STEP 5: WAIT FOR INGRESS ======================
echo "Step 5/7: Waiting for Istio ingress gateway public IP / Hostname (up to 8 minutes)..."
ISTIO_ENDPOINT=""
for i in {1..40}; do
  ISTIO_ENDPOINT=$(kubectl get svc istio-ingressgateway -n "$ISTIO_GATEWAY_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -z "$ISTIO_ENDPOINT" ]]; then
    ISTIO_ENDPOINT=$(kubectl get svc istio-ingressgateway -n "$ISTIO_GATEWAY_NAMESPACE" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi

  if [[ -n "$ISTIO_ENDPOINT" ]]; then
    echo "SUCCESS! Service is live at: http://$ISTIO_ENDPOINT"
    break
  fi
  (( i % 6 == 0 )) && echo "Still waiting... ($i/40)"
  sleep 12
done

if [[ -z "$ISTIO_ENDPOINT" ]]; then
  echo "WARNING: Timeout waiting for Istio ingress gateway endpoint — load balancer may still be provisioning."
  echo "Check: kubectl get svc istio-ingressgateway -n $ISTIO_GATEWAY_NAMESPACE"
  ISTIO_ENDPOINT="<pending>"
fi

# ====================== STEP 6: GENERATE EXTERNAL KUBECONFIG ======================
echo "Step 6/7: Generating external-access kubeconfig..."
ADMIN_KUBECONFIG="$KUBECONFIG_FILE" \
KUBECONFIG_OUTPUT="$EXTERNAL_KUBECONFIG_FILE" \
CLUSTER_NAME="$CLUSTER_NAME" \
AWS_DEFAULT_REGION="$REGION" \
bash "/app/scripts/generate-kubeconfig.sh"

# ====================== STEP 7: FINAL OUTPUT ======================
echo
echo "============================================================="
echo "BYOC EKS SETUP COMPLETED!"
echo "============================================================="
echo "Test URL   : http://$ISTIO_ENDPOINT"
echo "Admin kubeconfig    : $KUBECONFIG_FILE"
echo "External kubeconfig : $EXTERNAL_KUBECONFIG_FILE"
echo
echo "Quick test: curl http://$ISTIO_ENDPOINT/"
echo "============================================================="
