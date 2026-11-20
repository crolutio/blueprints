#!/usr/bin/env bash
# Free-GPU check: per GPU node -> product, allocatable GPUs, GPUs requested by scheduled (non-finished)
# pods, free GPUs; then totals per GPU type and whether each blueprint fits.
# Read-only (oc get only). Needs: oc, jq.
set -euo pipefail

# JSON goes through temp files: on big clusters it is too large for a command-line argument
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
oc get nodes -l nvidia.com/gpu.present=true -o json > "$T/nodes.json"
oc get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o json \
  | jq -c '{items: [.items[] | {spec: {nodeName: .spec.nodeName, containers: [.spec.containers[] | {resources}], initContainers: [.spec.initContainers[]? | {resources}]}}]}' > "$T/pods.json"

rows="$(jq -cn --slurpfile n "$T/nodes.json" --slurpfile p "$T/pods.json" '$n[0] as $nodes | $p[0] as $pods |
  def gpu(c): ((c.resources.requests["nvidia.com/gpu"] // c.resources.limits["nvidia.com/gpu"] // "0") | tonumber);
  # GPUs used per node = sum over scheduled pods of max(sum(containers), max(initContainers))
  ($pods.items | map(select(.spec.nodeName != null)) |
     map({node: .spec.nodeName,
          g: ([([.spec.containers[] | gpu(.)] | add // 0), ([.spec.initContainers[]? | gpu(.)] | max // 0)] | max)})
     | group_by(.node) | map({key: .[0].node, value: (map(.g) | add)}) | from_entries) as $used
  | $nodes.items | map({
        node: .metadata.name,
        product: (.metadata.labels["nvidia.com/gpu.product"] // "unknown"),
        alloc: ((.status.allocatable["nvidia.com/gpu"] // "0") | tonumber),
        used: ($used[.metadata.name] // 0),
        schedulable: ((.spec.unschedulable // false) | not)
      }) | map(. + {free: (if .schedulable then ([.alloc - .used, 0] | max) else 0 end)})')"

jq -r '"NODE\tPRODUCT\tALLOCATABLE\tUSED\tFREE\tSCHEDULABLE", (.[] | "\(.node)\t\(.product)\t\(.alloc)\t\(.used)\t\(.free)\t\(.schedulable)")' <<<"$rows" | column -t -s $'\t'
echo
jq -r '
    "FREE BY GPU TYPE",
    (group_by(.product)[] | "  \(.[0].product): \(map(.free) | add) free on \(map(select(.free > 0)) | length) node(s)"),
    "",
    ( (map(select(.product == "NVIDIA-H200") | .free) | add // 0) as $h
    | (map(select(.product == "NVIDIA-L40S") | .free) | add // 0) as $l
    | "FLYWHEEL (needs 2 GPUs: candidate NIM + judge NIM; they take any free GPU): \(if ($h + $l) >= 2 then "OK (\($h + $l) free)" else "NOT ENOUGH free GPUs (\($h + $l)). Wait until 2 are free." end)",
      "RAG (needs 2 x L40S): \(if $l >= 2 then "OK (\($l) L40S free)" else "NOT ENOUGH L40S free (\($l))" end)" )
  ' <<<"$rows"
