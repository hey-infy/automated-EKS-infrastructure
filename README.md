# BYOC EKS Provisioner

Provisions an EKS cluster on AWS using Terraform inside a Docker container.

## Credential Setup

Two separate AWS accounts are used:

| File | Account | Used For |
|---|---|---|
| `key.json` | Infra account | Terraform - creates EKS, VPC, node groups |
| `.env` | Secrets account | Stores kubeconfig in AWS Secrets Manager |

**`key.json`** - AWS IAM access key JSON (the format downloaded from the AWS console):
```json
{
  "AccessKey": {
    "UserName": "eks-provisioner",
    "AccessKeyId": "AKIA...",
    "SecretAccessKey": "...",
    "Status": "Active",
    "CreateDate": "..."
  }
}
```

**`.env`** - Secrets account credentials (copy from `.env.example`):
```bash
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_DEFAULT_REGION=ap-south-1
```

Both files must exist in the current directory before running.

---

## Build

```bash
docker build -t byoc-eks .
```

---

## Provision (create infra)

```bash
mkdir -p tfstate output

docker run --rm -it \
  -v "$(pwd)/tfstate:/app/Terraform" \
  -v "$(pwd)/output:/app/output" \
  -v "$(pwd)/key.json:/app/key.json:ro" \
  -v "$(pwd)/.env:/app/.env:ro" \
  -e ACTION=create \
  byoc-eks
```

On first run, `tfstate/` can be empty - the `.tf` files are auto-seeded from the image.  
The `terraform.tfstate` file is written to `tfstate/` on your host so it persists across runs.  
The admin kubeconfig is written to `output/eks/kubeconfig-admin`.  
The external token-based kubeconfig is written to `output/eks/kubeconfig` and uploaded to AWS Secrets Manager.  
The external kubeconfig token defaults to `24h`.

---

## Cleanup (destroy all infra)

```bash
docker run --rm -it \
  -v "$(pwd)/tfstate:/app/Terraform" \
  -v "$(pwd)/output:/app/output" \
  -v "$(pwd)/key.json:/app/key.json:ro" \
  -v "$(pwd)/.env:/app/.env:ro" \
  -e ACTION=destroy \
  byoc-eks
```

Local terminal runs prompt for `YES` before anything is deleted.  
Kubernetes jobs and other non-interactive runs auto-confirm the cleanup so they do not hang waiting for stdin.

---

## Optional flags

| Flag | Default | Description |
|---|---|---|
| `INSTALL_ISTIO_APP=1` | off | Re-run the sample echo app deployment with Istio Gateway + VirtualService |
| `SKIP_AWS_UPLOAD=1` | off | Skip uploading kubeconfig to Secrets Manager |
| `ACTION=create|destroy` | `create` | Choose whether to provision or destroy infrastructure |
| `AWS_DEFAULT_REGION=...` | ap-south-1 | Override AWS region |
| `EXTERNAL_ACCESS_NAMESPACE=...` | `external-access` | Namespace for the external ServiceAccount |
| `EXTERNAL_KUBECONFIG_TOKEN_DURATION=...` | `24h` | Lifetime for the external kubeconfig token |
| `EXTERNAL_SERVICE_ACCOUNT_PREFIX=...` | `external-user` | Prefix used when creating the external ServiceAccount |

`CLEANUP=1` is still accepted as a legacy alias for `ACTION=destroy`, and `ACTION=up` is still accepted as a legacy alias for `ACTION=create`.

Istio with an internet-facing AWS Network Load Balancer-backed ingress gateway and KEDA are installed by default during provisioning.

Example with the sample app redeploy step:
```bash
docker run --rm -it \
  -v "$(pwd)/tfstate:/app/Terraform" \
  -v "$(pwd)/output:/app/output" \
  -v "$(pwd)/key.json:/app/key.json:ro" \
  -v "$(pwd)/.env:/app/.env:ro" \
  -e INSTALL_ISTIO_APP=1 \
  byoc-eks
```

---

## What gets provisioned

- VPC with 2 public + 2 private subnets across 2 AZs
- Internet Gateway + NAT Gateway
- EKS cluster (`q0-cluster`, Kubernetes 1.29)
- EKS control plane associated only with private subnets
- EKS upgrade policy set to standard support (`STANDARD`)
- One managed node group (`t4g.medium` by default, minimum size 2)
- EKS add-ons: `vpc-cni`, `kube-proxy`, `coredns`, `eks-pod-identity-agent`, and `metrics-server`
- Istio control plane with `istio-ingressgateway` internet-facing Network Load Balancer service
- Echo app deployed to `demo` namespace with Istio sidecar injection
- Echo app exposed through Istio `Gateway` + `VirtualService`
- admin kubeconfig saved locally as `output/eks/kubeconfig-admin`
- external token-based kubeconfig saved as `output/eks/kubeconfig`
- external kubeconfig uploaded to AWS Secrets Manager as `AWS/kubeconfig`
