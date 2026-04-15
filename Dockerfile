# =============================================================================
# BYOC EKS Provisioner
# =============================================================================
#
# CREDENTIAL SETUP:
#   - Infra account  → Passed as env var: INFRA_KEY_JSON="$(cat key.json)"
#   - Secrets account → Hardcoded inside entrypoint.sh
#
# Build:
#   docker build -t byoc-eks .
#
# Provision:
#   docker run --rm -it \
#     -v "$(pwd)/tfstate:/app/Terraform" \
#     -v "$(pwd)/output:/app/output" \
#     -e INFRA_KEY_JSON="$(cat key.json)" \
#     byoc-eks
#
# Cleanup:
#   docker run --rm -it \
#     -v "$(pwd)/tfstate:/app/Terraform" \
#     -v "$(pwd)/output:/app/output" \
#     -e INFRA_KEY_JSON="$(cat key.json)" \
#     -e ACTION=destroy \
#     byoc-eks
# =============================================================================

FROM debian:bookworm-slim

ARG TERRAFORM_VERSION=1.7.5
ARG KUBECTL_VERSION=1.29.3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash curl unzip ca-certificates gnupg python3 jq less groff git \
  && rm -rf /var/lib/apt/lists/*

# AWS CLI
RUN ARCH="$(dpkg --print-architecture)" && \
  AWSCLI_ARCH="$([ "$ARCH" = "arm64" ] && echo "aarch64" || echo "x86_64")" && \
  curl --retry 5 --retry-delay 3 --retry-connrefused -fsSL \
  "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" \
  -o /tmp/awscli.zip && \
  unzip -q /tmp/awscli.zip -d /tmp/awscli && \
  /tmp/awscli/aws/install && \
  rm -rf /tmp/awscli /tmp/awscli.zip

# Terraform
RUN ARCH="$(dpkg --print-architecture)" && \
  curl --retry 5 --retry-delay 3 --retry-connrefused -fsSL \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" \
  -o /tmp/terraform.zip && \
  unzip -q /tmp/terraform.zip -d /usr/local/bin && \
  rm /tmp/terraform.zip

# kubectl
RUN ARCH="$(dpkg --print-architecture)" && \
  curl --retry 5 --retry-delay 3 --retry-connrefused -fsSL \
  "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
  -o /usr/local/bin/kubectl && \
  chmod +x /usr/local/bin/kubectl

# Helm
RUN curl --retry 5 --retry-delay 3 --retry-connrefused -fsSL \
  https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  -o /tmp/get-helm.sh && \
  chmod +x /tmp/get-helm.sh && \
  USE_SUDO=false HELM_INSTALL_DIR=/usr/local/bin /tmp/get-helm.sh && \
  rm /tmp/get-helm.sh

WORKDIR /app

COPY scripts/ ./scripts/
RUN chmod +x scripts/*.sh

COPY Terraform/ ./Terraform/
COPY Terraform/ ./Terraform-src/

RUN mkdir -p /app/output
RUN ln -s /app/scripts/entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
