# Chart patches (what changed versus upstream, and why)

Upstream sources (download from GitHub/NGC at these versions to compare):

| Blueprint | Upstream | Patched copy | Package |
|---|---|---|---|
| Data Flywheel | github.com/NVIDIA-AI-Blueprints/data-flywheel @ tag **v0.3.1** (chart 0.3.1) + NeMo Microservices chart **25.8.0** from NGC | chart `0.3.1-nvaie.2` | `deploy/packages/nvidia-blueprint-data-flywheel-0.3.1-nvaie.2.tgz` |
| RAG | github.com/NVIDIA-AI-Blueprints/rag @ tag **v2.6.2** (chart v2.6.0) + nv-ingest **26.3.0**, seaweedfs **4.21.0**, eck-elasticsearch **0.18.0** (vendored, disabled) | chart `v2.6.0-nvaie.2` | `deploy/packages/nvidia-blueprint-rag-v2.6.0-nvaie.2.tgz` |

Exact diffs against those upstream versions (unified diff):

- `deploy/flywheel/chart-patch.diff`: the flywheel chart itself
- `deploy/flywheel/nemo-subchart-patch.diff`: the vendored NeMo Microservices 25.8.0 subchart
- `deploy/rag/chart-patch.diff`: the RAG chart itself
- `deploy/rag/nv-ingest-subchart-patch.diff`: nv-ingest 26.3.0

**Design rule:** every template change sits behind a new value whose default reproduces upstream
behaviour. Our values files turn the changes on. Nothing changes application code or images.

**Result:** with our values neither release creates any cluster-scoped object (no CRDs, ClusterRoles,
ClusterRoleBindings or webhooks), and no operator is installed besides the NIM Operator the client
already runs. The flywheel runs in evaluation mode (fine-tuning off, so no NeMo Operator, Customizer
or Volcano); RAG uses a plain Elasticsearch Deployment instead of the ECK operator.

---

## 1. Data Flywheel chart

| # | File | Change | Why | Enabled by |
|---|---|---|---|---|
| F1 | `templates/secrets.yaml` | Whole file wrapped in `if secrets.create` | Secrets are pre-created with `oc` (keys never go into Helm values/release history) | `secrets.create: false` |
| F2 | `templates/{api,celeryWorker,celeryParentWorker}-deployment.yaml` | Every API-key `secretKeyRef` can be `optional: true` | With the local judge no API-key secrets (`nvidia-api`, `llm-judge-api`, `emb-api`, `hf-secret`) are needed; upstream would fail on the missing secrets | `secrets.optionalSecretRefs: true` |
| F3 | `templates/api-deployment.yaml` | `busybox:1.28` init container optional | Not needed (the emptyDir is writable); avoids a docker.io image | `foundationalFlywheelServer.initDataFolder: false` |
| F4 | `templates/{api,celery*,elasticsearch,mongodb,redis}-deployment.yaml` + `_helpers.tpl` | Optional pod label `kueue.x-k8s.io/queue-name`, optional `nodeSelector`, pod and container `securityContext` | Kueue label (off by default), placement, explicit restricted-v2 settings | `kueue.queueName`, `cpuNodeSelector`, `podSecurityContext`, `containerSecurityContext` |
| F5 | `templates/{elasticsearch,mongodb,redis}-deployment.yaml` | Optional emptyDir mounts on the data directories | The images' data dirs are owned by fixed UIDs; restricted-v2 gives a random UID, so `/data/db` and `/data` would not be writable | `<component>.dataDirs` |
| F6 | `templates/nemo-gateway.yaml` (**new**) | CPU-only nginx (Red Hat UBI image) that routes `/v1/customization`, `/v1/evaluation`, `/v1/deployment` and `/v1/{namespaces,projects,datasets,repos,models}` to the NeMo services. The `/v1/customization` route is only rendered when the Customizer subchart is enabled (nginx refuses to start when an upstream host does not resolve). | The flywheel sends all NeMo calls to one base URL; upstream uses an Ingress on fake hosts (`nemo.test`). This keeps it in-cluster with no external exposure. Path map copied from the upstream NeMo 25.8 Ingress. | `nemoGateway.enabled: true` |
| F7 | `templates/{api,celeryWorker,celeryParentWorker}-deployment.yaml` | Optional `extraEnv` list | The published image (0.3.0) runs as root and was built with `uv sync --no-dev`; every container starts with `uv run`, which re-syncs (installs the dev group from PyPI into the root-owned venv). Under a random restricted-v2 UID that fails, and it needs PyPI egress. We set `UV_NO_SYNC=1`, `UV_CACHE_DIR=/tmp/uv-cache`, `HOME=/tmp`. | `foundationalFlywheelServer.extraEnv` |
| F7b | `values.yaml` | Defaults for the keys above | | |
| F8 | `Chart.yaml` | version `0.3.1-nvaie.2` | Marks the patched build | |
| F9 | `charts/` | NeMo 25.8.0 vendored **unpacked** (it needs patches, below) | Offline install | |

