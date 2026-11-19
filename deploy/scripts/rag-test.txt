#!/usr/bin/env bash
# RAG end-to-end functional test (text-only).
# Needs two port-forwards (see RUNBOOK 2.4):
#   ingestor-server -> localhost:8082   (oc port-forward svc/ingestor-server 8082:8082)
#   rag-server      -> localhost:8081   (oc port-forward svc/rag-server 8081:8081)
# Steps: health -> create collection -> upload sample .txt -> wait for ingestion ->
#        ask a question WITH the knowledge base (must contain the planted phrase) ->
#        ask the same question WITHOUT the knowledge base (control: must NOT contain it).
# Usage: deploy/scripts/rag-test.sh [path/to/doc.txt]
set -uo pipefail
D="$(cd "$(dirname "$0")/.." && pwd)"
DOC="${1:-$D/rag/sample/nvaie-validation-note.txt}"
ING="${ING:-http://localhost:8082}"; RAG="${RAG:-http://localhost:8081}"
COL="${COL:-nvaie_validation}"
Q="What is the secret validation phrase for this deployment, and who is the programme lead of Project Kestrel-42?"
EXPECT="amber lantern seventeen"
fail=0; check() { if [ "$2" = true ]; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== Health"
H1="$(curl -fsS "$ING/v1/health")" && ok=true || ok=false; echo "$H1"; check "ingestor-server healthy" $ok
H2="$(curl -fsS "$RAG/v1/health")" && ok=true || ok=false; echo "$H2"; check "rag-server healthy" $ok

echo "== Create collection $COL (an 'already exists' message is fine)"
curl -sS -X POST "$ING/v1/collection" -H 'Content-Type: application/json' \
  -d "{\"collection_name\": \"$COL\"}" | jq -c .

echo "== Upload $(basename "$DOC")"
UP="$(curl -sS -X POST "$ING/v1/documents" \
  -F "documents=@$DOC" \
  -F "data={\"collection_name\": \"$COL\", \"blocking\": false, \"split_options\": {\"chunk_size\": 512, \"chunk_overlap\": 150}}")"
echo "$UP" | jq -c .
TASK="$(jq -r '.task_id // empty' <<<"$UP")"
[ -n "$TASK" ] || { echo "FAIL no task_id returned"; exit 1; }

echo "== Wait for ingestion task $TASK (max 10 min)"
STATE=""
for _ in $(seq 1 60); do
  S="$(curl -sS "$ING/v1/status?task_id=$TASK")"; STATE="$(jq -r '.state // empty' <<<"$S")"
  echo "  state=$STATE"; [[ "$STATE" == FINISHED || "$STATE" == FAILED ]] && break; sleep 10
done
echo "$S" | jq .
check "ingestion task FINISHED"            "$([ "$STATE" = FINISHED ] && echo true || echo false)"
DOCS="$(curl -sS -G "$ING/v1/documents" --data-urlencode "collection_name=$COL")"
echo "$DOCS" | jq -c '[.documents[]?.document_name]'
check "document listed in collection"      "$(jq --arg f "$(basename "$DOC")" '[.documents[]?.document_name] | index($f) != null' <<<"$DOCS")"

ask() { # $1 = use_knowledge_base (true/false), $2 = file for the raw SSE stream -> prints answer text
  curl -sS -N -X POST "$RAG/v1/generate" -H 'Content-Type: application/json' -d "{
    \"messages\": [{\"role\": \"user\", \"content\": \"$Q\"}],
    \"use_knowledge_base\": $1, \"collection_names\": [\"$COL\"],
    \"enable_reranker\": false, \"reranker_top_k\": 0, \"vdb_top_k\": 5,
    \"enable_citations\": true, \"max_tokens\": 256, \"temperature\": 0 }" > "$2"
  sed -n 's/^data: //p' "$2" | jq -rj 'select(type=="object") | (.choices[0].delta.content // .choices[0].message.content // "")' 2>/dev/null
}
OUT="${OUT:-.}"
echo "== Question WITH knowledge base: $Q"
A1="$(ask true "$OUT/rag-answer-kb.sse")"; echo "ANSWER: $A1"
echo "== Citations"
sed -n 's/^data: //p' "$OUT/rag-answer-kb.sse" | jq -c 'select(.citations != null) | [.citations.results[]? | {document_name, score}]' 2>/dev/null | tail -1
check "answer contains the planted phrase \"$EXPECT\"" "$(grep -qi "$EXPECT" <<<"$A1" && echo true || echo false)"

echo "== Control: same question WITHOUT knowledge base"
A0="$(ask false "$OUT/rag-answer-nokb.sse")"; echo "ANSWER: $A0"
check "control answer does NOT contain the phrase (proves grounding)" "$(grep -qi "$EXPECT" <<<"$A0" && echo false || echo true)"

echo; [ $fail = 0 ] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: SOME CHECKS FAILED"
exit $fail
