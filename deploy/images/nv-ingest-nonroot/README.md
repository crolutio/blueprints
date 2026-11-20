# nv-ingest 26.3.0, non-root

NVIDIA's `nvcr.io/nvidia/nemo-microservices/nv-ingest:26.3.0` (the version RAG Blueprint 2.6 uses) runs
as root: its Python interpreter lives under `/root` (mode 700), so it cannot start as any other user.
NVIDIA fixed this in later nv-ingest releases, but none of them works with RAG 2.6. `Containerfile`
applies the same fix to 26.3.0 and nothing else:

1. Python and `uv` move from `/root` to `/opt/uv` (where NVIDIA's later releases put them);
2. `/workspace` and the home directory belong to group 0 and are group-writable (OpenShift runs the pod
   as a random UID that is always in group 0);
3. all Python code is precompiled (NVIDIA's image ships no bytecode for Ray; a non-root user cannot
   write it at run time, and Ray's start-up then times out);
4. the image runs as a non-root user (1001; OpenShift replaces it with the namespace's random UID).

Result: nv-ingest runs under the default `restricted-v2` SCC like every other RAG pod. No `anyuid`.

## Plan A: build inside OpenShift (RUNBOOK 2.2)

```bash
oc apply -n $NS -f deploy/images/nv-ingest-nonroot/buildconfig.yaml
oc start-build nv-ingest-nonroot -n $NS --from-dir=deploy/images/nv-ingest-nonroot --follow --wait
oc get istag nv-ingest-nonroot:26.3.0 -n $NS
```
About 10-15 minutes (downloads ~5 GB from nvcr.io). The image lands in the internal registry at
`image-registry.openshift-image-registry.svc:5000/$NS/nv-ingest-nonroot:26.3.0`, which is what
`deploy/rag/values-nvaie.yaml` points to (if the namespace is not `nvaie-test`, change it there;
the pre-flight checks this).

## Plan B: build on a workstation and push (if OpenShift Docker builds are not allowed)

Needs `podman` on an x86_64 machine, the NGC key, and push rights to a registry the cluster can pull from.
```bash
REG=<registry>/<path>        # e.g. the internal registry's route + /nvaie-test, or the client's Quay/Artifactory
podman login nvcr.io -u '$oauthtoken'          # password: the NGC API key
podman login ${REG%%/*}
podman build --platform linux/amd64 -t $REG/nv-ingest-nonroot:26.3.0 -f deploy/images/nv-ingest-nonroot/Containerfile deploy/images/nv-ingest-nonroot
podman push $REG/nv-ingest-nonroot:26.3.0
```
Then set `nv-ingest.image.repository: $REG/nv-ingest-nonroot` in `deploy/rag/values-nvaie.yaml`
(and add the registry's pull secret to `nv-ingest.imagePullSecrets` if it needs one).

