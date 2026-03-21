#!/usr/bin/env bash
set -euo pipefail

# ci-drift.sh -- Nightly configuration drift detector.
# Checks each repo's local checkout against expected ci-workflows conventions.
#
# Usage:
#   ci-drift.sh [--repo <name>] [--all] [--json] [--notify]
#
# Env vars:
#   TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID  (optional, required for --notify)

###############################################################################
# Paths
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ASSIGNMENTS="$SCRIPT_DIR/../docs/TIER-ASSIGNMENTS.md"
PROJECTS_DIR="$HOME/Documents/projects"
OWNER="parthalon025"

###############################################################################
# Defaults
###############################################################################
TARGET_REPO=""
PROCESS_ALL=false
JSON_OUTPUT=false
NOTIFY=false

# Accumulate results for JSON / summary
declare -a RESULT_LINES=()
DRIFT_COUNT=0
REPO_COUNT=0

###############################################################################
# Colors (suppressed in JSON mode)
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

###############################################################################
# Logging helpers
###############################################################################
log_ok()      { $JSON_OUTPUT || echo -e "  ${GREEN}[OK]${NC} $*"; }
log_drift()   { $JSON_OUTPUT || echo -e "  ${YELLOW}[DRIFT]${NC} $*"; }
log_missing() { $JSON_OUTPUT || echo -e "  ${RED}[MISSING]${NC} $*"; }
log_header()  { $JSON_OUTPUT || echo -e "\n--- $* ---"; }

###############################################################################
# Parse TIER-ASSIGNMENTS.md
# Outputs lines: tier|repo|language|release_type|deploy|install_cmd
###############################################################################
parse_assignments() {
    local in_table=false
    local header_skipped=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^\|[[:space:]]*Tier ]]; then
            in_table=true
            continue
        fi
        if $in_table && [[ "$line" =~ ^\|[[:space:]]*-+ ]]; then
            header_skipped=true
            continue
        fi
        if $in_table && $header_skipped; then
            if [[ ! "$line" =~ ^\| ]] || [[ -z "$line" ]]; then
                break
            fi
            local tier repo language
            tier=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
            repo=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$3); print $3}')
            language=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$4); print $4}')
            release_type=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$5); print $5}')
            deploy=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$6); print $6}')
            install_cmd=$(echo "$line" | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$7); print $7}')
            echo "${tier}|${repo}|${language}|${release_type}|${deploy}|${install_cmd}"
        fi
    done < "$ASSIGNMENTS"
}

###############################################################################
# Required secrets per tier
###############################################################################
required_secrets() {
    local tier="$1"
    case "$tier" in
        1) echo "ANTHROPIC_API_KEY CODECOV_TOKEN" ;;
        2) echo "" ;;
        3) echo "" ;;
        *) echo "" ;;
    esac
}

