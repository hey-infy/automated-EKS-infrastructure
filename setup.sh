#!/bin/bash
set -euo pipefail

# =============================================================================
# setup.sh — run once on your host before the first docker build
# Creates tfstate/ and output/ folders and copies .tf files into tfstate/
# so terraform.tfstate persists on your host between container runs.
# =============================================================================

echo "Setting up host folders..."

mkdir -p tfstate output

# Copy all .tf files and terraform.tfvars into tfstate/
cp Terraform/eks.tf          tfstate/
cp Terraform/vpc.tf          tfstate/
cp Terraform/provider.tf     tfstate/
cp Terraform/variables.tf    tfstate/
cp Terraform/terraform.tfvars tfstate/

echo
echo "Done. Folder structure:"
echo "  tfstate/              ← mount this as -v \"\$(pwd)/tfstate:/app/Terraform\""
echo "    eks.tf"
echo "    vpc.tf"
echo "    provider.tf"
echo "    variables.tf"
echo "    terraform.tfvars"
echo "  output/               ← mount this as -v \"\$(pwd)/output:/app/output\""
echo
echo "Next: docker build -t byoc-eks ."
echo
echo "Then provision:"
echo "  docker run --rm -it \\"
echo "    -v \"\$(pwd)/tfstate:/app/Terraform\" \\"
echo "    -v \"\$(pwd)/output:/app/output\" \\"
echo "    -e AWS_ACCESS_KEY_ID=\"AKIA...\" \\"
echo "    -e AWS_SECRET_ACCESS_KEY=\"...\" \\"
echo "    -e AWS_DEFAULT_REGION=\"ap-south-1\" \\"
echo "    byoc-eks"
