#!/bin/bash
set -euo pipefail

echo "============================================================="
echo " BYOC EKS Provisioner"
echo "============================================================="
echo

# ==============================================================================
# INFRA ACCOUNT — from environment variable INFRA_KEY_JSON
# ==============================================================================
if [[ -z "${INFRA_KEY_JSON:-}" ]]; then
  echo "ERROR: INFRA_KEY_JSON environment variable is required."
  echo "Run with: -e INFRA_KEY_JSON=\"\$(cat key.json)\""
  exit 1
fi

if ! echo "$INFRA_KEY_JSON" | jq -e '.AccessKey' >/dev/null 2>&1; then
  echo "ERROR: INFRA_KEY_JSON is not valid JSON or missing 'AccessKey'."
  exit 1
fi

INFRA_KEY_ID=$(echo "$INFRA_KEY_JSON" | jq -r '.AccessKey.AccessKeyId')
INFRA_SECRET=$(echo "$INFRA_KEY_JSON" | jq -r '.AccessKey.SecretAccessKey')

if [[ -z "$INFRA_KEY_ID" || "$INFRA_KEY_ID" == "null" || \
      -z "$INFRA_SECRET"  || "$INFRA_SECRET" == "null" ]]; then
  echo "ERROR: INFRA_KEY_JSON missing AccessKeyId or SecretAccessKey."
  exit 1
fi

export INFRA_AWS_ACCESS_KEY_ID="$INFRA_KEY_ID"
export INFRA_AWS_SECRET_ACCESS_KEY="$INFRA_SECRET"
export INFRA_AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

echo "Infra account  : credentials loaded from INFRA_KEY_JSON"
echo "Infra region   : $INFRA_AWS_DEFAULT_REGION"
echo

# ==============================================================================
# SECRETS ACCOUNT — Hardcoded (update these values)
# ==============================================================================
export SECRETS_AWS_ACCESS_KEY_ID="<AWS_ACCESS_KEY_ID>"          # ← UPDATE THIS
export SECRETS_AWS_SECRET_ACCESS_KEY="<AWS_SECRET_ACCESS_KEY>"  # ← UPDATE THIS
export SECRETS_AWS_DEFAULT_REGION="ap-south-1"

echo "Secrets account: credentials hardcoded"
echo "Secrets region : $SECRETS_AWS_DEFAULT_REGION"
echo

# ==============================================================================
# Terraform sync logic
# ==============================================================================
TF_DIR="/app/Terraform"
TF_SRC="/app/Terraform-src"

echo "INFO: Syncing Terraform .tf files from image..."
cp "$TF_SRC"/*.tf "$TF_DIR/" 2>/dev/null || true

if [[ ! -f "$TF_DIR/terraform.tfvars" ]]; then
  echo "INFO: Seeding terraform.tfvars from image..."
  cp "$TF_SRC"/*.tfvars "$TF_DIR/" 2>/dev/null || true
else
  echo "INFO: Preserving existing terraform.tfvars in $TF_DIR"
fi

if ls "$TF_DIR"/*.tf >/dev/null 2>&1; then
  echo "      Active Terraform files: $(ls "$TF_DIR"/*.tf 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
  echo
fi

if ! touch "$TF_DIR/.write-test" 2>/dev/null; then
  echo "ERROR: /app/Terraform is not writable."
  exit 1
fi
rm -f "$TF_DIR/.write-test"

echo "Terraform dir  : $TF_DIR ready"
echo

# Output directory
mkdir -p /app/output

# ==============================================================================
# Main execution routes
# ==============================================================================
ACTION="${ACTION:-}"
if [[ -z "$ACTION" ]]; then
  if [[ "${CLEANUP:-0}" == "1" ]]; then
    ACTION="destroy"
  else
    ACTION="create"
  fi
fi

if [[ "$ACTION" == "up" ]]; then
  ACTION="create"
fi

if [[ "$ACTION" == "destroy" ]]; then
  echo "Mode: CLEANUP"
  export AWS_ACCESS_KEY_ID="$INFRA_AWS_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$INFRA_AWS_SECRET_ACCESS_KEY"
  export AWS_DEFAULT_REGION="$INFRA_AWS_DEFAULT_REGION"
  bash /app/scripts/cleanup-eks.sh
  exit 0
fi

if [[ "$ACTION" != "create" ]]; then
  echo "ERROR: Unsupported ACTION='$ACTION'. Use ACTION=create or ACTION=destroy."
  exit 1
fi

echo "Mode: PROVISION"
echo

export INSTALL_MONITORING="${INSTALL_MONITORING:-0}"
export INSTALL_DCGM="${INSTALL_DCGM:-0}"
export INSTALL_ISTIO_APP="${INSTALL_ISTIO_APP:-0}"

export AWS_ACCESS_KEY_ID="$INFRA_AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$INFRA_AWS_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$INFRA_AWS_DEFAULT_REGION"

bash /app/scripts/provision-eks.sh

# Copy kubeconfigs
ADMIN_KUBECONFIG_SRC="/app/eks/kubeconfig"
EXTERNAL_KUBECONFIG_SRC="/app/eks/external-kubeconfig"

mkdir -p /app/output/eks

if [[ -f "$ADMIN_KUBECONFIG_SRC" ]]; then
  cp "$ADMIN_KUBECONFIG_SRC" /app/output/eks/kubeconfig-admin
  echo "Admin kubeconfig saved to output/eks/kubeconfig-admin"
else
  echo "WARNING: admin kubeconfig not generated"
fi

if [[ -f "$EXTERNAL_KUBECONFIG_SRC" ]]; then
  cp "$EXTERNAL_KUBECONFIG_SRC" /app/output/eks/kubeconfig
  echo "External kubeconfig saved to output/eks/kubeconfig"
else
  echo "ERROR: external kubeconfig not generated"
  exit 1
fi

if [[ "${INSTALL_ISTIO_APP:-0}" == "1" ]]; then
  echo "Running Istio sample deployment..."
  export KUBECONFIG="$ADMIN_KUBECONFIG_SRC"
  bash /app/scripts/deploy-istio-sample.sh
fi

# Secrets Manager upload
KUBECONFIG_OUT="/app/output/eks/kubeconfig"
SECRET_NAME="AWS/kubeconfig"

if [[ ! -f "$KUBECONFIG_OUT" || "${SKIP_AWS_UPLOAD:-0}" == "1" ]]; then
  echo "Skipping Secrets Manager upload."
  exit 0
fi

echo "Switching to Secrets account..."
export AWS_ACCESS_KEY_ID="$SECRETS_AWS_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SECRETS_AWS_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$SECRETS_AWS_DEFAULT_REGION"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "ERROR: Secrets account credentials invalid."
  exit 1
fi

echo "Uploading kubeconfig to Secrets Manager..."
if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$SECRETS_AWS_DEFAULT_REGION" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" --secret-string "file://$KUBECONFIG_OUT" --region "$SECRETS_AWS_DEFAULT_REGION"
  echo "Secret updated."
else
  aws secretsmanager create-secret --name "$SECRET_NAME" --description "Kubeconfig for BYOC EKS" --secret-string "file://$KUBECONFIG_OUT" --region "$SECRETS_AWS_DEFAULT_REGION"
  echo "Secret created."
fi

echo
echo "============================================================="
echo " All done!"
echo "============================================================="