###############################################################################
# Check a single repo
# Outputs structured result lines; sets DRIFT_COUNT
###############################################################################
check_repo() {
    local tier="$1"
    local repo="$2"
    local language="$3"

    local repo_dir="$PROJECTS_DIR/$repo"
    local wf_dir="$repo_dir/.github/workflows"
    local ci_yml="$wf_dir/ci.yml"
    local dependabot_yml="$repo_dir/.github/dependabot.yml"

    local repo_drift=0
    local checks_ok=()
    local checks_drift=()
    local checks_missing=()

    log_header "$repo (tier $tier, $language)"

    # ---- 1. Repo exists locally ----
    if [[ ! -d "$repo_dir" ]]; then
        log_missing "$repo: local checkout not found at $repo_dir"
        checks_missing+=("local_checkout")
        _record_result "$repo" "$tier" "MISSING" "local checkout not found"
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        return
    fi

    # ---- 2. ci.yml exists ----
    if [[ -f "$ci_yml" ]]; then
        # Check it uses the reusable workflow pattern (simpler check per spec)
        if grep -q "uses: parthalon025/ci-workflows/" "$ci_yml" 2>/dev/null; then
            log_ok "ci.yml uses reusable workflow pattern"
            checks_ok+=("ci_yml_pattern")
        else
            log_drift "ci.yml: missing 'uses: parthalon025/ci-workflows/' -- may be legacy"
            checks_drift+=("ci_yml_pattern")
            repo_drift=1
        fi
    else
        log_missing "ci.yml (.github/workflows/ci.yml)"
        checks_missing+=("ci_yml")
        repo_drift=1
    fi

    # ---- 3. dependabot.yml exists ----
    if [[ -f "$dependabot_yml" ]]; then
        log_ok "dependabot.yml exists"
        checks_ok+=("dependabot_yml")
    else
        log_missing "dependabot.yml (.github/dependabot.yml)"
        checks_missing+=("dependabot_yml")
        repo_drift=1
    fi

    # ---- 4. Supplemental files for tier 1 + 2 ----
    if [[ "$tier" == "1" || "$tier" == "2" ]]; then
        for f in release.yml; do
            if [[ -f "$wf_dir/$f" ]]; then
                log_ok "$f exists"
                checks_ok+=("$f")
            else
                log_missing "$f (.github/workflows/$f)"
                checks_missing+=("$f")
                repo_drift=1
            fi
        done
    fi

    if [[ "$tier" == "1" ]]; then
        for f in nightly.yml claude-review.yml; do
            if [[ -f "$wf_dir/$f" ]]; then
                log_ok "$f exists"
                checks_ok+=("$f")
            else
                log_missing "$f (.github/workflows/$f)"
                checks_missing+=("$f")
                repo_drift=1
            fi
        done
    fi

    # ---- 5. Required secrets ----
    local secrets_needed
    secrets_needed=$(required_secrets "$tier")
    if [[ -n "$secrets_needed" ]]; then
        local existing_secrets=""
        if existing_secrets=$(gh secret list --repo "$OWNER/$repo" 2>/dev/null | awk '{print $1}'); then
            for secret in $secrets_needed; do
                if echo "$existing_secrets" | grep -qx "$secret"; then
                    log_ok "Secret $secret present"
                    checks_ok+=("secret_$secret")
                else
                    log_missing "Secret $secret not found in repo"
                    checks_missing+=("secret_$secret")
                    repo_drift=1
                fi
            done
        else
            log_drift "Could not list secrets for $repo (gh API error)"
            checks_drift+=("secrets_api")
        fi
    fi

    # ---- Record overall result ----
    if [[ $repo_drift -eq 0 ]]; then
        local summary="OK (${#checks_ok[@]} checks passed)"
        $JSON_OUTPUT || echo -e "  ${GREEN}[OK]${NC} All checks passed"
        _record_result "$repo" "$tier" "OK" "$summary"
    else
        DRIFT_COUNT=$((DRIFT_COUNT + 1))
        local missing_list
        missing_list=$(printf '%s\n' "${checks_missing[@]-}" | awk 'NF' | paste -sd,)
        local drift_list
        drift_list=$(printf '%s\n' "${checks_drift[@]-}" | awk 'NF' | paste -sd,)
        local detail=""
        [[ -n "$missing_list" ]] && detail+="MISSING:$missing_list "
        [[ -n "$drift_list" ]]   && detail+="DRIFT:$drift_list"
        _record_result "$repo" "$tier" "DRIFT" "${detail% }"
    fi
}

###############################################################################
# Store a result line for later JSON/summary output
###############################################################################
_record_result() {
    local repo="$1" tier="$2" status="$3" detail="$4"
    RESULT_LINES+=("${repo}|${tier}|${status}|${detail}")
}

###############################################################################
# Emit JSON summary to stdout
###############################################################################
emit_json() {
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{"
    echo "  \"timestamp\": \"$ts\","
    echo "  \"total\": $REPO_COUNT,"
    echo "  \"drift_count\": $DRIFT_COUNT,"
    echo "  \"repos\": ["
    local first=true
    for line in "${RESULT_LINES[@]}"; do
        IFS='|' read -r repo tier status detail <<< "$line"
        $first || echo ","
        first=false
        # Escape detail for JSON
        detail="${detail//\\/\\\\}"
        detail="${detail//\"/\\\"}"
        printf '    {"repo": "%s", "tier": "%s", "status": "%s", "detail": "%s"}' \
            "$repo" "$tier" "$status" "$detail"
    done
    echo ""
    echo "  ]"
    echo "}"
}

###############################################################################
# Send Telegram alert
###############################################################################
send_telegram_alert() {
    local message="$1"
    local tg_token="${TELEGRAM_BOT_TOKEN:-}"
    local tg_chat="${TELEGRAM_CHAT_ID:-}"

    if [[ -z "$tg_token" || -z "$tg_chat" ]]; then
        echo "[WARN] TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set -- skipping notification" >&2
        return 0
    fi

    local payload
    payload=$(printf '{"chat_id": "%s", "text": "%s", "parse_mode": "HTML"}' \
        "$tg_chat" \
        "$(echo "$message" | sed 's/"/\\"/g; s/$/\\n/g' | tr -d '\n')")

    curl -sS -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://api.telegram.org/bot${tg_token}/sendMessage" > /dev/null
}

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
Usage: ci-drift.sh [OPTIONS]

Detect configuration drift across consumer repos.

Options:
  --repo <name>   Check a single repo
  --all           Check all repos in TIER-ASSIGNMENTS.md
  --json          Emit JSON summary to stdout instead of colored text
  --notify        Send Telegram alert if drift found
  -h, --help      Show this help

Examples:
  ci-drift.sh --repo lessons-db
  ci-drift.sh --all
  ci-drift.sh --all --json
  ci-drift.sh --all --notify
EOF
    exit 0
}

