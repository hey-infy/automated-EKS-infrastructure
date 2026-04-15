#!/bin/bash
set -euo pipefail

# =============================================================================
# force-cleanup-eks.sh
# Deletes all AWS resources directly via aws cli — no terraform state needed.
# =============================================================================

CLUSTER="q0-cluster"
REGION="${AWS_DEFAULT_REGION:-ap-south-1}"

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID not set}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY not set}"
export AWS_DEFAULT_REGION="$REGION"

echo "============================================================="
echo " BYOC EKS Force Cleanup (no tfstate required)"
echo "============================================================="
echo " Cluster   : $CLUSTER ($REGION)"
echo "============================================================="
echo
echo "This will permanently delete the EKS cluster and its node groups."
echo
read -rp "Type 'YES' to confirm: " CONFIRM
echo

if [[ "$CONFIRM" != "YES" ]]; then
  echo "Cleanup cancelled."
  exit 0
fi

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
success() { echo "[$(date '+%H:%M:%S')] ✓ $*"; }

echo "Starting force cleanup..."
echo

# 1. Node Groups — BUG FIX: delete and wait for each nodegroup individually
# (aws eks wait nodegroup-deleted only accepts one nodegroup at a time)
log "Checking for Node Groups in $CLUSTER..."
NODE_GROUPS=$(aws eks list-nodegroups \
  --cluster-name "$CLUSTER" \
  --region "$REGION" \
  --query 'nodegroups' \
  --output text 2>/dev/null || true)

for NG in $NODE_GROUPS; do
  log "Deleting Node Group: $NG"
  aws eks delete-nodegroup \
    --cluster-name "$CLUSTER" \
    --nodegroup-name "$NG" \
    --region "$REGION" >/dev/null 2>&1 || true
done

# Wait for each node group individually (one at a time — AWS CLI requirement)
for NG in $NODE_GROUPS; do
  log "Waiting for Node Group '$NG' to delete..."
  aws eks wait nodegroup-deleted \
    --cluster-name "$CLUSTER" \
    --nodegroup-name "$NG" \
    --region "$REGION" 2>/dev/null || true
  success "Node Group '$NG' deleted."
done

# 2. EKS Cluster
log "Deleting EKS Cluster: $CLUSTER..."
aws eks delete-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1 || true

log "Waiting for cluster to terminate..."
aws eks wait cluster-deleted --name "$CLUSTER" --region "$REGION" 2>/dev/null || true

success "Cluster deleted."

echo "============================================================="
echo " Force Cleanup Complete!"
echo "============================================================="
