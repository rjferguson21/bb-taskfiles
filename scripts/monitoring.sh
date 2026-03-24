#!/bin/bash
# Check Prometheus targets health by pattern
# Usage: ./monitoring.sh <pattern>
# Example: ./monitoring.sh "kube-state"

set -euo pipefail

PROMETHEUS_URL="${PROMETHEUS_URL:-https://prometheus.dev.bigbang.mil}"
PATTERN="${1:-}"

if [[ -z "$PATTERN" ]]; then
    echo "Usage: $0 <pattern>"
    echo "Example: $0 'kube-state'"
    exit 1
fi

# Try direct URL first, fall back to kubectl port-forward
fetch_targets() {
    local url="$1/api/v1/targets"

    # Try direct access
    if curl -sf --connect-timeout 5 "$url" 2>/dev/null; then
        return 0
    fi

    # Fall back to kubectl port-forward
    echo "Direct access failed, trying kubectl..." >&2

    local port=9090
    local local_port=$((9090 + RANDOM % 1000))

    # Find prometheus pod
    local pod
    pod=$(kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || \
    pod=$(kubectl get pods -n monitoring -l app=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "$pod" ]]; then
        echo "Error: Could not find prometheus pod" >&2
        return 1
    fi

    # Start port-forward in background
    kubectl port-forward -n monitoring "$pod" "$local_port:$port" &>/dev/null &
    local pf_pid=$!
    trap "kill $pf_pid 2>/dev/null || true" EXIT

    sleep 2
    curl -sf "http://localhost:$local_port/api/v1/targets"
}

# Fetch and filter targets
echo "Checking targets matching pattern: $PATTERN"
echo

targets_json=$(fetch_targets "$PROMETHEUS_URL")

if [[ -z "$targets_json" ]]; then
    echo "Error: Failed to fetch targets from Prometheus"
    exit 1
fi

# Parse and filter targets, check health
unhealthy=$(echo "$targets_json" | jq -r --arg pattern "$PATTERN" '
    .data.activeTargets[]
    | select((.labels.job // "" | test($pattern; "i")) or ((.scrapePool // "") | test($pattern; "i")))
    | select(.health != "up")
    | "\(.health)\t\(.labels.job // "unknown")\t\(.lastError // "no error")"
')

healthy_count=$(echo "$targets_json" | jq -r --arg pattern "$PATTERN" '
    [.data.activeTargets[]
    | select((.labels.job // "" | test($pattern; "i")) or ((.scrapePool // "") | test($pattern; "i")))
    | select(.health == "up")]
    | length
')

total_count=$(echo "$targets_json" | jq -r --arg pattern "$PATTERN" '
    [.data.activeTargets[]
    | select((.labels.job // "" | test($pattern; "i")) or ((.scrapePool // "") | test($pattern; "i")))]
    | length
')

if [[ "$total_count" -eq 0 ]]; then
    echo "No targets found matching pattern: $PATTERN"
    exit 0
fi

echo "Targets matching '$PATTERN': $healthy_count/$total_count healthy"
echo

# Print all matching targets
all_targets=$(echo "$targets_json" | jq -r --arg pattern "$PATTERN" '
    .data.activeTargets[]
    | select((.labels.job // "" | test($pattern; "i")) or ((.scrapePool // "") | test($pattern; "i")))
    | "\(.health)\t\(.labels.job // "unknown")\t\(.scrapeUrl // "unknown")"
')

echo "All matching targets:"
echo "STATUS    JOB                          SCRAPE URL"
echo "$all_targets" | while IFS=$'\t' read -r status job url; do
    printf "%-9s %-28s %s\n" "$status" "$job" "$url"
done
echo

if [[ -n "$unhealthy" ]]; then
    echo "Unhealthy targets:"
    echo "STATUS    JOB                          ERROR"
    echo "$unhealthy" | while IFS=$'\t' read -r status job error; do
        printf "%-9s %-28s %s\n" "$status" "$job" "$error"
    done
    exit 1
else
    echo "All matching targets are healthy"
    exit 0
fi
