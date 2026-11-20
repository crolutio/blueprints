#!/usr/bin/env bash
# Flywheel success check, EVALUATION MODE (fine-tuning is off: customization_enabled: false).
# Needs two port-forwards (see RUNBOOK 1.4):
#   flywheel API  -> localhost:8000   (oc port-forward svc/df-api-service 8000:8000)
#   NeMo gateway  -> localhost:8001   (oc port-forward svc/nemo-gateway 8001:80)
# Prints PASS/FAIL per criterion; exit 0 only if all pass.
# Usage: deploy/scripts/flywheel-check.sh <job_id> [namespace]
set -uo pipefail
JOB="$1"; NS="${2:-nvaie-test}"; API="${API:-http://localhost:8000}"; GW="${GW:-http://localhost:8001}"
J="$(curl -fsS "$API/api/jobs/$JOB")" || { echo "FAIL cannot read job $JOB from $API"; exit 2; }
fail=0
check() { if [ "$2" = true ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== Flywheel job $JOB"
jq '{status, error, workload_id, client_id, num_records, llm_judge,
     nims: [.nims[]? | {model_name, status, deployment_status, error,
       evaluations: [.evaluations[]? | {eval_type, scores, progress}],
       customizations: [.customizations[]? | {customized_model, progress, epochs_completed, steps_completed, error}]}]}' <<<"$J"

check "job status is completed"                     "$(jq '.status=="completed"' <<<"$J")"
check "judge deployment is ready"                   "$(jq '.llm_judge.deployment_status|tostring|test("ready|completed")' <<<"$J")"
check "base-eval has judge scores"                   "$(jq '[.nims[].evaluations[]? | select(.eval_type=="base-eval") | .scores | length > 0] | any' <<<"$J")"
check "icl-eval has judge scores"                    "$(jq '[.nims[].evaluations[]? | select(.eval_type=="icl-eval") | .scores | length > 0] | any' <<<"$J")"
check "fine-tuning skipped as configured (evaluation mode)" "$(jq '[.nims[].customizations[]?] | length == 0' <<<"$J")"

echo; echo "== NeMo Evaluator jobs"
curl -fsS "$GW/v1/evaluation/jobs" 2>/dev/null \
  | jq '[.data[]? | {id, status, created_at}]' || echo "(could not query evaluator through the gateway)"
EVAL_OK="$(curl -fsS "$GW/v1/evaluation/jobs" 2>/dev/null | jq '[.data[]? | select(.status=="completed")] | length > 0' 2>/dev/null || echo false)"
check "NeMo Evaluator reports >= 1 completed job"    "$EVAL_OK"

echo; [ $fail = 0 ] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: SOME CHECKS FAILED"
exit $fail
