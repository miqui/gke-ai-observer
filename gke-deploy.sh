#!/usr/bin/env bash
#
# gke-deploy.sh — provision the GCP side of the AI observability platform. Everything *inside* the
# cluster is installed afterwards by gke-bootstrap.sh (Argo CD, then everything else via GitOps).
#
# Architecture:
#   - Zonal cluster (no HA): 1 managed control plane, e2-standard-2 workers, autoscaling 3..5
#   - Dedicated VPC + subnet with Private Google Access
#   - Private nodes (no external IPs); control plane locked to operator's IP
#   - Cloud Router + Cloud NAT for node/pod egress (all images are public: ghcr.io, Docker Hub, ...)
#   - Dataplane V2 (NetworkPolicy enforcement), Workload Identity, Shielded Nodes
#   - Dedicated least-privilege node service account (not the Editor-role default compute SA)
#   - Workload Identity GSAs for in-cluster controllers: Crossplane, External Secrets
#   - No public edge: every UI (Argo CD, OpenLIT, ...) is reached with kubectl port-forward
#
# Every gcloud call is pinned to PROJECT_ID through CLOUDSDK_CORE_PROJECT, so this script never
# touches another project and never changes your gcloud configuration's default project.
#
# Usage:
#   PROJECT_ID=dev-ai-1 ./gke-deploy.sh
#
# Overridable env vars: REGION, ZONE, CLUSTER, VPC, SUBNET, ROUTER, NAT, MACHINE_TYPE,
#                       MIN_NODES, MAX_NODES, NODE_DISK_SIZE_GB
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

# ---- Config ---------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required, e.g. PROJECT_ID=dev-ai-1 ./gke-deploy.sh}"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-dev-cluster}"
VPC="${VPC:-dev-vpc}"
SUBNET="${SUBNET:-dev-subnet}"
ROUTER="${ROUTER:-dev-router}"
NAT="${NAT:-dev-nat}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-2}"
MIN_NODES="${MIN_NODES:-3}"
MAX_NODES="${MAX_NODES:-5}"
# Node boot disk (GKE default is 100 GB). Holds COS, system pods and all pulled images (no image
# streaming); 30 GB is ample for this stack. Creation-time only for the default node pool.
NODE_DISK_SIZE_GB="${NODE_DISK_SIZE_GB:-30}"

SUBNET_RANGE="10.0.0.0/20"
PODS_RANGE="10.4.0.0/14"
SERVICES_RANGE="10.8.0.0/20"

# Service accounts. The in-cluster ones are bound to fixed Kubernetes ServiceAccounts that the
# Helm values / Crossplane DeploymentRuntimeConfig in k8s/ name explicitly.
NODE_SA="gke-dev-nodes"
CROSSPLANE_SA="crossplane-gcp"          # KSA crossplane-system/provider-gcp
ESO_SA="external-secrets"               # KSA external-secrets/external-secrets

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { echo "    already exists, skipping"; }
sa_email() { echo "$1@${PROJECT_ID}.iam.gserviceaccount.com"; }

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }
gcloud projects describe "$PROJECT_ID" --format="value(projectId)" >/dev/null || {
  echo "ERROR: project $PROJECT_ID not found or not accessible" >&2; exit 1;
}

# ---- 0. Project setup -----------------------------------------------------
log "Project: $PROJECT_ID"

# ---- 0b. Preflight: verify effective IAM permissions ------------------------
# Uses resourcemanager.testIamPermissions, which accounts for permissions
# inherited from the org, folders, and group memberships (not just direct
# project bindings). Skip with IAM_CHECK=0.
IAM_CHECK="${IAM_CHECK:-1}"
if [[ "$IAM_CHECK" == "1" ]]; then
  ACCOUNT=$(gcloud config get-value account)
  log "Checking IAM permissions for $ACCOUNT"

  REQUIRED_PERMS=(
    resourcemanager.projects.get
    resourcemanager.projects.setIamPolicy
    serviceusage.services.enable
    compute.networks.create
    compute.subnetworks.create
    compute.routers.create
    compute.firewalls.create
    container.clusters.create
    container.clusters.getCredentials
    iam.serviceAccounts.create
    iam.serviceAccounts.setIamPolicy
  )

  PERMS_JSON=$(printf '"%s",' "${REQUIRED_PERMS[@]}")
  RESPONSE=$(curl -s --max-time 15 -X POST \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "Content-Type: application/json" \
    -d "{\"permissions\":[${PERMS_JSON%,}]}" \
    "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" || true)

  if [[ -z "$RESPONSE" || "$RESPONSE" == *'"error"'* ]]; then
    echo "ERROR: IAM permission check failed (does $ACCOUNT have any access to '$PROJECT_ID'?):" >&2
    echo "${RESPONSE:-<empty response>}" >&2
    exit 1
  fi

  MISSING=""
  for perm in "${REQUIRED_PERMS[@]}"; do
    [[ "$RESPONSE" == *"\"$perm\""* ]] || MISSING="${MISSING}  - ${perm}"$'\n'
  done

  if [[ -n "$MISSING" ]]; then
    cat >&2 <<EOF
