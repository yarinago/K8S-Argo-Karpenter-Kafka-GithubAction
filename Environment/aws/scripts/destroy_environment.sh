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

  # Fallback: force-terminate anything Karpenter didn't clean up in time.
  # `karpenter.sh/discovery` was wrong -- verified live that Karpenter
  # doesn't actually set that tag on the instances it launches in this
  # setup, so this filter matched nothing and every straggler silently
  # slipped through. Hit live: a Karpenter node from an unrelated earlier
  # operation (an EKS version bump's node churn) sat running, unnoticed,
  # through two full destroy attempts, then blocked `terraform destroy`
  # in 01-cluster for 20 minutes on the subnet/security-group deletion
  # (DependencyViolation -- its ENIs were still attached) once it finally
  # got there. `karpenter.sh/nodepool` is the tag actually confirmed
  # present (via `aws ec2 describe-tags`) on every Karpenter-launched
  # instance regardless of which NodePool -- and, importantly, it is
  # never set on the EKS-managed bootstrap node group's own instance, so
  # this still can't accidentally catch the one instance this step must
  # never touch (Terraform owns and destroys that itself in 01-cluster).
  STRAGGLERS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
              "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query "Reservations[].Instances[].InstanceId" --output text)
  if [[ -n "$STRAGGLERS" ]]; then
    echo "-- Force-terminating leftover Karpenter instances: $STRAGGLERS --"
    aws ec2 terminate-instances --region "$REGION" --instance-ids $STRAGGLERS
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $STRAGGLERS
  fi
  # Argo CD's aws-bootstrap-root Application carries a cascade-delete
  # finalizer (resources-finalizer.argocd.argoproj.io) specifically so
  # deleting it prunes everything Argo CD manages -- ExternalSecrets,
  # Ingresses (and the ALBs/target groups/security groups behind them),
  # etc. -- via each resource's own controller, while that controller is
  # still running. Nothing in 02-platform's Terraform graph forces that to
  # happen before Terraform's own destroy tears down
  # alb_controller/external_secrets/argocd themselves -- those helm_releases
  # only depend on alb_controller, not on argocd_root_app, so Terraform is
  # free to destroy them before Argo CD ever gets a chance to prune.
  #
  # A first version of this step just ran `kubectl delete application
  # aws-bootstrap-root --timeout=300s || true` and moved on. That's not
  # enough, for two reasons hit live in the same incident:
  #   1. A 5-minute client-side wait isn't always enough for Argo CD to
  #      finish cascading through ~10 child Applications, especially when
  #      several own real ALBs that take AWS real time to deprovision --
  #      and `|| true` swallowed the timeout and ran `terraform destroy`
  #      anyway, which then hit the exact same stuck-finalizer wall on
  #      whatever hadn't been pruned yet (this time on the `infrastructure`
  #      namespace's Ingresses/TargetGroupBindings).
  #   2. Argo CD's cascade isn't the only way these objects get a
  #      deletionTimestamp -- `infrastructure` is a real
  #      kubernetes_namespace Terraform resource, so Terraform's own
  #      destroy deletes it directly, which triggers Kubernetes' own
  #      namespace-content garbage collection independently of Argo CD
  #      entirely. That GC hit the same missing-controller finalizers.
  # By the time this was diagnosed, alb_controller's own helm release was
  # already gone, orphaning 6 real ALBs (plus target groups and security
  # groups) in AWS with nothing left to clean them up -- exactly the
  # failure mode described in kubectl_manifest.argocd_root_app's own
  # comment, just not fully prevented by depending on Argo CD's cascade
  # alone. Required manual `aws elbv2`/`aws ec2` cleanup to recover.
  #
  # Fixed by not trusting the cascade to reach every resource in time:
  # after asking Argo CD to prune (best-effort, still worth doing first so
  # it does as much of the real work as it can), explicitly wait for the
  # two resource types whose finalizers can only be cleared by a
  # controller that's about to be torn down -- Ingress and
  # TargetGroupBinding -- to actually be gone, cluster-wide, regardless of
  # what triggered their deletion. This is the actual invariant that has
  # to hold (those controllers must still be alive when these objects are
  # deleted), so checking it directly is more robust than assuming any one
  # deletion path (Argo CD cascade, namespace GC, ...) reached them in time.
  # Update, found via the EKS audit log after the wait-loop below kept
  # timing out at a flat, never-decreasing 7 ingress/7 targetgroupbinding/
  # 1 externalsecret no matter how long it waited: the wait-loop was never
  # the fix for the actual bug, just a safety net that correctly stopped
  # this script from doing damage while the real cause went unfixed. Root
  # cause: aws-bootstrap-root carries resources-finalizer.argocd.argoproj.io
  # (set by kubectl_manifest.argocd_root_app in Terraform), but its 9 CHILD
  # Applications (argocd/apps/dev/**/*-application.yaml) never had that
  # finalizer on themselves. Deleting the root only cascades to its own
  # direct resources -- which, in an app-of-apps, ARE the child Application
  # objects, not what those children deploy. Confirmed live: the root's
  # cascade deleted all 9 children within 600ms (too fast for a real
  # cascade through Ingresses/Deployments/etc.), and zero delete events
  # ever followed for anything the children owned. No amount of waiting
  # here was ever going to reach 0, regardless of timeout length -- fixed
  # at the source instead, by adding the finalizer to every child
  # Application manifest. This wait-loop stays as defense in depth (it's
  # still the right thing to verify before letting Terraform touch
  # alb_controller/external_secrets), but it should now normally resolve
  # in well under a minute instead of timing out.
  echo "-- Deleting the Argo CD root Application, so it starts pruning everything it manages --"
  if kubectl get application aws-bootstrap-root -n argocd >/dev/null 2>&1; then
    kubectl delete application aws-bootstrap-root -n argocd --timeout=300s --wait=false || true
  else
    echo "  aws-bootstrap-root not found — already deleted or never created, skipping."
  fi

  echo "-- Waiting for every Ingress/TargetGroupBinding/ExternalSecret cluster-wide to actually be gone (their controllers must still be running to clear these) --"
  # `kubectl get <type>` on a CRD-backed type whose CRD no longer exists at
  # all (e.g. externalsecrets, if a prior run's cleanup already let it fully
  # delete) exits non-zero ("the server doesn't have a resource type..."),
  # not zero-with-no-output -- under `pipefail` that non-zero survives
  # `| wc -l` and trips `set -e`, killing the whole script right here with
  # no diagnostic output. That's not a real failure, it's the type being
  # legitimately absent (so trivially zero remaining) -- hit live right
  # after the previous incident's cleanup had already removed the
  # externalsecrets CRD. `|| true` on each kubectl call (not on the pipe
  # overall) keeps a genuine zero-count distinguishable from this case
  # while still letting `wc -l` count real output when the type does exist.
  count_remaining() { kubectl get "$1" -A --no-headers 2>/dev/null | wc -l || true; }
  DEADLINE=$((SECONDS + 900))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    ING_COUNT=$(count_remaining ingress)
    TGB_COUNT=$(count_remaining targetgroupbinding)
    ES_COUNT=$(count_remaining externalsecret)
    if [[ "$ING_COUNT" -eq 0 && "$TGB_COUNT" -eq 0 && "$ES_COUNT" -eq 0 ]]; then
      echo "  All Ingresses/TargetGroupBindings/ExternalSecrets gone."
      break
    fi
    echo "  still remaining: $ING_COUNT ingress(es), $TGB_COUNT targetgroupbinding(s), $ES_COUNT externalsecret(s)... ($((DEADLINE - SECONDS))s left)"
    sleep 15
  done
  REMAINING_ING=$(count_remaining ingress)
  REMAINING_TGB=$(count_remaining targetgroupbinding)
  REMAINING_ES=$(count_remaining externalsecret)
  if [[ "$REMAINING_ING" -gt 0 || "$REMAINING_TGB" -gt 0 || "$REMAINING_ES" -gt 0 ]]; then
    echo "!! $REMAINING_ING ingress(es), $REMAINING_TGB targetgroupbinding(s), $REMAINING_ES externalsecret(s) still remain after 15 minutes."
    echo "!! Proceeding to terraform destroy anyway would risk orphaning their ALBs in AWS or hanging on their finalizers again"
    echo "!! (alb_controller/external_secrets are about to be torn down). Investigate manually before re-running:"
    echo "!! 'kubectl get ingress -A' / 'kubectl get targetgroupbinding -A' / 'kubectl get externalsecret -A', and check"
    echo "!! 'aws elbv2 describe-load-balancers' for anything left needing manual 'aws elbv2 delete-load-balancer' cleanup."
    exit 1
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
