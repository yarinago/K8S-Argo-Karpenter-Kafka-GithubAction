#!/usr/bin/env bash
# Tears down one AWS environment (dev or prod) fully: Karpenter-provisioned
# EC2 nodes first (they're outside Terraform state), then 02-platform
# (Karpenter/Argo CD/ALB controller/external-dns/external-secrets), then
# 01-cluster (EKS, VPC, IAM, secrets containers). Run from real Linux/WSL2
# — same constraint as cluster_creation.sh.
#
# Usage:
#   ./destroy_environment.sh dev
#   ./destroy_environment.sh prod
#   ./destroy_environment.sh dev --nuke-backend   # ALSO destroys
#     global/backend-bootstrap (the shared S3 state bucket). Only run this
#     after BOTH dev and prod are already destroyed — it removes state for
#     both, and everything else in global/ (github-oidc, dns) along with it
#     if you choose to tear those down too (not done by this script).

set -euo pipefail

ENV="${1:?Usage: $0 <dev|prod> [--nuke-backend]}"
NUKE_BACKEND="${2:-}"
REGION="us-east-1"
CLUSTER_NAME="splitwise-${ENV}"
AWS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "ENV must be 'dev' or 'prod', got '$ENV'" >&2
  exit 1
fi

echo "== Destroying environment: $ENV (cluster: $CLUSTER_NAME) =="

if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

  # Karpenter-provisioned EC2 instances are NOT in Terraform state — delete
  # NodePools first so Karpenter drains and terminates them itself. Skipping
  # this leaves orphaned running instances after `terraform destroy`, and
  # can also block VPC/SG deletion outright (ENIs still attached).
  echo "-- Deleting Karpenter NodePools (drains + terminates nodes) --"
  kubectl delete nodepool --all --ignore-not-found=true --timeout=60s || true
  kubectl delete ec2nodeclass --all --ignore-not-found=true --timeout=60s || true

  echo "-- Waiting for Karpenter nodes to terminate --"
  for i in $(seq 1 30); do
    REMAINING=$(kubectl get nodes -l karpenter.sh/registered=true --no-headers 2>/dev/null | wc -l)
    [[ "$REMAINING" -eq 0 ]] && { echo "All Karpenter nodes gone."; break; }
    echo "  still $REMAINING node(s) draining... ($i/30)"
    sleep 10
  done

  # Fallback: force-terminate anything Karpenter didn't clean up in time, by
  # its own discovery tag. Never touches the bootstrap managed-node-group
  # instance — Terraform owns and destroys that itself in the 01-cluster
  # step below.
  STRAGGLERS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:karpenter.sh/discovery,Values=${CLUSTER_NAME}" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  if [[ -n "$STRAGGLERS" ]]; then
    echo "-- Force-terminating leftover Karpenter instances: $STRAGGLERS --"
    aws ec2 terminate-instances --region "$REGION" --instance-ids $STRAGGLERS
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $STRAGGLERS
  fi
else
  echo "Cluster $CLUSTER_NAME not found — skipping node cleanup, still running terraform destroy in case of a partial apply."
fi

echo "-- Running terraform destroy in envs/${REGION}/${ENV}/02-platform --"
(cd "${AWS_DIR}/envs/${REGION}/${ENV}/02-platform" && terraform init -input=false && terraform destroy -auto-approve)

echo "-- Running terraform destroy in envs/${REGION}/${ENV}/01-cluster --"
(cd "${AWS_DIR}/envs/${REGION}/${ENV}/01-cluster" && terraform init -input=false && terraform destroy -auto-approve)

echo "== Environment '$ENV' destroyed. =="

if [[ "$NUKE_BACKEND" == "--nuke-backend" ]]; then
  echo "-- Destroying global/backend-bootstrap (shared S3 state bucket) --"
  read -rp "This deletes ALL Terraform state for BOTH dev and prod. Type 'destroy-backend' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "destroy-backend" ]]; then
    echo "Confirmation text didn't match — leaving the backend in place."
    exit 0
  fi
  # force_destroy = true on the bucket resource handles emptying every
  # object version before deletion — no manual aws s3 rm needed here.
  (cd "${AWS_DIR}/global/backend-bootstrap" && terraform init -input=false && terraform destroy -auto-approve)
  echo "Backend destroyed."
fi
