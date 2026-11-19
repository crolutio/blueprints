#!/usr/bin/env bash
# Pre-flight: every check from RUNBOOK section 0 in one run, with PASS / WARN / FAIL per line
# and the exact action for anything that is not PASS.
#
# Changes it makes (all inside the namespace, all labelled, the test objects are removed again):
#   - creates the secrets ngc-registry-default and ngc-api ONLY if they are missing (needs $NGC_API_KEY)
#   - one 1Gi test PVC + Job (storage write test), deleted at the end of the test
#   - one tiny pod per image (pull check, via pull-check.sh), deleted at the end of the test
# Nothing cluster-scoped is created or changed.
#
# Usage (from the folder that contains RUNBOOK.html, after `oc login`):
#   export NS=nvaie-test SC=ocs-storagecluster-ceph-rbd
#   read -rsp "NGC API key: " NGC_API_KEY; echo; export NGC_API_KEY
#   bash deploy/scripts/preflight.sh
set -uo pipefail
NS="${NS:-nvaie-test}"; SC="${SC:-ocs-storagecluster-ceph-rbd}"
D="$(cd "$(dirname "$0")/.." && pwd)"
TEST_IMAGE=registry.redhat.io/ubi9/nginx-126:1-1777855212
NFAIL=0; NWARN=0; ACTIONS=()
pass() { printf '  PASS  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; NWARN=$((NWARN+1)); [ -n "${2:-}" ] && ACTIONS+=("WARN: $2"); }
fail() { printf '  FAIL  %s\n' "$1"; NFAIL=$((NFAIL+1)); [ -n "${2:-}" ] && ACTIONS+=("FAIL: $2"); }
info() { printf '  info  %s\n' "$1"; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }   # ver_ge HAVE NEED
section() { printf '\n== %s\n' "$1"; }

echo "Pre-flight for namespace '$NS', StorageClass '$SC'  ($(date '+%Y-%m-%d %H:%M'))"

# ---------------------------------------------------------------- 0.1 tools
section "Tools and packages"
for t in oc helm jq curl column sha256sum; do
  command -v "$t" >/dev/null && pass "$t found" || fail "$t not found" "install $t on this workstation"
done
if command -v helm >/dev/null; then
  hv=$(helm version --template '{{.Version}}' 2>/dev/null | tr -d v)
  ver_ge "$hv" 3.17.0 && pass "helm $hv (>= 3.17)" || fail "helm $hv is older than 3.17" "install helm 3.17 or newer (tested 3.18.4)"
fi
if command -v oc >/dev/null; then
  ov=$(oc version --client -o json 2>/dev/null | jq -r '.releaseClientVersion // .clientVersion.gitVersion' 2>/dev/null)
  info "oc client $ov"
fi
if (cd "$D/packages" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then pass "chart packages intact (SHA256SUMS)"
else fail "chart packages do not match SHA256SUMS" "re-copy the deploy/packages folder"; fi
if grep -q '"1.8.3"' "$D/flywheel/values-nvaie-common.yaml" && grep -q '"1.8.3"' "$D/rag/values-nvaie.yaml"; then
  pass "8B model tag 1.8.3 set in both values files"
else fail "8B model tag not set in the values files" "re-copy deploy/flywheel and deploy/rag"; fi

# ---------------------------------------------------------------- login, namespace, rights
section "Login, namespace, permissions"
if ! who=$(oc whoami 2>/dev/null); then
  fail "not logged in to the cluster" "run oc login first"
  echo; echo "RESULT: NOT READY (log in and run again)"; exit 1
fi
pass "logged in as $who ($(oc whoami --show-server 2>/dev/null))"
phase=$(oc get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$phase" = Active ] && pass "namespace $NS is Active" || { fail "namespace $NS not found" "ask the client to create namespace $NS"; echo; echo "RESULT: NOT READY"; exit 1; }
for r in customresourcedefinitions clusterroles; do
  [ "$(oc auth can-i create $r 2>/dev/null)" = yes ] && pass "can create $r" \
    || fail "cannot create $r (needed for the flywheel and the operators)" "a cluster-admin must run the installs (RUNBOOK 0.4 and 1.2)"
done

# ---------------------------------------------------------------- 0.3.1 quotas
section "Quotas and limits (0.3.1)"
quotas=$(oc get resourcequota -n "$NS" -o name 2>/dev/null); lrs=$(oc get limitrange -n "$NS" -o name 2>/dev/null)
if [ -z "$quotas" ]; then pass "no ResourceQuota in $NS"
else
  warn "ResourceQuota present; compare with the needs in 0.3.1" "check the quota table in RUNBOOK 0.3.1 against: oc describe resourcequota -n $NS"
  oc describe resourcequota -n "$NS" | sed 's/^/        /'
  [ -n "$lrs" ] && pass "LimitRange present (defaults for pods NeMo creates)" \
    || warn "quota but no LimitRange" "ask the client for a LimitRange in $NS, or pods NeMo creates at runtime may be rejected (0.3.1)"
fi

# ---------------------------------------------------------------- 0.3.2 storage class
section "StorageClass (0.3.2)"
if oc get storageclass "$SC" >/dev/null 2>&1; then pass "StorageClass $SC exists"
else
  rbd=$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.provisioner}{"\n"}{end}' | awk '$2 ~ /rbd/ {print $1}' | head -1)
  fail "StorageClass $SC not found${rbd:+ (Ceph RBD class found: $rbd)}" \
    "export SC=${rbd:-<rbd-class>} && sed -i \"s/ocs-storagecluster-ceph-rbd/\$SC/g\" deploy/flywheel/values-*.yaml deploy/rag/values-nvaie.yaml   then run this script again"
fi

# ---------------------------------------------------------------- 0.3.3 operators
section "Operators already on the cluster (0.3.3, decides 0.4)"
crd() { oc get crd "$1" >/dev/null 2>&1; }
imgs=$(oc get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' 2>/dev/null | tr ' ' '\n' | sort -u)
if crd nimservices.apps.nvidia.com; then
  # image may be tagged (helm install) or pinned by digest (OperatorHub/OLM install)
  nimimg=$(grep -iE 'nim-operator[^/]*[:@]' <<<"$imgs" | head -1)
  t=$(sed -n 's/.*nim-operator[^/:@]*:v\{0,1\}\([0-9][0-9.]*\).*/\1/p' <<<"$nimimg")
  # OperatorHub install: read the version from its ClusterServiceVersion
  [ -z "$t" ] && t=$(oc get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null \
                     | awk 'tolower($1) ~ /nim/ {print $2; exit}' | sed 's/^v//')
  if [ -z "$nimimg" ] && [ -z "$t" ]; then warn "NIM Operator CRDs exist but no operator pod found" "ask the client who owns the NIM Operator and whether it is running (oc get pods -A | grep -i nim; oc get csv -A | grep -i nim)"
  elif [ -z "$t" ]; then warn "NIM Operator pod found ($nimimg) but version unknown" "confirm the version is >= 3.0.2: oc get csv -A | grep -i nim"
  elif ver_ge "$t" 3.0.2; then pass "NIM Operator $t present (>= 3.0.2): nothing to install"
  else fail "NIM Operator $t is older than 3.0.2" "ask the client to upgrade the NIM Operator (RAG needs >= 3.0.2)"; fi
else warn "NIM Operator not installed" "with client approval (A3), install it: RUNBOOK 0.4, NIM Operator command"; fi
if crd elasticsearches.elasticsearch.k8s.elastic.co; then
  pass "ECK (Elasticsearch operator) present: nothing to install (RUNBOOK 2.3 checks it manages $NS)"
else warn "ECK operator not installed" "with client approval (A4), install it: RUNBOOK 0.4, ECK command"; fi
if crd queues.scheduling.volcano.sh; then
  fail "Volcano is already installed by someone else" "STOP: do not install a second Volcano; contact us"
else pass "Volcano not installed: we install v1.15.4 before the flywheel (RUNBOOK 1.2, approval A1)"; fi
if crd nemotrainingjobs.nvidia.com; then
  fail "NeMo Operator CRDs already exist (someone else runs NeMo)" "STOP: contact us before installing the flywheel"
else pass "no other NeMo installation"; fi

# ---------------------------------------------------------------- 0.3.4 kueue
section "Kueue (0.3.4)"
labels=$(oc get ns "$NS" -o jsonpath='{.metadata.labels}' 2>/dev/null)
lq=$(oc get localqueue -n "$NS" -o name 2>/dev/null)
if grep -qi kueue <<<"$labels" || [ -n "$lq" ]; then
  warn "namespace looks Kueue-managed (${lq:-label only})" "set kueue.queueName: <localqueue> in deploy/flywheel/values-nvaie-common.yaml and deploy/rag/values-nvaie.yaml, and ask the client to exempt $NS for pods NeMo creates (RUNBOOK 0.3.4)"
else pass "namespace is not Kueue-managed"; fi

# ---------------------------------------------------------------- 0.3.5 pid limit
section "Kubelet PID limit (0.3.5, record only)"
N=$(oc get nodes -l nvidia.com/gpu.product=NVIDIA-L40S -o name 2>/dev/null | head -1 | cut -d/ -f2)
if [ -n "$N" ]; then
  pid=$(oc get --raw "/api/v1/nodes/$N/proxy/configz" 2>/dev/null | jq -r '.kubeletconfig.podPidsLimit // "unknown"')
  info "podPidsLimit on $N: $pid (NVIDIA's OpenShift overlay already handles low limits)"
else warn "no node labelled nvidia.com/gpu.product=NVIDIA-L40S" "confirm the GPU node labels with the client (RAG needs 2 x L40S)"; fi

# ---------------------------------------------------------------- secrets
section "Secrets"
for s in ngc-registry-default ngc-api; do
  if oc get secret "$s" -n "$NS" >/dev/null 2>&1; then pass "secret $s exists"
  elif [ -z "${NGC_API_KEY:-}" ]; then fail "secret $s missing and NGC_API_KEY is not set" "export NGC_API_KEY (RUNBOOK 0.2) and run this script again"
  else
    if [ "$s" = ngc-registry-default ]; then
      oc create secret docker-registry ngc-registry-default -n "$NS" --docker-server=nvcr.io \
        --docker-username='$oauthtoken' --docker-password="$NGC_API_KEY" >/dev/null
    else
      oc create secret generic ngc-api -n "$NS" --from-literal=NGC_API_KEY="$NGC_API_KEY" >/dev/null
    fi && pass "secret $s created" || fail "could not create secret $s" "check permissions in $NS"
  fi
done
oc secrets link default ngc-registry-default --for=pull -n "$NS" >/dev/null 2>&1 \
  && pass "default ServiceAccount can use ngc-registry-default" || warn "could not link the pull secret to the default ServiceAccount" "oc secrets link default ngc-registry-default --for=pull -n $NS"

# ---------------------------------------------------------------- storage write test
# Runs as a Job, not a bare pod: a bare pod created by an admin can be admitted under any SCC the
# admin may use; a Job's pod is admitted like the real workloads (service account permissions only).
# This also shows whether Kueue holds Jobs that carry no queue label (the flywheel's eval Jobs cannot).
section "Storage write test (as a real workload: SCC + $SC + Kueue)"
if oc get storageclass "$SC" >/dev/null 2>&1; then
  oc delete job,pod,pvc -n "$NS" -l nvaie-test=rwtest --wait=true >/dev/null 2>&1
  cat <<EOF | oc apply -n "$NS" -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nvaie-rwtest, labels: {nvaie-test: rwtest}}
spec: {accessModes: [ReadWriteOnce], storageClassName: $SC, resources: {requests: {storage: 1Gi}}}
---
apiVersion: batch/v1
kind: Job
metadata: {name: nvaie-rwtest, labels: {nvaie-test: rwtest}}
spec:
  backoffLimit: 0
  template:
    metadata: {labels: {nvaie-test: rwtest}}
    spec:
      restartPolicy: Never
      containers:
      - name: t
        image: $TEST_IMAGE
        command: ["/bin/sh","-c","id; touch /data/ok && echo WRITE_OK"]
        resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 100m, memory: 64Mi}}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: d, mountPath: /data}]
      volumes: [{name: d, persistentVolumeClaim: {claimName: nvaie-rwtest}}]
