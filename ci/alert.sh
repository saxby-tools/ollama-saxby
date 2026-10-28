#!/usr/bin/env bash

#  =====================================================================
#  ci/alert.sh
#  =====================================================================
#  Opens, updates or closes the one alert issue per Ollama tag, so a
#  human hears about a failure once per tag rather than once per run.
#
#  Usage:
#    ci/alert.sh open  <patches|build> <tag> <reason> [log file]
#    ci/alert.sh close <patches|build> <tag>
#
#  Needs GH_TOKEN and the GITHUB_* variables Actions provides.

set -euo pipefail

# ---------------------------------------------------------
# CONSTANTS
# ---------------------------------------------------------
LOG_LINES=40

ACTION="${1:?open or close}"
KIND="${2:?patches or build}"
TAG="${3:?Ollama tag}"
REASON="${4:-}"
LOG_FILE="${5:-}"

RUN="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

title_for() {
    if [ "$KIND" = "build" ]; then
        echo "Native macOS build fails on Ollama $TAG"
        return
    fi

    echo "Patches fail on Ollama $TAG"
}

TITLE="$(title_for)"

find_issue() {
    gh issue list --state open --search "in:title \"$TITLE\"" \
        --json number,title \
        --jq ".[] | select(.title == \"$TITLE\") | .number" |
        head -1
}

write_body() {
    echo "$REASON Nothing was pinned or shipped."
    echo
    echo "Run: $RUN"

    if [ -z "$LOG_FILE" ]; then
        return
    fi

    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    echo
    echo '```'
    tail -"$LOG_LINES" "$LOG_FILE"
    echo '```'
}

open_alert() {
    local number body
    number="$(find_issue)"
    body="$(mktemp)"
    write_body >"$body"

    if [ -n "$number" ]; then
        gh issue comment "$number" --body-file "$body"
        return
    fi

    gh issue create --title "$TITLE" --body-file "$body"
}

close_alert() {
    local number
    number="$(find_issue)"

    if [ -z "$number" ]; then
        return
    fi

    gh issue close "$number" --comment "Passing again: $RUN"
}

case "$ACTION" in
    open) open_alert ;;
    close) close_alert ;;
    *) echo "unknown action: $ACTION" >&2; exit 64 ;;
esac
