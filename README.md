# gke-ai-observer

An open-source AI observability platform on a dev [GKE](https://cloud.google.com/kubernetes-engine)
cluster in GCP project **`dev-ai-1`**. Argo CD deploys [OpenLIT](https://github.com/openlit/openlit)
(LLM traces, token/cost metrics and evals, on ClickHouse) with its eBPF-based zero-code
instrumentation controller. Crossplane provisions the GCP resources the platform needs: today,
the GCS bucket for ClickHouse backups.

> **Status:** OpenLIT is defined but has not yet been deployed to `dev-ai-1`. No demo LLM app
> exists yet, so OpenLIT stays empty until something sends it OTLP data. This repo started as a
> copy of `miqui/gke-springboot-grpc-o2`. That repo and its GCP project (`k8s-dev-412419`) are
> untouched.

The cluster is meant to be **short-lived**: create it for an experiment, tear it down after a few
hours, recreate it for the next one. Secrets and service accounts live outside it and are reused.

## Stack URLs

Nothing is public: there is no Ingress, Gateway or LoadBalancer. Every UI is reached through
`./gke-port-forward.sh`. It tunnels through the GKE API server, which only accepts your IP plus
Google IAM, and binds on `127.0.0.1` only.

| Component | URL | Login |
| --- | --- | --- |
| OpenLIT | `http://localhost:3000` | `user@openlit.io` / `openlituser` (the chart's default). Change it in Settings after each new cluster. |
| Argo CD | `https://localhost:8081` (self-signed cert) | `admin` / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d`. Change it in the UI, then delete that Secret. |
| Headlamp | `http://localhost:4466` | `kubectl create token headlamp -n headlamp --duration=1h \| tr -d '\n' \| pbcopy` (read-only) |
| Polaris | `http://localhost:8082` | none (read-only report) |

## Architecture

- **Project isolation**: every script takes `PROJECT_ID` (required, no default) and exports it as
  `CLOUDSDK_CORE_PROJECT`. All `gcloud` calls are therefore pinned to that project, and your
  gcloud configuration's default project is never changed. `gke-bootstrap.sh` refuses to run if
  the manifests in `k8s/` are not for the given project.
- **Cluster** (`gke-deploy.sh`): zonal GKE Standard cluster `dev-cluster` in `us-central1-a`,
  `e2-standard-2` nodes autoscaling 3-5, release channel `stable`.
  - **Private nodes** (no external IPs), with egress through Cloud NAT. Every image is public
    (ghcr.io, Docker Hub, quay.io, ...), so no registry is needed. The control plane only accepts
    the operator's public IP (master authorized networks).
  - **Dataplane V2** enforces NetworkPolicies. **Workload Identity** gives in-cluster controllers
    Google credentials without key files. Shielded Nodes with secure boot. GKE Managed
    Prometheus is off.
  - Nodes run as a dedicated `gke-dev-nodes` service account with only
    `roles/container.defaultNodeServiceAccount`, not the default compute account (which has
    project Editor).
  - A firewall rule lets the control plane reach admission webhooks on 8443/9443 (Kyverno,
    Crossplane) on older peering-based private clusters. Current PSC-based clusters need no rule.
- **GitOps**: Argo CD syncs the whole platform from this repo's `main` branch; see
  [Continuous Deployment with Argo CD](#continuous-deployment-with-argo-cd).
- **GCP resources through Crossplane**:
  - `k8s/platform/` installs the [Upbound GCP provider](https://marketplace.upbound.io/providers/upbound/provider-family-gcp)
    family plus `provider-gcp-storage` (v3.1.0) and the Composition functions. It also holds a
    `ClusterProviderConfig` that authenticates as the `crossplane-gcp` service account via
    Workload Identity (`roles/storage.admin`).
  - The managed resources live next to the workload that uses them, as namespaced MRs. The one
    today is `k8s/openlit/manifests/backup-bucket.yaml`: the bucket plus its IAM bindings.
  - To add another resource type: add its sub-provider to `crossplane-packages.yaml` with
    `runtimeConfigRef: {name: provider-gcp}`, and grant `crossplane-gcp` the narrowest matching
    role in `gke-deploy.sh`.
- **Budget**: `gke-deploy.sh` creates a `BUDGET_USD` (default 25) monthly budget on the project.
  It alerts the billing admins at 50/90/100% of actual spend and at 100% of forecast spend.
  - Budgets only alert; they never stop spending.
  - The budget is created with `gcloud`, not Crossplane. It belongs to the billing account, it
    has to exist while no cluster does, and managing it from Crossplane would need a
    billing-account role.
- **Secrets**: nothing secret is committed, or passed through a script into the cluster.
  - Values live in 1Password. `gke-secrets-seed.sh` copies them into **GCP Secret Manager**.
  - The **External Secrets Operator** builds Kubernetes Secrets from `ExternalSecret` manifests.
    It authenticates as the `external-secrets` service account via Workload Identity, and can read
    exactly the seeded secrets.
  - The `gcp-secret-manager` `ClusterSecretStore` only serves the namespaces listed in its
    `conditions` (`openlit`).
  - No secrets need seeding yet. The ClickHouse password is generated inside the cluster by an
    External Secrets `Password` generator, so it never exists outside the cluster. A seeded
    secret would be an entry in `gke-secrets-seed.sh`, `.env.example` and `REQUIRED_SECRETS` in
    `gke-bootstrap.sh`.
- **Tools**:
  - **[Headlamp](https://headlamp.dev/)** is a Kubernetes web UI, bound to the read-only `view`
    ClusterRole.
  - **[Polaris](https://polaris.docs.fairwinds.com/)** is a best-practice dashboard with read-only
    RBAC.
  - **[Trivy Operator](https://github.com/aquasecurity/trivy-operator)** does continuous CVE and
    misconfiguration scanning ([TRIVY.md](TRIVY.md)).

## Continuous Deployment with Argo CD

`gke-bootstrap.sh` does two things by hand: it Helm-installs Argo CD and applies one **root**
Application (`k8s/argocd/root-application.yaml`). The root Application syncs every other
Application from `k8s/argocd/apps/` ("app of apps"), Argo CD itself included. From then on, a
version bump, a values change or a new manifest is a merged commit to
`https://github.com/miqui/gke-ai-observer.git`. The repo must be public, because Argo CD clones it
anonymously.

| Wave | Application | Source |
| --- | --- | --- |
| -4 | `argocd` (self-managed), `external-secrets`, `crossplane` | upstream charts + values in `k8s/argocd/`, `k8s/external-secrets/`, `k8s/crossplane/` |
| -3 | `kyverno`, `platform` | Kyverno chart; `k8s/platform/` (secret store, Crossplane GCP provider family/functions/config) |
| -2 | `kyverno-policies` | `k8s/policies/`: enforce rules exist before any workload syncs |
| -1 | `headlamp`, `polaris`, `trivy-operator` | charts + values |
| 0 | `openlit` | OpenLIT chart + `k8s/openlit/values.yaml` + `k8s/openlit/manifests/` |

A wave only starts once the previous one is Healthy. That depends on the Application health check
in `k8s/argocd/argocd-values.yaml`, which also teaches Argo CD to read Crossplane's Ready
conditions. Every Application runs `automated: {prune: true, selfHeal: true}`, except Argo CD's
own, which doesn't prune. Day-to-day commands are in [ARGOCD.md](ARGOCD.md), and chart versions
in [HELM.md](HELM.md).

## Policy as Code with Kyverno

[Kyverno](https://kyverno.io/) runs admission control in the cluster. The *same* policies are
checked in CI (`.github/workflows/policy-check.yml` → `check-policies.sh`). They use the CEL-based
`policies.kyverno.io/v1` types.

- `k8s/policies/rules/` holds each rule once:
  - `disallow-host-access`
  - `require-secure-container-context`
  - `require-resources`
  - `restrict-image-repositories`, an exact-repository allowlist
- Overlays turn the rules into a **Deny** copy for `default` and an **Audit** copy for
  `headlamp`, `polaris` and `openlit`. `audit-only/` holds `disallow-latest-tag` and `restrict-cluster-admin-bindings`.
- **A new image** needs its repository in `restrict-image-repositories.yaml`.
- **A new namespace** goes into the overlays' `namespaceSelector`.
- `check-policies.sh` evaluates the enforce and audit sets against this repo's own workload
  manifests (`WORKLOAD_DIRS`, empty for now). It also requires the enforce set to reject a
  known-bad fixture. `polaris-audit.sh` runs the Polaris checks against the same manifests,
  report-only.

Debugging commands are in [KYVERNO.md](KYVERNO.md).

## Deployment to GKE

Requirements:
- `gcloud`, authenticated as an owner of the project
- `kubectl` and `helm`
- the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`), once secrets exist

```bash
export PROJECT_ID=dev-ai-1

# 1. GCP foundation + cluster (~10 min)
./gke-deploy.sh

# 2. Secrets -> Secret Manager (first time, and after rotating anything in 1Password)
op run --env-file=.env -- ./gke-secrets-seed.sh

# 3. Argo CD + everything else via GitOps
./gke-bootstrap.sh

# 4. Tools
./gke-port-forward.sh
```

**Before the first run:** push this repo to `github.com/miqui/gke-ai-observer` (public), branch
`main`. Argo CD syncs from there, not from your working copy. `gke-bootstrap.sh` checks that the
repo is readable and warns about unpushed commits.

**What each script does:**

- `gke-deploy.sh` is idempotent; every step skips what already exists. It:
  - checks your IAM permissions and enables the APIs;
  - creates the service accounts (`gke-dev-nodes`, `crossplane-gcp`, `external-secrets`,
    `openlit-backup`), the node SA's role and Crossplane's `roles/storage.admin`;
  - creates the monthly billing budget;
  - creates the VPC, subnet, Cloud Router + NAT, the cluster and the webhook firewall rule;
  - binds Workload Identity for Crossplane, External Secrets and the OpenLIT backup job.
- `gke-secrets-seed.sh` creates or updates the Secret Manager secrets listed in its `SECRETS`
  array, labelled `managed-by=gke-secrets-seed`. It adds a version only when the value changed, and
  grants `external-secrets` access to exactly those secrets.
- `gke-bootstrap.sh` runs a preflight (context, project guard, Secret Manager, public repo).
  It then Helm-installs Argo CD, applies the root Application and waits until every Application is
  Synced + Healthy. Safe to re-run.
- `gke-teardown.sh` works in dependency order:
  - It stops Argo CD reconciling, then deletes the cluster.
  - It then removes what a cluster deletion leaves behind: NEGs, and the unattached PD-CSI disks
    behind the PVCs.
  - Finally it removes the firewall rules, NAT, router, subnet and VPC.
  - Secrets, service accounts and the backup bucket are kept unless you pass `--purge`. The budget
    is always kept. `--yes` skips the prompt.

**If your public IP changes**, the control plane stops answering (`kubectl` times out).
Re-authorize your IP with the command `gke-deploy.sh` prints at the end.

**Validate a teardown** (nothing should be listed):

```bash
gcloud container clusters list --project=$PROJECT_ID
gcloud compute disks list --project=$PROJECT_ID --filter='name~^pvc-'
gcloud compute networks list --project=$PROJECT_ID --filter=name=dev-vpc
```

Operational notes on GKE events that look alarming but aren't are in [GKE-OPS.md](GKE-OPS.md);
everyday `kubectl` is in [KUBECTL.md](KUBECTL.md).

### OpenLIT

`./gke-port-forward.sh openlit` serves the UI at `http://localhost:3000`. Everything runs in the
`openlit` namespace:

- **OpenLIT** (`ghcr.io/openlit/openlit:1.24.0`) is the UI plus an embedded OTel collector. Its
  SQLite store (users, settings, API keys) sits on a 5Gi PVC.
- **ClickHouse** (`openlit-db`, 24.4.1) holds traces, metrics and logs, on a 10Gi PVC. It can only
  be reached from inside the namespace.
- **openlit-controller** provides zero-code instrumentation. One privileged pod per node (hostPID,
  eBPF, host mounts) finds processes calling LLM APIs, and OpenLIT's *Agents* page can then enable
  SDK injection for them.
  - It replaces the openlit-operator, which was removed upstream in April 2026.
  - Turn it off with `openlit-controller.enabled: false` in `k8s/openlit/values.yaml`.
  - When it injects the SDK it patches the target Deployment. If Argo CD manages that Deployment,
    `selfHeal` reverts the patch, so add the instrumentation in git for those.
  - Pods in `default` must pass the Kyverno enforce rules, injected containers included.

**Send telemetry** from any namespace (OTLP is open cluster-wide; nothing else is):

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://openlit.openlit.svc.cluster.local:4318   # HTTP; gRPC on :4317
```

**Backups.** The `openlit-backup` CronJob runs daily at 03:00 UTC. It dumps every ClickHouse table
(its schema plus a zstd-compressed Native data file) and copies the result to
`gs://dev-ai-1-openlit-backups/openlit/<timestamp>/`.
- It authenticates as the `openlit-backup` service account through Workload Identity, which can
  create and read backups but not delete them.
- A lifecycle rule deletes backups after 14 days.
- Crossplane never deletes the bucket, so backups outlive the cluster.

```bash
# back up now
kubectl -n openlit create job --from=cronjob/openlit-backup openlit-backup-manual
kubectl -n openlit logs -f job/openlit-backup-manual -c dump
gcloud storage ls gs://dev-ai-1-openlit-backups/openlit/

# restore one table into a fresh cluster (OpenLIT recreates the schema at startup)
TS=20261010T030000Z; T=otel_traces
gcloud storage cp gs://dev-ai-1-openlit-backups/openlit/$TS/$T.native.zst .
zstd -d $T.native.zst
kubectl -n openlit exec -i openlit-db-0 -- bash -c \
  'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" \
     --query "INSERT INTO openlit.'$T' FORMAT Native"' < $T.native
```

### Headlamp

Headlamp can show everything in the cluster, so it gets the least access that is still useful.
`./gke-port-forward.sh headlamp` serves it at `http://localhost:4466`. Log in with a short-lived
token for its `view`-bound ServiceAccount (see [Stack URLs](#stack-urls)).

For anything that needs more access (editing, exec), use `kubectl` with your own Google identity.
Don't widen the `headlamp` binding: every Headlamp login would become an admin login.

### Polaris

`./gke-port-forward.sh polaris` serves it at `http://localhost:8082`. It shows an overall score
and, per workload, which built-in checks fail at `warning`/`danger`.
- GKE-managed namespaces are exempt (`config.exemptions` in `k8s/polaris/polaris-values.yaml`).
- Findings are advice. Anything that must be blocked belongs in a Kyverno policy.