ERROR: $ACCOUNT is missing required permissions:

$MISSING
This script creates networks, a cluster, service accounts and IAM bindings - roles/owner on this
dev project is the simple fix:

  gcloud projects add-iam-policy-binding $PROJECT_ID --member="user:$ACCOUNT" --role=roles/owner

If permissions come from a source this check can't see, skip with IAM_CHECK=0.
EOF
    exit 1
  fi
  echo "    all required permissions present"
fi

log "Enabling APIs"
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com

# ---- 1. Service accounts ----------------------------------------------------
ensure_sa() { # ensure_sa <id> <display name>
  if gcloud iam service-accounts describe "$(sa_email "$1")" &>/dev/null; then
    echo "    $1: exists"
  else
    gcloud iam service-accounts create "$1" --display-name="$2"
  fi
}
project_role() { # project_role <sa id> <role>
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$(sa_email "$1")" --role="$2" --condition=None --quiet >/dev/null
  echo "    $1 -> $2"
}

log "Creating service accounts"
ensure_sa "$NODE_SA"          "GKE dev-cluster nodes"
ensure_sa "$CROSSPLANE_SA"    "Crossplane GCP provider"
ensure_sa "$ESO_SA"           "External Secrets Operator (Secret Manager reader)"

log "Granting project roles"
# Node SA: logging/monitoring/metadata only (the predefined role GKE recommends for custom node
# SAs). Every image is public, so no registry access is needed.
project_role "$NODE_SA" roles/container.defaultNodeServiceAccount
# Crossplane: no roles yet - it manages no GCP resources. Grant the narrowest role per resource
# type here when a managed resource is added (e.g. a GCS bucket for ClickHouse backups).
# ESO gets secretAccessor per secret (gke-secrets-seed.sh), not project-wide.

# ---- 2. Dedicated VPC + subnet --------------------------------------------
log "Creating VPC: $VPC"
if gcloud compute networks describe "$VPC" &>/dev/null; then
  skip
else
  gcloud compute networks create "$VPC" --subnet-mode=custom
fi

log "Creating subnet: $SUBNET ($SUBNET_RANGE, pods=$PODS_RANGE, services=$SERVICES_RANGE)"
if gcloud compute networks subnets describe "$SUBNET" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute networks subnets create "$SUBNET" \
    --network="$VPC" \
    --region="$REGION" \
    --range="$SUBNET_RANGE" \
    --secondary-range="pods=$PODS_RANGE,services=$SERVICES_RANGE" \
    --enable-private-ip-google-access
fi

# ---- 3. Cloud Router + NAT (egress for private nodes) ----------------------
log "Creating Cloud Router: $ROUTER"
if gcloud compute routers describe "$ROUTER" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute routers create "$ROUTER" --network="$VPC" --region="$REGION"
fi

log "Creating Cloud NAT: $NAT"
if gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" &>/dev/null; then
  skip
else
  gcloud compute routers nats create "$NAT" \
    --router="$ROUTER" \
    --region="$REGION" \
    --auto-allocate-nat-external-ips \
    --nat-all-subnet-ip-ranges
fi

# ---- 4. Control-plane access restricted to operator's IP -------------------
log "Detecting operator public IP for master authorized networks"
MY_IP=$(curl -4 -s --max-time 10 ifconfig.me || true)
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "ERROR: could not detect public IP (got: '${MY_IP:-empty}')" >&2; exit 1;
}
echo "    operator IP: $MY_IP"

