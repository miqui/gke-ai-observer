# Helm charts — how they're installed and changed

Every third-party component is an upstream Helm chart **rendered by Argo CD**, not installed with
`helm install`. Each Application in `k8s/argocd/apps/` pairs the chart (pinned `targetRevision`)
with a values file from this repo (the `$values` multi-source pattern), so changing a value or
bumping a version is a merged commit. There are no Helm releases in the cluster for these - `helm
list -A` shows only `argocd`, the one chart `gke-bootstrap.sh` installs with Helm before Argo CD
exists to take it over.

| Component | Chart | Version | Values | Application |
| --- | --- | --- | --- | --- |
| Argo CD | `argo/argo-cd` | 10.9.2 (v3.5.3) | `k8s/argocd/argocd-values.yaml` | `argocd` |
| External Secrets | `external-secrets/external-secrets` | 2.11.0 | `k8s/external-secrets/values.yaml` | `external-secrets` |
| Crossplane | `crossplane-stable/crossplane` | 2.4.2 | `k8s/crossplane/values.yaml` | `crossplane` |
| Kyverno | `kyverno/kyverno` | 3.9.1 (v1.19.1) | `k8s/kyverno/kyverno-values.yaml` | `kyverno` |
| Headlamp | `headlamp/headlamp` | 0.45.0 | `k8s/headlamp/headlamp-values.yaml` | `headlamp` |
| Polaris | `fairwinds-stable/polaris` | 6.0.1 | `k8s/polaris/polaris-values.yaml` | `polaris` |
| Trivy Operator | `aqua/trivy-operator` | 0.36.0 | `k8s/trivy-operator/trivy-operator-values.yaml` | `trivy-operator` |
| OpenLIT (+ openlit-controller 0.10.0) | `openlit/openlit` | 1.24.0 | `k8s/openlit/values.yaml` | `openlit` |

Repositories: `argo` https://argoproj.github.io/argo-helm, `external-secrets`
https://charts.external-secrets.io, `crossplane-stable` https://charts.crossplane.io/stable,
`kyverno` https://kyverno.github.io/kyverno/, `headlamp` https://kubernetes-sigs.github.io/headlamp/,
`fairwinds-stable` https://charts.fairwinds.com/stable, `aqua` https://aquasecurity.github.io/helm-charts/,
`openlit` https://openlit.github.io/helm/.

## Changing values or versions

1. Edit the values file (or `targetRevision` in the Application) on a branch.
2. Render locally to check it, with the same chart version:
   ```bash
   helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ && helm repo update headlamp
   helm template headlamp headlamp/headlamp --version 0.45.0 \
     -n headlamp -f k8s/headlamp/headlamp-values.yaml | less
   helm show values headlamp/headlamp --version 0.45.0   # what can be set
   ```
3. Merge. Argo CD re-renders and applies it; charts that hash their config into the pod template
   (a `checksum/config` pod annotation) roll their pods on their own.

Bumping Argo CD's own chart: change `targetRevision` in `k8s/argocd/apps/argocd.yaml` **and**
`ARGOCD_CHART_VERSION` in `gke-bootstrap.sh`, so fresh clusters start on the same version.
