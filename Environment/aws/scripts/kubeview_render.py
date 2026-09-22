#!/usr/bin/env python3
"""
Renders a live EKS cluster map from KubeView's /api/fetch/{namespace} JSON.

KubeView (https://github.com/benc-uk/kubeview) has no built-in static
export -- its backend returns raw per-namespace K8s object lists (the same
data its own frontend renders into a graph client-side), not an image. This
script replicates that relationship logic (ownerReferences -> workload,
label-selector -> Service, Ingress backend -> Service) and renders it with
Graphviz instead, so it can be dropped into a README.

Deliberately never reads Secret/ConfigMap .data/.stringData -- structural
references only (which workload points at which secret NAME), since
KubeView's API returns full secret values over the port-forward and those
must never end up in an image that gets committed anywhere.

Usage: see the "Live cluster map" section of ../README.MD for the full
deploy -> port-forward -> fetch -> render -> cleanup sequence. In short:

    python3 kubeview_render.py <dir-of-namespace.json-files> <output.dot>
    dot -Tpng <output.dot> -o <output.png>
"""
import json
import os
import sys
from datetime import date

WORKLOAD_KEYS = {
    "deployments": "Deployment",
    "statefulsets": "StatefulSet",
    "daemonsets": "DaemonSet",
}


def load(graph_dir, ns):
    with open(os.path.join(graph_dir, f"{ns}.json")) as f:
        return json.load(f)


def labels_match(selector, pod_labels):
    if not selector:
        return False
    return all(pod_labels.get(k) == v for k, v in selector.items())


def build_namespace(d):
    """Returns (workloads, services, ingresses, config_edges) for one namespace's raw KubeView JSON."""
    workloads = {}  # workload_id -> {kind, name, ready, total, [_synthetic_count]}

    for key, kind in WORKLOAD_KEYS.items():
        for obj in d.get(key, []):
            name = obj["metadata"]["name"]
            wid = f"{kind}/{name}"
            status = obj.get("status", {})
            ready = status.get("readyReplicas", status.get("numberReady", 0)) or 0
            total = status.get("replicas", status.get("desiredNumberScheduled", 0)) or 0
            workloads[wid] = {"kind": kind, "name": name, "ready": ready, "total": total}

    # ReplicaSet -> its owning Deployment (so Deployment-owned pods roll up
    # to the Deployment, not the transient ReplicaSet).
    rs_to_owner = {}
    for rs in d.get("replicasets", []):
        owners = rs["metadata"].get("ownerReferences", [])
        if owners:
            o = owners[0]
            rs_to_owner[rs["metadata"]["name"]] = f'{o["kind"]}/{o["name"]}'

    # Pods: attribute to their controlling workload. Pods owned directly by
    # something outside WORKLOAD_KEYS (an argoproj.io Rollout, a Strimzi
    # StrimziPodSet, ...) synthesize a workload node from the owner
    # reference alone -- KubeView's RBAC doesn't fetch those CRDs, but the
    # ownerReference naming them is still right there on the pod.
    pod_label_samples = {}  # workload_id -> one representative pod's labels
    for pod in d.get("pods", []):
        owners = pod["metadata"].get("ownerReferences", [])
        labels = pod["metadata"].get("labels", {})
        is_ready = any(
            c.get("type") == "Ready" and c.get("status") == "True"
            for c in pod.get("status", {}).get("conditions", [])
        )

        if owners:
            o = owners[0]
            if o["kind"] == "ReplicaSet":
                wid = rs_to_owner.get(o["name"], f'ReplicaSet/{o["name"]}')
            else:
                wid = f'{o["kind"]}/{o["name"]}'
        else:
            wid = f'Pod/{pod["metadata"]["name"]}'

        if wid not in workloads:
            kind, _, name = wid.partition("/")
            workloads[wid] = {"kind": kind, "name": name, "ready": 0, "total": 0, "_synthetic_count": True}

        if workloads[wid].get("_synthetic_count"):
            workloads[wid]["total"] += 1
            workloads[wid]["ready"] += 1 if is_ready else 0

        pod_label_samples.setdefault(wid, labels)

    services = []
    for svc in d.get("services", []):
        selector = svc.get("spec", {}).get("selector", {})
        matched = [wid for wid, lbls in pod_label_samples.items() if labels_match(selector, lbls)]
        services.append({"name": svc["metadata"]["name"], "matched": matched})

    ingresses = []
    for ing in d.get("ingresses", []):
        for rule in ing.get("spec", {}).get("rules", []):
            host = rule.get("host", "*")
            for path in rule.get("http", {}).get("paths", []):
                backend_svc = path.get("backend", {}).get("service", {}).get("name")
                if backend_svc:
                    ingresses.append({"name": ing["metadata"]["name"], "host": host, "service": backend_svc})

    # Structural only -- which ConfigMap/Secret/PVC NAMES (never Secret
    # values) each workload's pod template references via envFrom/volumes.
    config_edges = []  # (workload_id, kind, name)
    for key, kind in WORKLOAD_KEYS.items():
        for obj in d.get(key, []):
            wid = f'{kind}/{obj["metadata"]["name"]}'
            pod_spec = obj.get("spec", {}).get("template", {}).get("spec", {})
            for c in pod_spec.get("containers", []):
                for ef in c.get("envFrom", []):
                    if "configMapRef" in ef:
                        config_edges.append((wid, "ConfigMap", ef["configMapRef"]["name"]))
                    if "secretRef" in ef:
                        config_edges.append((wid, "Secret", ef["secretRef"]["name"]))
            for v in pod_spec.get("volumes", []):
                if "secret" in v:
                    config_edges.append((wid, "Secret", v["secret"]["secretName"]))
                if "persistentVolumeClaim" in v:
                    config_edges.append((wid, "PVC", v["persistentVolumeClaim"]["claimName"]))

    return workloads, services, ingresses, config_edges


