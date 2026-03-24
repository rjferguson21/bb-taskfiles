#!/usr/bin/env bash
set -euo pipefail

# Usage: ./pending.sh [MR_URL]
# Example: ./pending.sh https://repo1.dso.mil/big-bang/bigbang/-/merge_requests/7339
# If no URL provided, auto-detects MR for current branch

if [[ $# -lt 1 ]]; then
    # Auto-detect MR for current branch
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
    if [[ -z "$CURRENT_BRANCH" ]]; then
        echo "Error: Not in a git repository or no branch checked out"
        exit 1
    fi

    # Get remote URL to determine project path
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ -z "$REMOTE_URL" ]]; then
        echo "Error: No origin remote found"
        exit 1
    fi

    # Extract project path from remote URL
    # Handles: git@repo1.dso.mil:big-bang/bigbang.git or https://repo1.dso.mil/big-bang/bigbang.git
    if [[ "$REMOTE_URL" =~ repo1\.dso\.mil[:/](.+?)(\.git)?$ ]]; then
        PROJECT_PATH="${BASH_REMATCH[1]}"
        PROJECT_PATH="${PROJECT_PATH%.git}"
    else
        echo "Error: Could not parse project path from remote URL: $REMOTE_URL"
        exit 1
    fi

    PROJECT_ENCODED="${PROJECT_PATH//\//%2F}"

    echo "Detecting MR for branch: $CURRENT_BRANCH"

    # Find MR for current branch
    MR_INFO=$(glab api "projects/${PROJECT_ENCODED}/merge_requests?source_branch=${CURRENT_BRANCH}&state=opened" 2>/dev/null | jq '.[0] // empty')

    if [[ -z "$MR_INFO" || "$MR_INFO" == "null" ]]; then
        echo "No open MR found for branch: $CURRENT_BRANCH"
        exit 0
    fi

    MR_NUMBER=$(echo "$MR_INFO" | jq -r '.iid')
    MR_URL=$(echo "$MR_INFO" | jq -r '.web_url')
    echo "Found: $MR_URL"
    echo
else
    MR_URL="$1"

    # Parse the MR URL to extract project path and MR number
    # Expected format: https://repo1.dso.mil/<project>/-/merge_requests/<number>
    if [[ ! "$MR_URL" =~ ^https://repo1\.dso\.mil/(.+)/-/merge_requests/([0-9]+)$ ]]; then
        echo "Error: Invalid MR URL format"
        echo "Expected: https://repo1.dso.mil/<project>/-/merge_requests/<number>"
        exit 1
    fi

    PROJECT_PATH="${BASH_REMATCH[1]}"
    MR_NUMBER="${BASH_REMATCH[2]}"
    PROJECT_ENCODED="${PROJECT_PATH//\//%2F}"
fi

echo "Checking MR !${MR_NUMBER} in ${PROJECT_PATH}..."
echo

# Get MR info including head pipeline
MR_INFO=$(glab api "projects/${PROJECT_ENCODED}/merge_requests/${MR_NUMBER}" 2>/dev/null)

MR_TITLE=$(echo "$MR_INFO" | jq -r '.title')
MR_STATE=$(echo "$MR_INFO" | jq -r '.state')
PIPELINE_ID=$(echo "$MR_INFO" | jq -r '.head_pipeline.id // empty')
PIPELINE_STATUS=$(echo "$MR_INFO" | jq -r '.head_pipeline.status // "no pipeline"')

echo "Title: $MR_TITLE"
echo "State: $MR_STATE"
echo "Pipeline: $PIPELINE_STATUS"
echo

if [[ -z "$PIPELINE_ID" || "$PIPELINE_ID" == "null" ]]; then
    echo "No pipeline found for this MR"
    exit 0
fi

# Check if pipeline is passing
if [[ "$PIPELINE_STATUS" == "success" ]]; then
    echo "✅ Pipeline is PASSING"
    exit 0
fi

if [[ "$PIPELINE_STATUS" == "running" || "$PIPELINE_STATUS" == "pending" ]]; then
    echo "🔄 Pipeline is still running..."
    echo
fi

# Get failed jobs (excluding jobs that are allowed to fail)
FAILED_JOBS=$(glab api "projects/${PROJECT_ENCODED}/pipelines/${PIPELINE_ID}/jobs?per_page=100" 2>/dev/null | jq -r '.[] | select(.status == "failed" and .allow_failure == false)')

if [[ -z "$FAILED_JOBS" ]]; then
    if [[ "$PIPELINE_STATUS" == "running" || "$PIPELINE_STATUS" == "pending" ]]; then
        echo "No blocking failed jobs yet"
        exit 0
    fi
    echo "⚠️  Pipeline status: $PIPELINE_STATUS (no blocking failures - only allow_failure jobs failed)"
    exit 0
fi

echo "❌ FAILED JOBS (blocking):"
echo "========================="

# Process each failed job
echo "$FAILED_JOBS" | jq -s '.' | jq -c '.[]' | while read -r job; do
    JOB_ID=$(echo "$job" | jq -r '.id')
    JOB_NAME=$(echo "$job" | jq -r '.name')
    JOB_STAGE=$(echo "$job" | jq -r '.stage')

    echo
    echo "Job: $JOB_NAME (stage: $JOB_STAGE)"
    echo "URL: https://repo1.dso.mil/${PROJECT_PATH}/-/jobs/${JOB_ID}"
    echo

    # Get job trace and extract failure reason
    TRACE=$(glab api "projects/${PROJECT_ENCODED}/jobs/${JOB_ID}/trace" 2>/dev/null || echo "")

    if [[ -n "$TRACE" ]]; then
        # Look for common error patterns and extract the reason
        # Strip ANSI codes for cleaner parsing
        CLEAN_TRACE=$(echo "$TRACE" | sed 's/\x1b\[[0-9;]*m//g')

        # Extract FATAL errors (common in BB CI)
        FATAL_ERRORS=$(echo "$CLEAN_TRACE" | grep -i '\[FATAL\]' | head -5 || true)

        # Extract generic error/failure lines if no FATAL found
        if [[ -z "$FATAL_ERRORS" ]]; then
            FATAL_ERRORS=$(echo "$CLEAN_TRACE" | grep -iE '(error|failed|failure):' | tail -5 || true)
        fi

        # Extract assertion failures (for test jobs)
        if [[ -z "$FATAL_ERRORS" ]]; then
            FATAL_ERRORS=$(echo "$CLEAN_TRACE" | grep -iE '(AssertionError|assert|expected|actual)' | head -5 || true)
        fi

        if [[ -n "$FATAL_ERRORS" ]]; then
            echo "Reason:"
            echo "$FATAL_ERRORS" | sed 's/^/  /'
        else
            # Fallback: show last 10 non-empty lines before the error
            echo "Reason (last lines of output):"
            echo "$CLEAN_TRACE" | grep -v '^$' | tail -10 | sed 's/^/  /'
        fi
    else
        echo "Reason: Could not retrieve job trace"
    fi
done

echo
if [[ "$PIPELINE_STATUS" == "failed" ]]; then
    exit 1
fi
exit 0