Evaluation mode (values only, no template change): `customization_enabled: false` on the candidate
NIM (the blueprint's own switch: the flywheel skips the customization and customized-evaluation
stages), and `customizer`, `nemo-operator` and `volcano` disabled in the NeMo subchart.
Deployment-management starts the judge and candidate NIMs as `NIMService` resources through the NIM
Operator; it creates NeMo Operator resources only when its API is asked for those types, which the
flywheel never does (checked in the deployment-management 25.08 source).

Not changed: the judge. `llm_judge_config` is already exposed in values
(`foundationalFlywheelServer.config` becomes ConfigMap `df-config`, which the pods mount as `config/config.yaml`).

## 2. NeMo Microservices 25.8.0 subchart (inside the flywheel package)

| # | File | Change | Why | Enabled by |
|---|---|---|---|---|
| N1 | `charts/nemo-entity-store/templates/deployment.yaml` | `wait-for-postgres` init can use the entity-store image (Python TCP wait) instead of untagged `busybox` (that means `:latest` from docker.io); resources on both init containers | Pinned tags only, no docker.io, explicit requests/limits | `waitForPostgres.usePythonFromMainImage`, `waitForPostgres.resources`, `dbMigration.resources` |
| N2 | `charts/nemo-evaluator/templates/deployment.yaml` | Same for evaluator's `wait-for-postgres` (uses the pinned entity-store image) | Same | `waitForPostgres.image`, `.resources` |
| N3 | `charts/nemo-evaluator/templates/_db_migration.tpl` | `securityContext` configurable (upstream hard-codes `runAsUser: 0`) | Root is rejected by restricted-v2 | `dbMigration.securityContext: {}` |
| N4 | `charts/nemo-evaluator/templates/eval-factory-job-template.yaml` | Resources on both containers of the **runtime** evaluation Job | Evaluator creates these Jobs at runtime; without requests/limits they are rejected under a CPU/memory ResourceQuota | `evalJobResources`, `evalJobResultsHandlerResources` |
| N5 | `charts/nemo-datastore/templates/gitea/deployment.yaml` | Fixed UID 1000 (`configure-datastore`, `configure-gpg`) and pod `fsGroup: 1000` can be dropped | restricted-v2 assigns UID/fsGroup from the namespace range. A `null` in our values cannot remove them (Helm does not propagate nulls three chart levels down). | `configureDatastoreForceUid1000: false` |
| N6 | `charts/nemo-customizer/templates/finetuning/deployment.yaml` | Resources for the customizer API container (upstream sets none) | Explicit requests/limits | `apiResources` |
| N7 | `charts/nemo-customizer/templates/finetuning/configmap.yaml` | Model-download **runtime** Job: fixed UID/GID/fsGroup 1000 can be dropped | Same as N5, for a Job the Customizer creates at runtime | `modelDownloader.restrictedV2: true` |
| N8 | `charts/nemo-operator/templates/deployment.yaml`, `proxy-rbac.yaml` | `kube-rbac-proxy` sidecar (and its ClusterRole/Binding) optional | Its image `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0` **no longer exists (HTTP 404)**, so upstream would sit in ImagePullBackOff. It only protects a metrics endpoint we don't use. Also removes 1 ClusterRole + 1 ClusterRoleBinding. | `nemo-operator.controllerManager.kubeRbacProxy.enabled: false` |
| N9 | `charts/volcano/templates/webhooks.yaml` | Webhooks match **only the release namespace**, and never Volcano's own pods | Upstream matches *every namespace except its own* with `failurePolicy: Fail`: a dead Volcano admission pod would block pod creation in every production namespace | `volcano.custom.nvaie_restrict: true` |
| N10 | `charts/volcano/templates/scheduler.yaml` | Debug-socket `hostPath` becomes `emptyDir` | hostPath is rejected by restricted-v2 | same flag |
| N11 | `charts/volcano/templates/{admission,controllers,scheduler}.yaml` | No `priorityClassName: system-cluster-critical` | That class is reserved for system namespaces; pods using it are normally rejected elsewhere | same flag |

