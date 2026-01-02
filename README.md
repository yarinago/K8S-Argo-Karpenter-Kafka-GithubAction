# GitOps Event Platform on Kubernetes (Kafka + Argo CD + Karpenter + Observability + GitHub Actions)

## Objective
Build a production-style platform locally (zero cloud cost) that:
1. Runs on Kubernetes
2. Uses Kafka as the event backbone
3. Is deployed and operated via Argo CD (GitOps)
4. Has comprehensive monitoring + alerting + logs for everything
5. Enforces quality gates via GitHub Actions

This repository is intended as an interview-grade exercise spec. You are expected to design the repo layout and implementation details yourself.

---

## Hard Constraints
- **Cost: $0** (local only; no managed cloud services).
- **GitHub is the source of truth**: all deployable artifacts are stored in this repo and applied via Argo CD.
- **No manual `kubectl apply`** except:
  - one-time Argo CD install bootstrap, and
  - applying the initial “root” Argo CD Application (or equivalent).
- **Monitoring is mandatory**: Kubernetes + Argo CD + Kafka + your apps must be observable.

---

## Recommended Local Stack (suggested, not mandatory)
- Kubernetes: **kind** or **k3d**
- GitOps: **Argo CD**
- Kafka on K8s: **Strimzi**
- Metrics/Dashboards/Alerts: **Prometheus Operator + Grafana + Alertmanager** (often via `kube-prometheus-stack`)
- Logs: **Loki + log agent** (e.g., Grafana Alloy or Fluent Bit)
- CI: **GitHub Actions**
- Autoscaling (advanced): **Karpenter** via a local-friendly approach (e.g., Cluster API provider path)

> Note: Karpenter locally is intentionally the “capstone” difficulty. If you cannot complete the live Karpenter demo locally, you must still deliver a Karpenter design and document what would change in AWS/EKS.

---

## Deliverables (Definition of Done)

### A) Documentation
1. **Architecture doc**
   - components, data flows, tenancy model (namespaces), key decisions
2. **Runbooks** (minimum 3)
   - Kafka lag incident
   - Argo CD sync/drift incident
   - “Pods pending / capacity issue” incident
3. **Operational README section**
   - how to bootstrap from scratch
   - how to deploy changes via Git
   - how to roll back
4. **ADRs (Architecture Decision Records)** (minimum 4)
   - Examples: “Why GitOps”, “Why Strimzi”, “Observability choices”, “Autoscaling approach”.

### B) Platform Behavior
- A working Kafka cluster in Kubernetes.
- At least 2 services:
  - **producer**: HTTP endpoint that writes events to Kafka
  - **consumer**: consumes events, processes, and exposes metrics
- A load generator (job or script) to create controlled load and consumer lag.

### C) Observability (must be demonstrated)
- Metrics collected and queryable in Prometheus.
- Grafana dashboards exist for:
  - Kubernetes cluster health
  - Argo CD health/sync
  - Kafka health + consumer lag
  - Application SLIs (throughput, latency, errors)
- Alerts configured and testable:
  - Argo app OutOfSync/Degraded
  - Consumer lag threshold exceeded
  - Pods pending / no capacity
  - Kafka broker unavailable (or similar)

### D) GitHub Actions (must enforce gates)
PR must fail if:
- YAML is invalid / lint fails
- Kustomize or Helm render fails (whichever you use)
- Rendered manifests fail schema validation (kubeconform)
- Prometheus rules fail validation (promtool), if you have rules
- Security scan finds HIGH/CRITICAL issues (Trivy config scan)

Optional but strong:
- A “smoke test” workflow that spins up a Kind cluster and bootstraps Argo CD + your root app.

---

## Milestones (Implementation Plan)

### Milestone 1 — Cluster & GitOps Bootstrap
**Requirements**
- One command (or minimal steps) to create a local cluster.
- Install Argo CD (bootstrap allowed).
- Choose GitOps pattern: root app / app-of-apps / application sets.

**Acceptance Criteria**
- From a blank machine: create cluster + install Argo CD + point it at this repo.
- After bootstrap, all changes are Git-driven.

**Evidence**
- A documented “bootstrap demo”:
  - commands
  - expected Argo apps and health states

---

### Milestone 2 — Platform Baseline (K8s Discipline)
**Requirements**
- Namespaces separating concerns (platform vs apps vs data).
- RBAC: demonstrate least privilege for at least one service account.
- Resource controls: requests/limits on all app pods; optionally quotas/limit ranges.
- Readiness/liveness probes on all app pods.

**Acceptance Criteria**
- No app pod runs without requests/limits.
- Demonstrate a service account that cannot perform privileged actions (e.g., list secrets).
- Rolling update works without downtime (basic).

**Evidence**
- A runbook section: how to debug CrashLoopBackOff/readiness failures.

---

### Milestone 3 — Kafka on Kubernetes (Strimzi) + Operational Controls
**Requirements**
- Kafka cluster deployed via operator.
- Topics defined declaratively (Git-managed).
- Producer/consumer use Kafka with correct consumer group semantics.
- Consumer lag is measurable (Kafka exporter and/or app metrics).

**Acceptance Criteria**
- Create load and show:
  - topic exists with partitions > 1
  - consumer group exists
  - lag increases/decreases predictably
- Restart a broker pod; system recovers.

