#!/usr/bin/env bash
# Evaluates the Kyverno policies in k8s/policies/ against this repo's manifests - the same
# policies the cluster enforces, run before merge (CI: .github/workflows/policy-check.yml).
# Needs `kubectl` (for `kubectl kustomize`) and the `kyverno` CLI; run from anywhere.
#
#   1. ENFORCE set vs this repo's own workload manifests (WORKLOAD_DIRS) -> must pass, fails the check
#   2. AUDIT set vs the same manifests                                 -> reported, never fails
#   3. self-test: ENFORCE set vs a known-bad fixture                   -> must be rejected
#
# WORKLOAD_DIRS is empty until the repo ships its own workloads (third-party charts are checked
# in-cluster by the audit policies instead); steps 1 and 2 are skipped until then.
#
# The enforce and audit sets are separate runs on purpose: the CLI exits 1 on any failure and
# `--audit-warn` doesn't distinguish Deny from Audit for the CEL policy types, so a single run
# can't express "enforce fails, audit warns".
set -euo pipefail
cd "$(dirname "$0")"

for tool in kubectl kyverno; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Error: $tool is required."; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Kustomize directories of this repo's own workloads.
WORKLOAD_DIRS=()

kubectl kustomize k8s/policies/overlays/enforce-default > "$tmp/enforce.yaml"
{
  kubectl kustomize k8s/policies/overlays/audit-other
  echo "---"
  kubectl kustomize k8s/policies/audit-only
} > "$tmp/audit.yaml"

# apply <label> <policies> <resources>: runs the CLI, prints its output, and sets
#   rc (CLI exit code), rules (policy rules loaded), passed (passing evaluations).
# A run is only trusted if it loaded rules and reported no errors - otherwise the check would
# pass vacuously (e.g. a policy that no longer compiles).
apply() {
  local label="$1" out
  echo "=== ${label}"
  if out="$(kyverno apply "$2" --resource "$3" 2>&1)"; then rc=0; else rc=$?; fi
  echo "$out"
  rules="$(sed -n 's/^Applying \([0-9]*\) policy rule.*/\1/p' <<<"$out" | head -1)"
  passed="$(sed -n 's/^pass: \([0-9]*\),.*/\1/p' <<<"$out" | tail -1)"
  errors="$(sed -n 's/.*error: \([0-9]*\),\? *.*/\1/p' <<<"$out" | tail -1)"
  rules="${rules:-0}"; passed="${passed:-0}"; errors="${errors:-0}"
  if [ "$rules" -eq 0 ] || [ "$errors" -ne 0 ]; then
    echo "Error: '${label}' loaded ${rules} policy rule(s) with ${errors} error(s) - the check is not trustworthy."
    exit 1
  fi
}

failed=0

if [ ${#WORKLOAD_DIRS[@]} -eq 0 ]; then
  echo "=== No workload manifests (WORKLOAD_DIRS is empty) - skipping the enforce and audit runs."
else
  for d in "${WORKLOAD_DIRS[@]}"; do kubectl kustomize "$d"; echo "---"; done > "$tmp/app.yaml"

  apply "ENFORCE policies vs ${WORKLOAD_DIRS[*]}" "$tmp/enforce.yaml" "$tmp/app.yaml"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: the workload manifests violate the enforce policies - Kyverno would reject them."
    failed=1
  elif [ "$passed" -eq 0 ]; then
    echo "FAIL: no evaluation passed - the enforce policies didn't match any manifest."
    failed=1
  fi

  apply "AUDIT policies vs ${WORKLOAD_DIRS[*]} (report only)" "$tmp/audit.yaml" "$tmp/app.yaml" \
    | tee "$tmp/audit-report.txt"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo '### Kyverno audit findings (informational)'; echo '```'; cat "$tmp/audit-report.txt"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

echo
apply "SELF-TEST: enforce policies must reject the known-bad fixture" "$tmp/enforce.yaml" .github/policy-fixtures/violating-deployment.yaml
if [ "$rc" -eq 0 ]; then
  echo "FAIL: the violating fixture was NOT rejected - the enforce policies are not doing their job."
  failed=1
else
  echo "OK: fixture rejected, as it must be."
fi

echo
if [ "$failed" -ne 0 ]; then echo "Policy check FAILED."; exit 1; fi
echo "Policy check passed."