# ---- 5. GKE cluster ---------------------------------------------------------
# These flags can only be set at creation time (dataplane v2) or are awkward to change later, so
# an existing cluster created by an older version of this script must be recreated to pick them up.
log "Creating cluster: $CLUSTER (zonal $ZONE, $MACHINE_TYPE, ${NODE_DISK_SIZE_GB}GB pd-balanced, autoscaling $MIN_NODES..$MAX_NODES, private nodes)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  skip
else
  gcloud container clusters create "$CLUSTER" \
    --zone="$ZONE" \
    --network="$VPC" \
    --subnetwork="$SUBNET" \
    --enable-ip-alias \
    --cluster-secondary-range-name=pods \
    --services-secondary-range-name=services \
    --enable-private-nodes \
    --enable-master-authorized-networks \
    --master-authorized-networks="$MY_IP/32" \
    --service-account="$(sa_email "$NODE_SA")" \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-dataplane-v2 \
    --no-enable-managed-prometheus \
    --enable-shielded-nodes \
    --shielded-secure-boot \
    --shielded-integrity-monitoring \
    --machine-type="$MACHINE_TYPE" \
    --disk-type=pd-balanced \
    --disk-size="$NODE_DISK_SIZE_GB" \
    --num-nodes="$MIN_NODES" \
    --enable-autoscaling \
    --min-nodes="$MIN_NODES" \
    --max-nodes="$MAX_NODES" \
    --release-channel=stable
fi

# Admission webhooks served on ports other than 443/10250 (Kyverno and Crossplane: 9443).
# Current GKE private clusters are PSC-based: the control plane reaches webhooks through the
# konnectivity agents running inside the cluster, i.e. over the pod network, which GKE's own
# "-all" firewall rule already allows - nothing to add. Older VPC-peering-based private clusters
# instead connect from a dedicated control-plane range that GKE's "-master" rule only opens for
# 443/10250; there, open the webhook ports too, or every matching create/update times out.
WEBHOOK_FW="${CLUSTER}-allow-webhooks"
log "Control plane -> admission webhooks (tcp:8443,9443)"
MASTER_RANGES=$(gcloud compute firewall-rules list \
  --filter="network~/${VPC}\$ AND name~^gke-${CLUSTER}-.*-master\$" \
  --format='value(sourceRanges.list())' | head -1)
if [[ -z "$MASTER_RANGES" ]]; then
  echo "    PSC-based cluster (webhooks reached via konnectivity) - no extra rule needed"
elif gcloud compute firewall-rules describe "$WEBHOOK_FW" &>/dev/null; then
  skip
else
  NODE_TAG=$(gcloud compute firewall-rules list \
    --filter="network~/${VPC}\$ AND name~^gke-${CLUSTER}-.*-master\$" \
    --format='value(targetTags.list())' | head -1)
  gcloud compute firewall-rules create "$WEBHOOK_FW" \
    --network="$VPC" \
    --direction=INGRESS \
    --source-ranges="$MASTER_RANGES" \
    --target-tags="$NODE_TAG" \
    --allow=tcp:8443,tcp:9443
fi

# ---- 6. Workload Identity bindings for in-cluster controllers ----------------
# The PROJECT.svc.id.goog identity pool exists once the first Workload Identity cluster does.
wi_bind() { # wi_bind <gsa id> <namespace> <ksa>
  gcloud iam service-accounts add-iam-policy-binding "$(sa_email "$1")" \
    --role=roles/iam.workloadIdentityUser \
    --member="serviceAccount:${PROJECT_ID}.svc.id.goog[$2/$3]" --quiet >/dev/null
  echo "    $2/$3 -> $1"
}
log "Binding Kubernetes ServiceAccounts to GCP service accounts (Workload Identity)"
wi_bind "$CROSSPLANE_SA"    crossplane-system provider-gcp
wi_bind "$ESO_SA"           external-secrets  external-secrets

# ---- 7. Connect + verify -----------------------------------------------------
log "Fetching kubeconfig for $CLUSTER"
gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE"

log "Verifying cluster"
kubectl get nodes -o wide
kubectl cluster-info

# ---- Summary -----------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mDone.\033[0m') Cluster '$CLUSTER' and its GCP foundation are ready in project $PROJECT_ID.

  Next:
    1. op run --env-file=.env -- env PROJECT_ID=$PROJECT_ID ./gke-secrets-seed.sh   (first time / rotation)
    2. PROJECT_ID=$PROJECT_ID ./gke-bootstrap.sh
    3. ./gke-port-forward.sh     (Argo CD, Headlamp, Polaris)

  If your public IP changes, re-authorize it:
    gcloud container clusters update $CLUSTER --project=$PROJECT_ID --zone=$ZONE \\
      --enable-master-authorized-networks \\
      --master-authorized-networks=NEW_IP/32

  Tear down (keeps secrets and service accounts): PROJECT_ID=$PROJECT_ID ./gke-teardown.sh
EOF
