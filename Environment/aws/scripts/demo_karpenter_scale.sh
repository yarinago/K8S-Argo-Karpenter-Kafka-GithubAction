#!/usr/bin/env bash
# Triggers (and reverts) the CPU-overload -> HPA -> Karpenter node-scaling
# demo defined in scripts/demo/cpu-burn-hpa.yaml. Run from real Linux/WSL2
# — same constraint as cluster_creation.sh / destroy_environment.sh.
#
# Usage:
#   ./demo_karpenter_scale.sh dev up      # apply the demo workload + HPA
#   ./demo_karpenter_scale.sh dev status  # watch nodes / pods / HPA
#   ./demo_karpenter_scale.sh dev down    # delete the demo namespace — full revert

set -euo pipefail

ENV="${1:?Usage: $0 <dev|prod> <up|status|down>}"
ACTION="${2:?Usage: $0 <dev|prod> <up|status|down>}"
REGION="us-east-1"
CLUSTER_NAME="splitwise-${ENV}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "ENV must be 'dev' or 'prod', got '$ENV'" >&2
  exit 1
fi
if [[ "$ACTION" != "up" && "$ACTION" != "status" && "$ACTION" != "down" ]]; then
  echo "ACTION must be 'up', 'status' or 'down', got '$ACTION'" >&2
  exit 1
fi

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null

case "$ACTION" in
  up)
    if ! kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
      echo "!! metrics-server isn't installed in $CLUSTER_NAME — the HPA will sit at" >&2
      echo "!! <unknown> targets and never scale. Sync the metrics-server Argo CD" >&2
      echo "!! Application first (argocd/apps/dev/metrics-server)." >&2
      exit 1
    fi
    echo "-- Applying the CPU-burn Deployment + HPA (namespace: demo) --"
    kubectl apply -f "${SCRIPT_DIR}/demo/cpu-burn-hpa.yaml"
    echo
    echo "Watch it with:"
    echo "  $0 $ENV status"
    ;;
  status)
    echo "-- HPA --"
    kubectl get hpa -n demo 2>/dev/null || echo "  (not found — run '$0 $ENV up' first)"
    echo
    echo "-- Demo pods --"
    kubectl get pods -n demo -o wide 2>/dev/null || true
    echo
    echo "-- Nodes --"
    kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
    ;;
  down)
    echo "-- Deleting the demo namespace (Deployment + HPA + all its pods) --"
    kubectl delete namespace demo --ignore-not-found=true --wait=true
    echo "Karpenter will consolidate away any now-empty nodes after its normal delay."
    ;;
esac
