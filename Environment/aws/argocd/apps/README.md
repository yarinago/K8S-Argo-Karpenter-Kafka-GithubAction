# AWS Argo CD app-of-apps (per environment)

`dev/` and `prod/` are what each environment's `envs/*/02-platform` root Application points at — the AWS equivalent of `Environment/local/argocd/apps/`.

## What's here now

- **Strimzi operator** (`kafka/`) — same chart/pattern as local, pointed at an AWS-specific values file (`../../values/strimzi-values-{dev,prod}.yaml`) since each AWS cluster only ever hosts one environment, unlike local's single cluster watching two namespaces.
- **Splitwise Kafka runtime** (`splitwise/runtime/`) — Kafka cluster, producer/loadgen Rollouts, Kafka UI, all via the **same shared base** local uses (`Environment/resources/splitwise-runtime/base/`, extracted from what used to be `Environment/local/argocd/apps/splitwise/runtime/base/`). Only the ingress differs per environment on purpose: local keeps its own Traefik + `localtest.me` ingress (no DNS locally), AWS gets its own ALB + `external-dns` ingress here (`splitwise/runtime/kafka-ui-ingress.yaml`) — the base itself has zero ingress-controller-specific content, so nothing had to change to support both.
- **The Splitwise app itself** (`splitwise/app/`) — the web/consumer container from `splitwise-household-expenses`, deployed **without any change to that repo**. `deployment.yaml`/`service.yaml`/`pvc.yaml` are pulled straight from its `k8s/base` by raw GitHub URL (not a local cross-repo path — Kustomize's security sandbox blocks that; a remote URL isn't subject to it), which also means that directory's own `kustomization.yaml` — and the KSOPS generator it lists for its encrypted `configmap.yaml` — is never invoked, so no KSOPS install is needed on AWS. Config and credentials both come exclusively from Secrets Manager instead: a placeholder empty `ConfigMap` satisfies the Deployment's `envFrom` reference (Kubernetes just needs the object to exist), and the real values — all 13 keys, config and credentials merged — arrive via `ExternalSecret` from `splitwise/<env>/app-config`, the same secret `terraform-aws-envs.yaml` populates by decrypting the app repo's SOPS-encrypted files directly (see the root README's Secrets section). This is deliberately the industry-standard path for a production AWS setup — Secrets Manager, not SOPS-in-git — chosen specifically to keep the app repo untouched while still avoiding a second, parallel secrets mechanism.

Every tree here is `kustomize build`-verified against the real files — including a full regression build of local's entire `apps/` tree after the runtime extraction (confirming local wasn't affected), and of `splitwise/app/` against the actual live app repo content.

## What's still missing

- **The monitoring stack** (Prometheus/Alertmanager/Grafana/Loki) — not yet ported from local. `splitwise/app`'s `service-monitor.yaml` (from the app repo) is deliberately excluded until this exists — no Prometheus Operator CRDs on AWS yet, so including it would fail the sync.
- **prod's equivalent of `splitwise/app/`** — dev's is built and verified; prod needs the same three files with `splitwise/prod/app-config` and the prod hostname/namespace, not yet created.
- **A single `ApplicationSet` generating dev/prod from one definition**, the way local's Splitwise apps do — dev and prod are currently two hand-maintained, parallel trees instead.
