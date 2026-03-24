#!/bin/bash
# Check for common Istio/Envoy networking errors in pod logs
# Usage: ./network.sh [namespace] [pod-pattern]
# Example: ./network.sh argocd argocd-server

set -euo pipefail

NAMESPACE="${1:-}"
POD_PATTERN="${2:-}"

# Error patterns to check
PATTERNS="BlackHoleCluster|[Cc]onnection[_ ][Rr]efused|RBAC: access denied"

# Build namespace list
if [[ -n "$NAMESPACE" ]]; then
    NAMESPACES="$NAMESPACE"
else
    NAMESPACES=$(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}')
fi

found_errors=false

for ns in $NAMESPACES; do
    pods=$(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')

    if [[ -n "$POD_PATTERN" ]]; then
        pods=$(echo "$pods" | grep -E "$POD_PATTERN" || true)
    fi

    for pod in $pods; do
        matches=$(kubectl logs -n "$ns" "$pod" --all-containers --tail=1000 2>/dev/null | grep -E "$PATTERNS" || true)

        if [[ -n "$matches" ]]; then
            found_errors=true
            echo "=== $ns/$pod ==="
            echo "$matches"
            echo
        fi
    done
done

if [[ "$found_errors" == "false" ]]; then
    echo "No networking errors found"
    exit 0
else
    exit 1
fi
