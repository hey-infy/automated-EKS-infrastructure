#!/bin/bash
set -euo pipefail

TF_DIR="/app/Terraform"

# Credentials are set by entrypoint.sh (INFRA account) before calling this script
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set — run via entrypoint}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set — run via entrypoint}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

# Kubeconfig — prefer the one in /app/output (volume mount from host)
if [[ -f "/app/output/eks/kubeconfig-admin" ]]; then
  export KUBECONFIG="/app/output/eks/kubeconfig-admin"
elif [[ -f "/app/eks/kubeconfig" ]]; then
  export KUBECONFIG="/app/eks/kubeconfig"
else
  echo "WARNING: kubeconfig not found — Kubernetes resource deletion will be skipped."
  echo "         AWS infra will still be destroyed via Terraform."
  KUBECONFIG=""
fi

echo "============================================================="
echo " BYOC EKS Cleanup"
echo "============================================================="
echo "This will DELETE the EKS cluster, VPC, NAT Gateway,"
echo "node groups, and all related AWS resources."
echo
[[ -n "${KUBECONFIG:-}" ]] && echo "Kubeconfig : $KUBECONFIG"
echo "Terraform  : $TF_DIR"
echo "Region     : $AWS_DEFAULT_REGION"
echo

# Only prompt when a real local terminal is attached.
# Kubernetes jobs can expose a TTY even though there is no human to answer.
INTERACTIVE_CONFIRM=0
if [[ -t 0 && -t 1 ]] && [[ -z "${KUBERNETES_SERVICE_HOST:-}" ]] && [[ -z "${CI:-}" ]]; then
  INTERACTIVE_CONFIRM=1
fi

if [[ "${FORCE_CLEANUP:-0}" == "1" ]]; then
  echo "Auto-confirm enabled via FORCE_CLEANUP=1."
  CONFIRM="YES"
elif [[ "$INTERACTIVE_CONFIRM" == "1" ]]; then
  read -rp "Type 'YES' to confirm full destroy: " CONFIRM
else
  echo "Auto-confirm enabled for non-interactive cleanup run."
  CONFIRM="YES"
fi
echo

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

echo "Starting cleanup..."
echo

# ====================== STEP 1: DELETE K8S RESOURCES ======================
if [[ -n "${KUBECONFIG:-}" ]]; then
  echo "Step 1/2: Deleting Kubernetes resources (Istio ingress + sample app)..."
  kubectl delete virtualservice byoc-virtualservice -n demo --ignore-not-found=true 2>/dev/null || true
  kubectl delete gateway byoc-gateway -n demo --ignore-not-found=true 2>/dev/null || true
  kubectl delete service echo-service -n demo --ignore-not-found=true 2>/dev/null || true
  kubectl delete deployment echo-app -n demo --ignore-not-found=true 2>/dev/null || true
  kubectl delete service istio-ingressgateway -n istio-system --ignore-not-found=true 2>/dev/null || true
  kubectl delete deployment istio-ingressgateway -n istio-system --ignore-not-found=true 2>/dev/null || true
  echo "  Kubernetes resources deleted."
else
  echo "Step 1/2: Skipping Kubernetes cleanup (no kubeconfig)."
fi

echo

# ====================== STEP 2: TERRAFORM DESTROY ======================
echo "Step 2/2: Destroying Terraform infrastructure..."
cd "$TF_DIR"

if [[ ! -f "terraform.tfstate" ]]; then
  echo "WARNING: No terraform.tfstate found in $TF_DIR"
  echo "         Nothing to destroy or state already gone."
  exit 0
fi

terraform init -input=false -upgrade
terraform destroy -auto-approve -input=false

echo
echo "============================================================="
echo " Cleanup Completed Successfully!"
echo "============================================================="
echo " All AWS resources have been deleted."
echo " Run the provision command again to re-create."
echo "============================================================="
