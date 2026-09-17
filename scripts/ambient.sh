#!/bin/bash
# Check for common Istio Ambient/ztunnel errors in logs
# Usage: ./ambient.sh [namespace] [pod-pattern]
# Example: ./ambient.sh istio-system ztunnel

set -euo pipefail

NAMESPACE="${1:-istio-system}"
POD_PATTERN="${2:-ztunnel}"

# Error patterns to check in ztunnel logs
PATTERNS="error|failed|connection refused|certificate|denied|rejected|no healthy upstream"

# Build pod list from ztunnel daemonset
pods=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')

if [[ -n "$POD_PATTERN" ]]; then
    pods=$(echo "$pods" | grep -E "$POD_PATTERN" || true)
fi

if [[ -z "$pods" ]]; then
    echo "No ztunnel pods found in namespace $NAMESPACE matching pattern '$POD_PATTERN'"
    exit 0
fi

found_errors=false

for pod in $pods; do
    # Get logs and filter for errors/warnings only
    matches=$(kubectl logs -n "$NAMESPACE" "$pod" --tail=500 2>/dev/null | \
        grep -E "warn|error" | \
        grep -iE "$PATTERNS" | \
        grep -v "healthcheck" || true)

    if [[ -n "$matches" ]]; then
        found_errors=true
        echo "=== $NAMESPACE/$pod ==="
        echo "$matches" | head -50
        echo
    fi
done

if [[ "$found_errors" == "false" ]]; then
    echo "No ambient/ztunnel errors found"
    exit 0
else
    exit 1
fi