###############################################################################
# Main
###############################################################################
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)    TARGET_REPO="$2"; shift 2 ;;
            --all)     PROCESS_ALL=true; shift ;;
            --json)    JSON_OUTPUT=true; shift ;;
            --notify)  NOTIFY=true; shift ;;
            -h|--help) usage ;;
            *) echo "[ERROR] Unknown option: $1" >&2; usage ;;
        esac
    done

    if [[ -z "$TARGET_REPO" ]] && ! $PROCESS_ALL; then
        echo "[ERROR] Must specify --repo <name> or --all" >&2
        usage
    fi

    if [[ ! -f "$ASSIGNMENTS" ]]; then
        echo "[ERROR] TIER-ASSIGNMENTS.md not found at $ASSIGNMENTS" >&2
        exit 1
    fi

    local assignments
    assignments=$(parse_assignments)

    if [[ -z "$assignments" ]]; then
        echo "[ERROR] No repos found in TIER-ASSIGNMENTS.md" >&2
        exit 1
    fi

    $JSON_OUTPUT || echo "ci-drift: checking repos against ci-workflows conventions"
    $JSON_OUTPUT || echo "============================================================"

    local found_target=false
    while IFS='|' read -r tier repo language release_type deploy install_cmd; do
        if [[ -n "$TARGET_REPO" ]] && [[ "$repo" != "$TARGET_REPO" ]]; then
            continue
        fi
        [[ "$repo" == "$TARGET_REPO" ]] && found_target=true

        REPO_COUNT=$((REPO_COUNT + 1))
        check_repo "$tier" "$repo" "$language"
    done <<< "$assignments"

    if [[ -n "$TARGET_REPO" ]] && ! $found_target; then
        echo "[ERROR] Repo '$TARGET_REPO' not found in TIER-ASSIGNMENTS.md" >&2
        exit 1
    fi

    # Output
    if $JSON_OUTPUT; then
        emit_json
    else
        echo ""
        echo "============================================================"
        if [[ $DRIFT_COUNT -eq 0 ]]; then
            echo -e "${GREEN}All $REPO_COUNT repo(s) OK -- no drift detected${NC}"
        else
            echo -e "${YELLOW}Drift detected in $DRIFT_COUNT / $REPO_COUNT repo(s)${NC}"
            for line in "${RESULT_LINES[@]}"; do
                IFS='|' read -r repo tier status detail <<< "$line"
                if [[ "$status" != "OK" ]]; then
                    echo -e "  ${YELLOW}$repo${NC}: $status -- $detail"
                fi
            done
        fi
    fi

    # Telegram notification
    if $NOTIFY && [[ $DRIFT_COUNT -gt 0 ]]; then
        local alert_msg
        alert_msg="<b>CI Drift Alert</b> -- $(date -u +"%Y-%m-%d %H:%M UTC")\n"
        alert_msg+="Drift in $DRIFT_COUNT / $REPO_COUNT repo(s):\n"
        for line in "${RESULT_LINES[@]}"; do
            IFS='|' read -r repo tier status detail <<< "$line"
            if [[ "$status" != "OK" ]]; then
                alert_msg+="  $repo ($status): $detail\n"
            fi
        done
        send_telegram_alert "$alert_msg"
    fi

    # Exit non-zero if drift found
    [[ $DRIFT_COUNT -eq 0 ]]
}

main "$@"
