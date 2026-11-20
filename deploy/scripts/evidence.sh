#!/usr/bin/env bash
# Evidence capture (read-only). Writes a timestamped folder + .tar.gz with cluster state,
# Helm release data (values with secrets NOT included: secrets are pre-created, not in values),
# GPU placement, NIM/NeMo custom resources, events, and logs of the key pods.
# Usage: deploy/scripts/evidence.sh flywheel|rag <release> [namespace] [extra files to include...]
set -uo pipefail
KIND="$1"; REL="$2"; NS="${3:-nvaie-test}"; shift 3 || shift $#
TS="$(date -u +%Y%m%dT%H%M%SZ)"; E="evidence-$KIND-$TS"; mkdir -p "$E"/logs
D="$(cd "$(dirname "$0")" && pwd)"
cap() { local f="$1"; shift; { echo "\$ $*"; "$@" 2>&1; } > "$E/$f.txt"; }

cap 00-context        oc whoami --show-server
cap 01-clusterversion oc get clusterversion
cap 02-helm-status    helm status "$REL" -n "$NS"
cap 03-helm-values    helm get values "$REL" -n "$NS"
cap 04-helm-history   helm history "$REL" -n "$NS"
cap 05-pods           oc get pods -n "$NS" -o wide
cap 06-all            oc get deploy,sts,job,svc,cm,pvc -n "$NS" -o wide
cap 07-nim-crs        oc get nimcache,nimservice -n "$NS" -o wide
cap 08-gpu-pods       bash -c "oc get pods -n $NS -o json | jq -r '.items[] | select([.spec.containers[].resources.limits[\"nvidia.com/gpu\"]?, .spec.containers[].resources.requests[\"nvidia.com/gpu\"]?] | map(select(.!=null)) | length>0) | [.metadata.name, .spec.nodeName, .status.phase] | @tsv'"
cap 09-gpu-nodes      oc get nodes -l nvidia.com/gpu.present=true -L nvidia.com/gpu.product
cap 10-gpu-free       bash "$D/gpu-free.sh"
cap 11-events         oc get events -n "$NS" --sort-by=.lastTimestamp
cap 12-scc-used       bash -c "oc get pods -n $NS -o custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\\.io/scc,SA:.spec.serviceAccountName"
if [ "$KIND" = flywheel ]; then
  cap 20-eval-jobs    oc get jobs -n "$NS" -o wide
  for d in df-api-deployment df-celery-worker-deployment df-celery-parent-worker-deployment; do oc logs -n "$NS" deploy/$d --tail=2000 > "$E/logs/$d.log" 2>&1; done
  for d in $(oc get deploy -n "$NS" -o name | grep -E 'evaluator|deployment-management|nim-proxy|entity-store|data-store'); do oc logs -n "$NS" "$d" --all-containers --tail=2000 > "$E/logs/$(basename "$d").log" 2>&1; done
else
  for d in rag-server ingestor-server rag-nv-ingest rag-elasticsearch; do oc logs -n "$NS" deploy/$d --tail=2000 > "$E/logs/$d.log" 2>&1; done
fi
for p in $(oc get pods -n "$NS" -o name | grep -E 'nim-llm|nemotron-embedding|modeldeployment|llama'); do oc logs -n "$NS" "$p" --tail=500 > "$E/logs/$(basename "$p").log" 2>&1; done
for f in "$@"; do [ -e "$f" ] && cp -r "$f" "$E/"; done
tar czf "$E.tar.gz" "$E" && echo "Evidence: $PWD/$E.tar.gz" && ls "$E"
