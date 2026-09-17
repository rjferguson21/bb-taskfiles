#!/bin/bash
# Fast health check for a Big Bang / k3d deploy. Surfaces failing HelmReleases,
# Flux sources, and problem pods so issues show up early instead of at the
# `kubectl wait --timeout` barrier. Designed to drive a watch loop.
#
# Usage: ./health.sh
# Exit codes:
#   0 = everything ready
#   2 = still progressing (not ready yet, but no hard failure)
#   1 = hard failure detected (crashloop, image pull, install/upgrade failed)
set -uo pipefail

# Reasons that mean "this won't recover on its own" vs. a transient in-progress state.
hr_hard_re='Failed|RetriesExceeded|Error|Artifact|Denied|NotFound'
pod_hard_re='CrashLoopBackOff|ImagePullBackOff|ErrImagePull|InvalidImageName|CreateContainerConfigError|CreateContainerError|RunContainerError'

hard_fail=false
progressing=false

section() { printf '\n=== %s ===\n' "$1"; }

# Print not-ready objects of a Flux kind and classify each as hard-fail or progressing.
check_ready() {
  local kind="$1" label="$2" json out
  json=$(kubectl get "$kind" -A -o json 2>/dev/null || echo '{"items":[]}')
  out=$(echo "$json" | jq -r '
    .items[] | . as $o
    | (($o.status.conditions // []) | map(select(.type=="Ready")) | .[0]) as $c
    | select($c.status != "True")
    | "\($o.metadata.namespace)/\($o.metadata.name)\t\($c.reason // "Unknown")\t\($c.message // "")"')
  [[ -z "$out" ]] && return 0
  section "$label not ready"
  while IFS=$'\t' read -r name reason msg; do
    printf '%-45s %-20s %s\n' "$name" "$reason" "$msg"
    if echo "$reason" | grep -qE "$hr_hard_re"; then hard_fail=true; else progressing=true; fi
  done <<< "$out"
}

hr_json=$(kubectl get helmrelease -A -o json 2>/dev/null || echo '{"items":[]}')
hr_total=$(echo "$hr_json" | jq '.items | length')
if [[ "$hr_total" -eq 0 ]]; then
  echo "No HelmReleases found yet (cluster still bootstrapping)"
  progressing=true
fi

check_ready helmreleases       "HelmReleases"
check_ready gitrepositories    "GitRepositories"
check_ready helmrepositories   "HelmRepositories"
check_ready ocirepositories    "OCIRepositories"

# Problem / in-progress pods: waiting reasons, Pending, Failed, or Running-but-not-ready.
pods=$(kubectl get pods -A -o json 2>/dev/null | jq -r '
  .items[] | . as $p
  | select((($p.metadata.annotations["helm.sh/hook"]) // "") | test("test") | not)
  | ($p.status.phase) as $phase
  | [ (($p.status.containerStatuses // []) + ($p.status.initContainerStatuses // []))[]
      | .state.waiting.reason // empty ] as $waiting
  | (($p.status.containerStatuses // []) | map(select(.ready == false)) | length) as $notready
  | select($phase == "Pending" or $phase == "Failed" or ($waiting | length) > 0 or ($phase == "Running" and $notready > 0))
  | "\($p.metadata.namespace)/\($p.metadata.name)\t\($phase)\t\($waiting | join(","))"')
if [[ -n "$pods" ]]; then
  section "Pods not ready"
  while IFS=$'\t' read -r name phase waiting; do
    printf '%-55s %-10s %s\n' "$name" "$phase" "$waiting"
    if echo "$waiting" | grep -qE "$pod_hard_re" || [[ "$phase" == "Failed" ]]; then
      hard_fail=true
    else
      progressing=true
    fi
  done <<< "$pods"
fi

# Recent warnings — informational only, does not affect exit code.
warnings=$(kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp -o json 2>/dev/null \
  | jq -r '.items[-15:][] | "\(.metadata.namespace)/\(.involvedObject.name)\t\(.reason)\t\(.message)"' 2>/dev/null)
if [[ -n "$warnings" ]]; then
  section "Recent Warning events (last 15)"
  echo "$warnings"
fi

echo
if [[ "$hard_fail" == "true" ]]; then
  echo "RESULT: HARD FAILURE — see above; this will not recover on its own"
  exit 1
elif [[ "$progressing" == "true" ]]; then
  echo "RESULT: still progressing"
  exit 2
else
  echo "RESULT: all HelmReleases, sources, and pods ready"
  exit 0
fi
