#!/bin/bash
set -euo pipefail

# BUG FIX: was "eks/kubeconfig" (wrong case) — must match actual filename
KUBECONFIG_FILE="${KUBECONFIG:-/app/eks/kubeconfig}"
export KUBECONFIG="$KUBECONFIG_FILE"

NAMESPACE="demo"
GATEWAY_NAME="byoc-gateway"
VIRTUAL_SERVICE_NAME="byoc-virtualservice"

echo "=== Istio Sample Deployment ==="
echo

# ====================== PREFLIGHT ======================
echo "--- Preflight checks ---"

if [[ ! -f "$KUBECONFIG_FILE" ]]; then
  echo "ERROR: kubeconfig not found at $KUBECONFIG_FILE"
  exit 1
fi

if ! kubectl cluster-info --request-timeout=10s >/dev/null 2>&1; then
  echo "ERROR: Cannot reach the cluster. Check your kubeconfig."
  exit 1
fi

if ! kubectl get namespace istio-system >/dev/null 2>&1; then
  echo "ERROR: Istio is not installed. Run the provision flow first."
  exit 1
fi

if ! kubectl get deployment istiod -n istio-system >/dev/null 2>&1; then
  echo "ERROR: istiod deployment not found in istio-system namespace."
  exit 1
fi

ISTIOD_READY=$(kubectl get deployment istiod -n istio-system \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [[ "${ISTIOD_READY:-0}" -lt 1 ]]; then
  echo "ERROR: istiod deployment exists but has no ready replicas. Wait for it to stabilise."
  exit 1
fi

echo "Cluster reachable."
echo "Istio found."
echo

# ====================== STEP 1: NAMESPACE ======================
echo "Step 1/4: Creating namespace with Istio sidecar injection enabled..."

kubectl apply -f - <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: $NAMESPACE
  labels:
    istio-injection: enabled
YAML

echo "Namespace '$NAMESPACE' ready with istio-injection=enabled."
echo

# ====================== STEP 2: DEPLOY APP ======================
echo "Step 2/4: Deploying sample app (echo server with sidecar)..."

kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-app
  namespace: $NAMESPACE
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
---
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: $NAMESPACE
spec:
  type: ClusterIP
  selector:
    app: echo
  ports:
  - port: 80
    targetPort: 80
YAML

echo "Deployment and Service applied."
echo

# ====================== STEP 3: ISTIO ROUTING ======================
echo "Step 3/4: Applying Istio Gateway + VirtualService..."

kubectl apply -f - <<YAML
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: $GATEWAY_NAME
  namespace: $NAMESPACE
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
  name: $VIRTUAL_SERVICE_NAME
  namespace: $NAMESPACE
spec:
  hosts:
  - "*"
  gateways:
  - $GATEWAY_NAME
  http:
  - match:
    - uri:
        prefix: /
    route:
    - destination:
        host: echo-service.$NAMESPACE.svc.cluster.local
        port:
          number: 80
YAML

echo "Istio routing applied."
echo "NOTE: Traffic now flows through the Istio ingress gateway and sidecar proxy."
echo

# ====================== STEP 4: WAIT + GET IP ======================
echo "Step 4/4: Waiting for pods and Istio ingress gateway endpoint..."

kubectl wait --for=condition=Available deployment/echo-app \
  -n "$NAMESPACE" --timeout=5m
echo "echo-app deployment is ready."

echo "Waiting for Istio ingress gateway LoadBalancer hostname/IP (up to 5 minutes)..."
ISTIO_IP=""
for i in {1..30}; do
  ISTIO_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -z "$ISTIO_IP" ]]; then
    ISTIO_IP=$(kubectl get svc istio-ingressgateway -n istio-system \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi
  if [[ -n "$ISTIO_IP" ]]; then
    break
  fi
  (( i % 5 == 0 )) && echo "  Still waiting... ($i/30)"
  sleep 10
done

if [[ -z "$ISTIO_IP" ]]; then
  echo "WARNING: Istio ingress gateway endpoint not assigned yet."
  echo "  Check: kubectl get svc istio-ingressgateway -n istio-system"
else
  echo "Istio gateway endpoint: $ISTIO_IP"
fi

echo
echo "Verifying Istio sidecar injection..."
CONTAINERS=$(kubectl get pods -n "$NAMESPACE" \
  -o jsonpath='{.items[0].spec.containers[*].name}' 2>/dev/null || true)
if echo "$CONTAINERS" | grep -q "istio-proxy"; then
  echo "Istio sidecar (istio-proxy) confirmed in pod."
else
  echo "WARNING: Sidecar not detected yet — pod may still be starting."
fi

# ====================== FINAL OUTPUT ======================
echo
echo "============================================================="
echo "Istio Sample Deployment Complete!"
echo "============================================================="
echo "Namespace     : $NAMESPACE (istio-injection=enabled)"
echo "App           : echo-app (echo server)"
echo "Service       : echo-service (ClusterIP)"
echo "Gateway       : $GATEWAY_NAME"
echo "VirtualService: $VIRTUAL_SERVICE_NAME"
[[ -n "$ISTIO_IP" ]] && echo "Access URL    : http://$ISTIO_IP"
echo
echo "Useful commands:"
echo "  kubectl get pods -n $NAMESPACE"
echo "  kubectl get gateway,virtualservice -n $NAMESPACE"
echo "  kubectl get svc istio-ingressgateway -n istio-system"
[[ -n "$ISTIO_IP" ]] && echo "  curl http://$ISTIO_IP"
echo "============================================================="