def dot_id(ns, s):
    return '"' + ns + "__" + s.replace('"', "") + '"'


COLOR_BY_KIND = {
    "Deployment": "#123762",
    "StatefulSet": "#123762",
    "DaemonSet": "#123762",
    "Rollout": "#2e2410",
    "ReplicaSet": "#1c2d1c",
}


def render(namespaces, graph_dir, generated_on):
    lines = [
        "digraph EKS {",
        "  rankdir=LR;",
        '  bgcolor="#0a1f3b";',
        '  fontname="Helvetica"; fontcolor="#eef4ff";',
        '  node [fontname="Helvetica", fontsize=11, color="#4a6c98", fontcolor="#eef4ff"];',
        '  edge [fontname="Helvetica", fontsize=9, color="#6f93bf", fontcolor="#9fbfe0", arrowsize=0.7];',
        f'  labelloc="t"; label="Live EKS Cluster Map -- splitwise-dev (via KubeView, generated {generated_on})"; fontsize=18; fontcolor="#eef4ff";',
    ]

    for ns in namespaces:
        d = load(graph_dir, ns)
        workloads, services, ingresses, config_edges = build_namespace(d)
        lines.append(f'  subgraph "cluster_{ns}" {{')
        lines.append(f'    label="namespace: {ns}"; fontsize=14; fontcolor="#7fd8dc"; color="#2c4d78"; style=dashed; labeljust=l;')

        for wid, w in workloads.items():
            if w.get("_synthetic_count") and w["total"] == 0:
                continue  # e.g. an owner whose pods have all scaled to 0
            label = f'{w["kind"]}\\n{w["name"]}\\n{w["ready"]}/{w["total"]}'
            fill = COLOR_BY_KIND.get(w["kind"], "#123762")
            shape = "component" if w["kind"] == "Rollout" else "box"
            lines.append(f'    {dot_id(ns, wid)} [label="{label}", shape={shape}, style=filled, fillcolor="{fill}"];')

        for svc in services:
            if not svc["matched"]:
                continue
            sid = f'Service/{svc["name"]}'
            lines.append(f'    {dot_id(ns, sid)} [label="Service\\n{svc["name"]}", shape=ellipse, style=filled, fillcolor="#1c2d4a"];')
            for wid in svc["matched"]:
                if wid in workloads:
                    lines.append(f'    {dot_id(ns, sid)} -> {dot_id(ns, wid)} [label="selects", dir=back];')

        for ing in ingresses:
            iid = f'Ingress/{ing["name"]}/{ing["host"]}'
            lines.append(f'    {dot_id(ns, iid)} [label="Ingress\\n{ing["host"]}", shape=cds, style=filled, fillcolor="#ffb020", fontcolor="#1a1200"];')
            sid = f'Service/{ing["service"]}'
            lines.append(f'    {dot_id(ns, iid)} -> {dot_id(ns, sid)} [label="routes"];')

        seen_cfg = set()
        for wid, kind, name in config_edges:
            if wid not in workloads:
                continue
            cid = f"{kind}/{name}"
            if (ns, cid) not in seen_cfg:
                seen_cfg.add((ns, cid))
                shape = "note" if kind in ("ConfigMap", "Secret") else "cylinder"
                fill = "#3a2d4a" if kind == "Secret" else ("#2d3a4a" if kind == "ConfigMap" else "#2d4a3a")
                lines.append(f'    {dot_id(ns, cid)} [label="{kind}\\n{name}", shape={shape}, style=filled, fillcolor="{fill}"];')
            lines.append(f'    {dot_id(ns, wid)} -> {dot_id(ns, cid)} [label="{kind.lower()}", style=dotted];')

        lines.append("  }")

    lines.append("}")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <dir-of-namespace.json-files> <output.dot>", file=sys.stderr)
        sys.exit(1)
    graph_dir, out_path = sys.argv[1], sys.argv[2]
    namespaces = [f[:-5] for f in sorted(os.listdir(graph_dir)) if f.endswith(".json")]
    dot_source = render(namespaces, graph_dir, date.today().isoformat())
    with open(out_path, "w") as f:
        f.write(dot_source)
    print(f"wrote {out_path} ({len(namespaces)} namespaces: {', '.join(namespaces)})")
