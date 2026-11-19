#!/usr/bin/env bash
# Image pull check: proves the cluster's nodes can pull each NON-nvcr.io image the deployments
# need (docker.io, registry.redhat.io), plus one nvcr.io image as a control.
# Creates one tiny pod per image in the namespace (no GPU, explicit requests/limits),
# reads its events (Pulled / Failed), then deletes ONLY the pods it created (label pull-check=nvaie).
# Usage: deploy/scripts/pull-check.sh flywheel|rag|all   [namespace]
set -uo pipefail
WHAT="${1:-all}"; NS="${2:-nvaie-test}"
FLYWHEEL_IMAGES=(
  docker.io/library/elasticsearch:8.12.2
  docker.io/library/mongo:7.0.14
  docker.io/library/redis:7.2.5-alpine
  docker.io/bitnamilegacy/postgresql:16.1.0-debian-11-r20
  docker.io/bitnamilegacy/postgresql:16.2.0-debian-11-r1
  docker.io/volcanosh/vc-controller-manager:v1.15.4
  docker.io/volcanosh/vc-scheduler:v1.15.4
  registry.redhat.io/ubi9/nginx-126:1-1777855212
  nvcr.io/nvidia/nemo-microservices/entity-store:25.08
)
RAG_IMAGES=(
  docker.io/library/elasticsearch:9.3.0
  docker.io/elastic/eck-operator:3.3.2
  docker.io/library/redis:8.2.1
  docker.io/chrislusf/seaweedfs:3.73
  nvcr.io/nvidia/blueprint/rag-server:2.6.0
)
case "$WHAT" in flywheel) IMAGES=("${FLYWHEEL_IMAGES[@]}");; rag) IMAGES=("${RAG_IMAGES[@]}");; *) IMAGES=("${FLYWHEEL_IMAGES[@]}" "${RAG_IMAGES[@]}");; esac

i=0
for img in "${IMAGES[@]}"; do
  i=$((i+1)); name="pull-check-$i"
  oc -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
  labels: {pull-check: nvaie}
  annotations: {image: "$img"}
spec:
  restartPolicy: Never
  imagePullSecrets: [{name: ngc-registry-default}]
  containers:
  - name: c
    image: $img
    imagePullPolicy: Always
    command: ["/bin/sh", "-c", "exit 0"]
    resources:
      requests: {cpu: 10m, memory: 16Mi}
      limits: {cpu: 100m, memory: 64Mi}
    securityContext:
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
EOF
done
# A first "Failed"/"BackOff" is often temporary (slow or large download, kubelet pull rate limit):
# the kubelet retries by itself. So keep waiting until the image is Pulled, or the error is a
# permanent one (auth / not found / blocked), or 10 minutes pass.
HARD='unauthorized|denied|forbidden|not found|manifest unknown|no such host|blocked'
ev() { oc -n "$NS" get events --field-selector involvedObject.name="$1" -o jsonpath='{range .items[*]}{.reason}: {.message}{"\n"}{end}' 2>/dev/null; }
echo "Waiting up to 10 minutes for pulls (large images such as Elasticsearch take a few minutes)..."
for _ in $(seq 1 ${PULL_ROUNDS:-60}); do
  pending=0
  for n in $(seq 1 $i); do
    e=$(ev pull-check-$n)
    grep -q '^Pulled:' <<<"$e" || grep -qiE "$HARD" <<<"$e" || pending=1
  done
  [ $pending = 0 ] && break; sleep 10
done
echo; printf "%-8s %s\n" RESULT IMAGE
for n in $(seq 1 $i); do
  img=$(oc -n "$NS" get pod pull-check-$n -o jsonpath='{.metadata.annotations.image}')
  e=$(ev pull-check-$n)
  if grep -q '^Pulled:' <<<"$e"; then res=OK
  elif grep -qiE "$HARD" <<<"$e"; then res=FAILED
  else res=TIMEOUT; fi
  printf "%-8s %s\n" "$res" "$img"
  [ "$res" = OK ] || grep -E '^(Failed|BackOff|Warning|Pulling)' <<<"$e" | tail -2 | cut -c1-300 | sed 's/^/         /'
done
oc -n "$NS" delete pod -l pull-check=nvaie --wait=false >/dev/null
echo "(pull-check pods deleted; an image without /bin/sh still counts as OK if it was Pulled)"