**Evidence**
- Runbook: “Broker restart / degraded Kafka”.
- Dashboard panel showing consumer lag.

---

### Milestone 4 — Observability: Metrics + Logs + Alerts
**Metrics Requirements**
Prometheus must scrape:
- Kubernetes components (via kube-prometheus-stack)
- Argo CD metrics
- Kafka/Strimzi metrics
- Your apps (`/metrics`)

Grafana dashboards must include:
- cluster overview
- Argo CD sync health
- Kafka health + consumer lag
- app SLIs: RPS, latency (p95), error rate

**Logs Requirements**
- Central log aggregation (Loki or equivalent)
- Logs include structured fields (minimum): `service`, `level`, plus a correlation identifier (`request_id` or `event_id`) if applicable.

**Alerts Requirements**
Minimum 4 alerts:
1. Argo Application OutOfSync for > N minutes
2. Consumer lag > threshold for > N minutes
3. Pods Pending for > N minutes
4. Kafka broker unavailable OR under-replicated partitions (or similar)

**Acceptance Criteria**
- Intentionally trigger at least 2 alerts and show they fire and resolve.

**Evidence**
- A “game day” doc:
  - how you triggered it
  - what you observed
  - how you fixed it
  - prevention actions

---

### Milestone 5 — GitHub Actions Quality Gates (Mandatory)
**Required workflows**
1. **CI** on PR + main:
   - YAML lint
   - Shellcheck (if scripts exist)
   - Render step: `kustomize build` or `helm template`
   - Schema validation with kubeconform against a target K8s version
   - promtool rule validation (if rule files exist)

2. **Security** on PR + scheduled:
   - Secret scan (gitleaks)
   - Trivy config scan (HIGH/CRITICAL should fail)

3. **Optional smoke test** (strongly recommended):
   - Create Kind cluster
   - Install Argo CD
   - Apply root app
   - Wait for key components to be Ready

**Acceptance Criteria**
- A PR with a broken manifest cannot merge.
- A PR with a leaked fake secret is detected.
- A PR that breaks rendered output fails in CI.

**Evidence**
- CI logs from a failing PR and a fixed PR.

---

### Milestone 6 — Autoscaling with Karpenter (Advanced Track, $0)
**Goal**
Demonstrate node provisioning triggered by unschedulable pods, plus scale-down/consolidation behavior—using Karpenter concepts and APIs.

**Requirements**
- Implement Karpenter in a local-friendly way (e.g., Cluster API provider path).
- Define at least two capacity profiles (conceptual):
  - general services
  - batch/compute-heavy workloads
- Placement controls:
  - node selectors / affinity
  - taints / tolerations
  - topology spread constraints (optional)

**Acceptance Criteria**
- Force pods pending due to insufficient capacity.
- Provisioning adds capacity; pods schedule.
- Demonstrate scale-down after load stops.

**If you cannot fully implement Karpenter locally**
You may substitute a local autoscaler for the live demo only if:
- you still provide a Karpenter design + manifests + runbook,
- you document exactly what would change in AWS/EKS, and
- you can answer Karpenter interview questions (see Interview Mapping).

---

## Required Test Scenarios (“Game Days”)
You must implement and document these:

1. **GitOps drift**
   - Manually change a live resource (`kubectl edit`) and show Argo detects drift and self-heals (or blocks, per your policy).

2. **Bad deploy rollback**
   - Introduce a breaking config change to the consumer (crashloop).
   - Show alert triggers + rollback via Git revert.

3. **Kafka lag incident**
   - Increase producer rate so lag spikes.
   - Mitigate by scaling consumer replicas and/or increasing partitions (justify the choice).

4. **Capacity / scheduling incident**
   - Create pods pending (requests too high, constraints, scaling).
   - Resolve by provisioning capacity (Karpenter track) or adjusting constraints, and document.

---

## Scoring Rubric (Self-Assessment)

### Baseline (Pass)
- GitOps works, Kafka works, dashboards exist, CI gates exist, at least 2 alerts demonstrably fire/resolve.

### Strong
- Runbooks are actionable, alerts are high-signal, lag incident handled correctly, PR gates are strict and useful.

### Excellent (Senior Signal)
- Clear ADRs, strong SLI/SLO reasoning, cleanly executed game days, coherent autoscaling story (ideally Karpenter live), deep troubleshooting.

---

## Interview Mapping (What you will be able to answer)
You should be prepared to discuss, with concrete examples:
- GitOps workflows: promotion, rollback, drift, separation of duties
- Kafka operations: partitions vs consumers, replication, lag causes, rebalancing implications
- K8s operations: probes, resources, RBAC, network policies, failure modes
- Observability: what you alert on and why, what dashboards show, reducing noise
- Autoscaling: HPA vs node provisioning, scheduling constraints, disruption budgets

---

## Start Here (First 90 minutes Checklist)
1. Create the GitHub repo (public).
2. Create a local Kubernetes cluster (kind/k3d).
3. Install Argo CD (bootstrap).
4. Define your GitOps root app and point it at this repo.
5. Add a placeholder app (namespace + configmap) to validate the GitOps loop.
6. Add GitHub Actions CI workflow and create a PR that intentionally fails to confirm gates work.

---

## Optional: Add Realism With Environments
Implement “dev” and “prod” environments with different parameters (replicas/limits/retention) and promote by PR. This requires no cloud and forces good GitOps discipline.
