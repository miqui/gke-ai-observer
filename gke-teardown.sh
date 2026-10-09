#!/usr/bin/env bash
#
# gke-teardown.sh — delete what gke-deploy.sh/gke-bootstrap.sh created, in dependency order:
#   1. In-cluster: stop Argo CD reconciling (so it doesn't recreate anything mid-teardown)
#   2. GKE cluster
#   3. Leftovers a cluster deletion leaves behind: network endpoint groups in the VPC and the
#      PVCs' persistent disks
#   4. Firewall rules in the VPC, Cloud NAT, Cloud Router, subnet, VPC
#
# Kept by default (free or pennies) - removed with --purge: Secret Manager secrets, service
# accounts.
#
# Every gcloud call is pinned to PROJECT_ID through CLOUDSDK_CORE_PROJECT; nothing outside that
# project is touched and your gcloud configuration's default project is left alone.
#
# Usage:
#   PROJECT_ID=dev-ai-1 ./gke-teardown.sh
#   PROJECT_ID=dev-ai-1 ./gke-teardown.sh --yes            # skip confirmation
#   PROJECT_ID=dev-ai-1 ./gke-teardown.sh --purge          # also the persistent resources
#
# Overridable env vars match gke-deploy.sh.
set -euo pipefail
trap 'echo "ERROR: failed at line $LINENO (exit $?)" >&2' ERR
cd "$(dirname "$0")"

# ---- Config ---------------------------------------------------------------
PROJECT_ID="${PROJECT_ID:?PROJECT_ID is required, e.g. PROJECT_ID=dev-ai-1 ./gke-teardown.sh}"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
CLUSTER="${CLUSTER:-dev-cluster}"
VPC="${VPC:-dev-vpc}"
SUBNET="${SUBNET:-dev-subnet}"
ROUTER="${ROUTER:-dev-router}"
NAT="${NAT:-dev-nat}"
SERVICE_ACCOUNTS=(gke-dev-nodes crossplane-gcp external-secrets)
PROJECT_ROLES=(
  "gke-dev-nodes=roles/container.defaultNodeServiceAccount"
)

ASSUME_YES=0
PURGE=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --purge)  PURGE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
skip() { echo "    not found, skipping"; }

command -v gcloud >/dev/null 2>&1 || { echo "gcloud CLI not found" >&2; exit 1; }

# ---- Confirmation -----------------------------------------------------------
cat <<EOF
About to DELETE the following resources in project '$PROJECT_ID':

  GKE cluster          : $CLUSTER (zone $ZONE)
  Persistent disks     : the PVCs' disks (Trivy, ...) - their data is lost
  Network              : NEGs, firewall rules, $NAT / $ROUTER, $SUBNET / $VPC
EOF
if [[ "$PURGE" -eq 1 ]]; then
  echo "  --purge              : Secret Manager secrets (label managed-by=gke-secrets-seed), service accounts"
else
  echo "  Kept (use --purge) : Secret Manager secrets, service accounts"
fi
echo
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "Proceed? Type 'delete' to confirm: " CONFIRM
  [[ "$CONFIRM" == "delete" ]] || { echo "Aborted."; exit 0; }
fi

# ---- 1. In-cluster cleanup ----------------------------------------------------
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  gcloud container clusters get-credentials "$CLUSTER" --zone="$ZONE" >/dev/null 2>&1 || true
  if command -v kubectl >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; then
    log "Stopping Argo CD reconciliation (so it doesn't recreate what's deleted next)"
    kubectl scale statefulset argocd-application-controller -n argocd --replicas=0 2>/dev/null || skip
  else
    echo "WARNING: cluster exists but its API is unreachable (IP changed?); skipping in-cluster" >&2
    echo "         cleanup - the leftover checks after cluster deletion still run." >&2
  fi
fi

# ---- 2. GKE cluster ---------------------------------------------------------
log "Deleting cluster: $CLUSTER (this takes several minutes)"
if gcloud container clusters describe "$CLUSTER" --zone="$ZONE" &>/dev/null; then
  # GKE rejects the delete ("Cluster is running incompatible operation") while another
  # operation runs - typically a cluster-autoscaler resize triggered by the workload deletions
  # above. Wait for those to finish (up to 20 min) first. The targetLink match covers the
  # cluster and its node pools (a grouped `(/|$)` anchor matched nothing when tested).
  for _ in $(seq 1 80); do
    running=$(gcloud container operations list --zone="$ZONE" \
      --filter="status!=DONE AND targetLink~/clusters/$CLUSTER" --format='value(operationType)' 2>/dev/null || true)
    [[ -z "$running" ]] && break
    echo "    waiting for running cluster operation(s): $(tr '\n' ' ' <<<"$running")"
    sleep 15
  done
  gcloud container clusters delete "$CLUSTER" --zone="$ZONE" --quiet
else
  skip
fi

# ---- 3. Leftovers a cluster deletion leaves behind ------------------------------------
# Container-native load balancing leaves zonal network endpoint groups (one per Service port)
# behind when the cluster goes before the NEG controller has cleaned up; any NEG in this VPC
# blocks deleting it ("is already being used by .../networkEndpointGroups/k8s1-...").
log "Checking for leftover network endpoint groups in $VPC"
LEFTOVER_NEG=$(gcloud compute network-endpoint-groups list --filter="network~/${VPC}\$" \
  --format='value(name,zone.basename())' 2>/dev/null || true)