**N6-N11 are not used any more** (Customizer, NeMo Operator and the bundled Volcano are disabled:
fine-tuning is off). They stay in the package, inactive, so fine-tuning could be added later.

## 3. RAG chart

| # | File | Change | Why | Enabled by |
|---|---|---|---|---|
| R1 | `Chart.yaml` | Removed dependencies zipkin, opentelemetry-collector, kube-prometheus-stack; version `v2.6.0-nvaie.2` | Disabled anyway; barebones; nothing extra to vendor | always |
| R2 | `templates/deployment.yaml`, `ingestor-server-deployment.yaml` | Optional Kueue pod label | Kueue (off by default) | `kueue.queueName` |
| R3 | `templates/llm-nim.yaml`, `embedding-nim.yaml` | Optional Kueue label on `NIMService` (`spec.labels`); optional `resources` on `NIMCache` (upstream: `{}`) | Kueue; explicit cpu/memory for the model-download job | `kueue.queueName`, `nimOperator.<nim>.cacheResources` |
| R4 | `values.yaml` | Default `kueue.queueName: ""` | | |
| R5 | `charts/` | nv-ingest 26.3.0, seaweedfs 4.21.0, eck-elasticsearch 0.18.0 vendored as `.tgz` | Offline install (eck-elasticsearch is disabled by our values) | |
| R6 | `templates/elasticsearch.yaml` (**new**) | Plain single-node Elasticsearch: Deployment + Service `rag-elasticsearch:9200` + 5Gi PVC; security off, `node.store.allow_mmap: false`, no fixed UID | Replaces the eck-elasticsearch subchart, which needs the ECK operator and its cluster-wide CRDs. Same settings as NVIDIA's Docker Compose deployment of this blueprint. Tested with ES 9.3.0 as a random UID with group 0 (restricted-v2 conditions): collection create, vector write, vector search, document listing all work. | `elasticsearch.enabled: true`, `eck-elasticsearch.enabled: false`, `APP_VECTORSTORE_URL` |
| R7 | `templates/openshift.yaml` | The anyuid RoleBinding's subject list can be replaced | Upstream grants anyuid to 7 service accounts including `default` (every pod without its own account). Only nv-ingest needs it: its Python interpreter is a symlink into `/root` (mode 700), so it cannot start as any other UID. Everything else runs under restricted-v2. | `openshift.anyuidServiceAccounts: ["{{ .Release.Name }}-nv-ingest"]` |

Values-only changes for restricted-v2 (no template change): `TEMP_DIR=/tmp-data` for rag-server
(its default `./tmp-data` sits under the root-owned `/workspace`; as a random UID every
knowledge-base query failed with `Permission denied: './tmp-data'`), and nv-ingest memory raised to
16Gi request / 24Gi limit (NVIDIA's default is a 24Gi request; at the limit Ray kills its own workers).

## 4. nv-ingest 26.3.0 subchart

| # | File | Change | Why |
|---|---|---|---|
| I1 | `templates/deployment.yaml` | `toYaml $v \| nindent 12` becomes `nindent 14` for `extraVolumeMounts` | The documented fix from NVIDIA's OpenShift guide (Deploy step 2). Without it the OpenShift overlay renders invalid YAML. Already applied inside the packaged chart. |

## 5. Operators

None installed by us. The only operator used is the NVIDIA NIM Operator the client already runs
(3.1.2, OperatorHub). On OpenShift it gives the NIM and model-download pods the `nonroot` SCC itself
(its own Role), so they need nothing from our charts.