EOF
  oc wait job/nvaie-rwtest -n "$NS" --for=condition=complete --timeout=240s >/dev/null 2>&1
  susp=$(oc get job nvaie-rwtest -n "$NS" -o jsonpath='{.spec.suspend}' 2>/dev/null)
  pod=$(oc get pod -n "$NS" -l job-name=nvaie-rwtest -o name 2>/dev/null | head -1)
  if [ "$susp" = true ] && [ -z "$pod" ]; then
    fail "Kueue held the test Job (suspended, no pod created)" "ask the client to exempt $NS from Kueue: the flywheel's evaluation/training Jobs cannot carry a queue label (RUNBOOK 0.3.4)"
  elif [ -z "$pod" ]; then
    fail "test Job created no pod within 4 minutes" "send this output to us"
    oc describe job nvaie-rwtest -n "$NS" | tail -8 | sed 's/^/        /'
  else
    out=$(oc logs "$pod" -n "$NS" 2>/dev/null)
    scc=$(oc get "$pod" -n "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/scc}' 2>/dev/null)
    if grep -q WRITE_OK <<<"$out"; then pass "new volume is writable by a non-root pod (SCC: ${scc:-unknown})"
    else
      if [ -n "$scc" ] && [ "$scc" != restricted-v2 ]; then
        fail "could not write to a new $SC volume under SCC '$scc'" "workloads in $NS get SCC '$scc' instead of restricted-v2; send this output to us"
      else
        fail "could not write to a new $SC volume" "send this output to the storage admin"
      fi
      { echo "$out"; oc describe "$pod" -n "$NS" | tail -8; } | sed 's/^/        /'
    fi
    [ -n "$scc" ] && [ "$scc" != restricted-v2 ] && warn "workload pod ran under SCC '$scc', not restricted-v2" "tell us; the plan assumes restricted-v2"
  fi
  oc delete job,pod,pvc -n "$NS" -l nvaie-test=rwtest --wait=false >/dev/null 2>&1
  info "test Job, pod and PVC deleted"
else info "skipped (StorageClass missing, see above)"; fi

# ---------------------------------------------------------------- image pulls
section "Image pull check (takes up to 10 minutes)"
pc=$(bash "$D/scripts/pull-check.sh" all "$NS" 2>&1)
while read -r res img; do
  case "$res" in
    OK) pass "pull $img";;
    FAILED)  fail "pull $img (FAILED)" "$img is refused (see reason): mirror the image or ask the network team to allow it (approval A6)";;
    TIMEOUT) fail "pull $img (not finished after 10 minutes)" "slow or interrupted download (see reason): re-run, or mirror the image";;
  esac
done < <(grep -E '^(OK|FAILED|TIMEOUT) ' <<<"$pc")
grep -A2 -E '^(FAILED|TIMEOUT) ' <<<"$pc" | grep -E '^ {5,}' | sed 's/^ */        reason: /' 
info "pull-check pods deleted"

# ---------------------------------------------------------------- gpus
section "Free GPUs right now (run gpu-free.sh again right before each install)"
bash "$D/scripts/gpu-free.sh" 2>&1 | sed 's/^/    /'

# ---------------------------------------------------------------- summary
echo
echo "=================================================================="
if [ $NFAIL -eq 0 ]; then echo "RESULT: READY  ($NWARN warning(s) to read below)"
else echo "RESULT: NOT READY  ($NFAIL failure(s), $NWARN warning(s))"; fi
if [ ${#ACTIONS[@]} -gt 0 ]; then
  echo; echo "What to do:"
  for a in "${ACTIONS[@]}"; do echo "  - $a"; done
fi
echo "=================================================================="
[ $NFAIL -eq 0 ]
