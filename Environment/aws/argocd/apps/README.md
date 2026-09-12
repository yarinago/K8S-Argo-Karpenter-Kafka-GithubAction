# AWS Argo CD app-of-apps (per environment)

`dev/` and `prod/` are what each environment's `envs/*/02-platform` root Application points at — the AWS equivalent of `Environment/local/argocd/apps/`.

## What's here now

- **Strimzi operator** (`kafka/`) — same chart/pattern as local, pointed at an AWS-specific values file (`../../values/strimzi-values-{dev,prod}.yaml`) since each AWS cluster only ever hosts one environment, unlike local's single cluster watching two namespaces.
- **Splitwise Kafka runtime** (`splitwise/`) — Kafka cluster, producer/loadgen Rollouts, Kafka UI, all via the **same shared base** local uses (`Environment/resources/splitwise-runtime/base/`, extracted from what used to be `Environment/local/argocd/apps/splitwise/runtime/base/`). Only the ingress differs per environment on purpose: local keeps its own Traefik + `localtest.me` ingress (no DNS locally), AWS gets its own ALB + `external-dns` ingress here (`splitwise/runtime/kafka-ui-ingress.yaml`) — the base itself has zero ingress-controller-specific content, so nothing had to change to support both.

Both trees are `kustomize build`-verified — including a full regression build of local's entire `apps/` tree after the extraction, confirming local wasn't affected.

## What's still missing

- **The monitoring stack** (Prometheus/Alertmanager/Grafana/Loki) — not yet ported from local.
- **The Splitwise app's own web/consumer container**, from the `splitwise-household-expenses` repo — local's `ApplicationSet` merges that repo's overlay with this repo's runtime overlay as two sources on one Application; the AWS side only has the runtime half built so far (`splitwise-runtime-application.yaml`), not the app-repo half or the `ApplicationSet` structure to generate dev/prod from one definition the way local does.
