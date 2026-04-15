#!/bin/bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-q0-cluster}"
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
ADMIN_KUBECONFIG="${ADMIN_KUBECONFIG:-/app/eks/kubeconfig}"
KUBECONFIG_OUTPUT="${KUBECONFIG_OUTPUT:-/app/eks/external-kubeconfig}"
NAMESPACE="${EXTERNAL_ACCESS_NAMESPACE:-external-access}"
ROLE_NAME="${EXTERNAL_CLUSTER_ROLE_NAME:-external-readonly}"
TOKEN_DURATION="${EXTERNAL_KUBECONFIG_TOKEN_DURATION:-24h}"
SERVICE_ACCOUNT_PREFIX="${EXTERNAL_SERVICE_ACCOUNT_PREFIX:-external-user}"
CONTEXT_PREFIX="${EXTERNAL_CONTEXT_PREFIX:-external-context}"
RUN_ID="${EXTERNAL_ACCESS_ID:-$(date +%s)}"
SERVICE_ACCOUNT="${EXTERNAL_SERVICE_ACCOUNT_NAME:-${SERVICE_ACCOUNT_PREFIX}-${RUN_ID}}"
BINDING_NAME="${EXTERNAL_CLUSTER_ROLE_BINDING_NAME:-external-binding-${RUN_ID}}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set}"
export AWS_DEFAULT_REGION="$REGION"

echo "============================================================="
echo " Generating External kubeconfig for EKS"
echo "Cluster     : $CLUSTER_NAME"
echo "Namespace   : $NAMESPACE"
echo "ServiceAcct : $SERVICE_ACCOUNT"
echo "Output file : $KUBECONFIG_OUTPUT"
echo "============================================================="

for cmd in aws kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd not found. Please install it first."
    exit 1
  fi
done

if [[ ! -f "$ADMIN_KUBECONFIG" ]]; then
  echo "ERROR: Admin kubeconfig not found at $ADMIN_KUBECONFIG"
  exit 1
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: AWS session not valid. Please set AWS_ACCESS_KEY_ID or run aws configure."
  exit 1
fi

mkdir -p "$(dirname "$ADMIN_KUBECONFIG")" "$(dirname "$KUBECONFIG_OUTPUT")"

echo "Refreshing admin kubeconfig via aws eks..."
aws eks update-kubeconfig \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --kubeconfig "$ADMIN_KUBECONFIG" >/dev/null

export KUBECONFIG="$ADMIN_KUBECONFIG"

echo "Creating namespace if needed..."
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

echo "Creating ServiceAccount: $SERVICE_ACCOUNT"
kubectl create serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" >/dev/null

echo "Creating or updating readonly ClusterRole..."
kubectl apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $ROLE_NAME
rules:
- apiGroups: [""]
  resources: ["pods", "services", "nodes", "namespaces"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
EOF

echo "Binding role..."
kubectl create clusterrolebinding "$BINDING_NAME" \
  --clusterrole "$ROLE_NAME" \
  --serviceaccount "$NAMESPACE:$SERVICE_ACCOUNT" >/dev/null

echo "Generating service account token..."
TOKEN=$(kubectl create token "$SERVICE_ACCOUNT" -n "$NAMESPACE" --duration="$TOKEN_DURATION")

echo "Fetching cluster endpoint and CA bundle..."
ENDPOINT=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.endpoint' \
  --output text)
CA_DATA=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.certificateAuthority.data' \
  --output text)

echo "Writing external kubeconfig..."
cat > "$KUBECONFIG_OUTPUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: $ENDPOINT
    certificate-authority-data: $CA_DATA
  name: eks
contexts:
- context:
    cluster: eks
    user: $SERVICE_ACCOUNT
  name: ${CONTEXT_PREFIX}-${RUN_ID}
current-context: ${CONTEXT_PREFIX}-${RUN_ID}
users:
- name: $SERVICE_ACCOUNT
  user:
    token: $TOKEN
EOF

chmod 600 "$KUBECONFIG_OUTPUT"

echo
echo "External kubeconfig created successfully!"
echo "File          : $KUBECONFIG_OUTPUT"
echo "Token duration: $TOKEN_DURATION"
echo "Namespace     : $NAMESPACE"
echo "ServiceAccount: $SERVICE_ACCOUNT"
echo
echo "Test with these commands:"
echo "   kubectl --kubeconfig=$KUBECONFIG_OUTPUT get pods -A"
echo "   kubectl --kubeconfig=$KUBECONFIG_OUTPUT get services -A"
echo "============================================================="