if [[ -n "$LEFTOVER_NEG" ]]; then
  while read -r neg zone; do
    gcloud compute network-endpoint-groups delete "$neg" --zone="$zone" --quiet
  done <<<"$LEFTOVER_NEG"
else
  echo "    none"
fi

# Deleting a GKE cluster does NOT delete the persistent disks behind its PVCs (the Trivy
# server's here); they'd keep billing. Some GKE versions label them with the
# cluster name; others (1.35.6, 2026-09-27) set no labels and only record the PVC in the
# disk's description (`"storage.gke.io/created-by":"pd.csi.storage.gke.io"`, name `pvc-...`).
# Match either, in the cluster's zone; only unattached disks are touched.
log "Checking for leftover PVC disks (unattached pvc-* disks from the PD CSI driver in $ZONE)"
LEFTOVER_DISKS=$(gcloud compute disks list \
  --filter="-users:* AND zone:($ZONE) AND (labels.goog-k8s-cluster-name=$CLUSTER OR (name~^pvc- AND description:pd.csi.storage.gke.io))" \
  --format='value(name,zone.basename())' 2>/dev/null || true)
if [[ -n "$LEFTOVER_DISKS" ]]; then
  while read -r disk zone; do
    gcloud compute disks delete "$disk" --zone="$zone" --quiet
  done <<<"$LEFTOVER_DISKS"
else
  echo "    none"
fi

# ---- 4. Network ------------------------------------------------------------------------------
# The VPC is dedicated to this platform, so every firewall rule in it is ours: the webhook rule
# from gke-deploy.sh plus anything GKE failed to clean up.
log "Deleting firewall rules in $VPC"
FW_RULES=$(gcloud compute firewall-rules list --filter="network~/${VPC}\$" --format='value(name)' 2>/dev/null || true)
if [[ -n "$FW_RULES" ]]; then
  # shellcheck disable=SC2086
  gcloud compute firewall-rules delete $FW_RULES --quiet
else
  skip
fi

log "Deleting Cloud NAT: $NAT"
if gcloud compute routers nats describe "$NAT" --router="$ROUTER" --region="$REGION" &>/dev/null; then
  gcloud compute routers nats delete "$NAT" --router="$ROUTER" --region="$REGION" --quiet
else
  skip
fi

log "Deleting Cloud Router: $ROUTER"
if gcloud compute routers describe "$ROUTER" --region="$REGION" &>/dev/null; then
  gcloud compute routers delete "$ROUTER" --region="$REGION" --quiet
else
  skip
fi

# Retry: NAT IP release and NEG cleanup can lag briefly behind their deletion.
log "Deleting subnet: $SUBNET"
if gcloud compute networks subnets describe "$SUBNET" --region="$REGION" &>/dev/null; then
  for attempt in 1 2 3 4; do
    if gcloud compute networks subnets delete "$SUBNET" --region="$REGION" --quiet; then
      break
    fi
    if [[ "$attempt" -eq 4 ]]; then
      echo "ERROR: could not delete subnet $SUBNET after 4 attempts." >&2
      echo "Something may still be using it (network endpoint groups, reserved IPs, other VMs):" >&2
      echo "  gcloud compute network-endpoint-groups list --filter='subnetwork~$SUBNET'" >&2
      exit 1
    fi
    echo "    retrying in 30s..."
    sleep 30
  done
else
  skip
fi

log "Deleting VPC: $VPC"
if gcloud compute networks describe "$VPC" &>/dev/null; then
  gcloud compute networks delete "$VPC" --quiet
else
  skip
fi

# ---- 5. --purge: persistent resources -----------------------------------------------------------
if [[ "$PURGE" -eq 1 ]]; then
  # Only the secrets gke-secrets-seed.sh created (it labels them), whatever their names.
  log "Purging Secret Manager secrets (label managed-by=gke-secrets-seed)"
  for s in $(gcloud secrets list --filter='labels.managed-by=gke-secrets-seed' --format='value(name.basename())' 2>/dev/null || true); do
    gcloud secrets delete "$s" --quiet 2>/dev/null && echo "    $s" || true
  done

  log "Purging service accounts"
  for pair in "${PROJECT_ROLES[@]}"; do
    gcloud projects remove-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${pair%%=*}@${PROJECT_ID}.iam.gserviceaccount.com" \
      --role="${pair#*=}" --condition=None --quiet >/dev/null 2>&1 || true
  done
  for sa in "${SERVICE_ACCOUNTS[@]}"; do
    gcloud iam service-accounts delete "${sa}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet 2>/dev/null \
      && echo "    $sa" || true
  done
fi

# ---- Summary ----------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32mTeardown complete.\033[0m') Billable cluster, disk and network resources are deleted.
EOF
if [[ "$PURGE" -ne 1 ]]; then
  cat <<EOF

  Still present (by design, for the next gke-deploy.sh): Secret Manager secrets, service
  accounts. Remove them with --purge.
EOF
fi
