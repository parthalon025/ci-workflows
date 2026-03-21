#!/usr/bin/env bash
set -euo pipefail

# ci-sweep.sh — Deploy ci-workflows caller templates to consumer repos.
# Reads TIER-ASSIGNMENTS.md, selects templates, substitutes variables,
# copies workflows, manages secrets, sets branch protection.

###############################################################################
# Paths (symlink-safe)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
ASSIGNMENTS="$SCRIPT_DIR/../docs/TIER-ASSIGNMENTS.md"
PROJECTS_DIR="$HOME/Documents/projects"
OWNER="parthalon025"

###############################################################################
# Colors
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

###############################################################################
# Globals
###############################################################################
DRY_RUN=false
VERIFY_ONLY=false
SECRETS_ONLY=false
TARGET_REPO=""
PROCESS_ALL=false
FAILURES=0

###############################################################################
# Logging helpers
###############################################################################
log_info()    { echo -e "${CYAN}[$1]${NC} $2"; }
log_success() { echo -e "${GREEN}[$1]${NC} $2"; }
log_warn()    { echo -e "${YELLOW}[$1]${NC} $2"; }
log_error()   { echo -e "${RED}[$1]${NC} $2"; }
log_header()  { echo -e "\n${BOLD}=== $1 ===${NC}"; }
log_dry()     { echo -e "${YELLOW}[DRY-RUN]${NC} $1"; }

###############################################################################
# Parse TIER-ASSIGNMENTS.md table
# Returns lines: tier|repo|language|release_type|deploy|install_command
###############################################################################
parse_assignments() {
    local in_table=false
    local header_skipped=false

    while IFS= read -r line; do
        # Detect table start (header row has "Tier" and "Repo")
        if [[ "$line" =~ ^\|[[:space:]]*Tier ]]; then
            in_table=true
            continue
        fi
        # Skip separator row (|------|------|...)
        if $in_table && [[ "$line" =~ ^\|[[:space:]]*-+ ]]; then
            header_skipped=true
            continue
        fi
        # Stop at next header or blank line after table
        if $in_table && $header_skipped; then
            if [[ ! "$line" =~ ^\| ]] || [[ -z "$line" ]]; then
                break
            fi
            # Parse columns: | Tier | Repo | Language | Release Type | Deploy | Install Command |
            local tier repo language release_type deploy install_cmd
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
# Determine caller template filename from tier + language
###############################################################################
get_template() {
    local tier="$1"
    local language="$2"

    case "$tier" in
        1)
            case "$language" in
                python) echo "ci-tier1-python.yml" ;;
                node)   echo "ci-tier1-node.yml" ;;
                mixed)  echo "ci-tier1-mixed.yml" ;;
                *)      echo "ci-tier1-python.yml" ;;  # shell fallback
            esac
            ;;
        2)
            case "$language" in
                python) echo "ci-tier2-python.yml" ;;
                node)   echo "ci-tier2-node.yml" ;;
                mixed)  echo "ci-tier2-mixed.yml" ;;
                shell)  echo "ci-tier2-python.yml" ;;  # shell repos use same structure
                *)      echo "ci-tier2-python.yml" ;;
            esac
            ;;
        3)
            echo "ci-tier3.yml"
            ;;
        *)
            log_error "UNKNOWN" "Unknown tier: $tier"
            return 1
            ;;
    esac
}

###############################################################################
# Generate ecosystem block for dependabot.yml
###############################################################################
generate_ecosystem_block() {
    local language="$1"
    local pip_block npm_block

    pip_block='  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5'

    npm_block='  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5'

    case "$language" in
        python)
            echo "$pip_block"
            ;;
        node)
            echo "$npm_block"
            ;;
        mixed)
            printf '%s\n%s' "$pip_block" "$npm_block"
            ;;
        shell|config|yaml)
            # github-actions only, no extra block
            echo ""
            ;;
        *)
            echo ""
            ;;
    esac
}

###############################################################################
# Generate release-please-config.json
###############################################################################
generate_release_please_config() {
    local release_type="$1"
    cat <<EOF
{
  "\$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "${release_type}",
      "bump-minor-pre-major": true
    }
  }
}
EOF
}

###############################################################################
# Remove old workflow files
###############################################################################
remove_old_workflows() {
    local repo="$1"
    local repo_dir="$PROJECTS_DIR/$repo"
    local old_files=(
        ".github/workflows/megalinter.yml"
        ".github/workflows/codety.yml"
        ".github/workflows/sonarcloud.yml"
        ".mega-linter.yml"
        "sonar-project.properties"
    )

    for f in "${old_files[@]}"; do
        local target="$repo_dir/$f"
        if [[ -f "$target" ]]; then
            if $DRY_RUN; then
                log_dry "[$repo] Would remove $f"
            else
                rm "$target"
                log_info "$repo" "Removed $f"
            fi
        fi
    done
}

###############################################################################
# Set branch protection via gh API
###############################################################################
set_branch_protection() {
    local repo="$1"

    if $DRY_RUN; then
        log_dry "[$repo] Would set branch protection (required check: CI Pass)"
        return 0
    fi

    log_info "$repo" "Setting branch protection..."
    if gh api "repos/$OWNER/$repo/branches/main/protection" -X PUT \
        --input - <<'PROTECTION_EOF'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["CI Pass"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null
}
PROTECTION_EOF
    then
        log_success "$repo" "Branch protection set"
    else
        log_warn "$repo" "Failed to set branch protection (may need admin access)"
    fi
}

###############################################################################
# Copy a file with placeholder substitution
###############################################################################
copy_template() {
    local src="$1"
    local dest="$2"
    shift 2
    # Remaining args are key=value substitution pairs

    if [[ ! -f "$src" ]]; then
        log_error "TEMPLATE" "Template not found: $src"
        return 1
    fi

    local content
    content=$(<"$src")

    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        content="${content//\{\{${key}\}\}/${val}}"
        shift
    done

    if $DRY_RUN; then
        log_dry "Would write $dest"
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    echo "$content" > "$dest"
}

###############################################################################
# Process a single repo
###############################################################################
process_repo() {
    local tier="$1"
    local repo="$2"
    local language="$3"
    local release_type="$4"
    local deploy="$5"

    local repo_dir="$PROJECTS_DIR/$repo"
    local wf_dir="$repo_dir/.github/workflows"

    log_header "Processing $repo (tier $tier, $language)"

    # Verify repo exists locally
    if [[ ! -d "$repo_dir" ]]; then
        log_error "$repo" "Repo directory not found at $repo_dir"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # 1. Determine and copy caller template
    local template_name
    template_name=$(get_template "$tier" "$language")
    log_info "$repo" "Copying $template_name -> .github/workflows/ci.yml"

    if ! $DRY_RUN; then
        mkdir -p "$wf_dir"
    fi

    copy_template "$TEMPLATES_DIR/$template_name" "$wf_dir/ci.yml"

    # 2. Copy supplemental workflows (tier 1 + 2)
    if [[ "$tier" == "1" || "$tier" == "2" ]]; then
        # release.yml
        log_info "$repo" "Copying release.yml (release-type: $release_type)"
        copy_template "$TEMPLATES_DIR/release.yml" "$wf_dir/release.yml" \
            "RELEASE_TYPE=$release_type"

        # Tier 1 only: nightly.yml + claude-review.yml
        if [[ "$tier" == "1" ]]; then
            log_info "$repo" "Copying nightly.yml (language: $language)"
            copy_template "$TEMPLATES_DIR/nightly.yml" "$wf_dir/nightly.yml" \
                "LANGUAGE=$language"

            log_info "$repo" "Copying claude-review.yml"
            copy_template "$TEMPLATES_DIR/claude-review.yml" "$wf_dir/claude-review.yml"
        fi

        # release-please-config.json
        log_info "$repo" "Generating release-please-config.json"
        if $DRY_RUN; then
            log_dry "[$repo] Would write release-please-config.json"
        else
            generate_release_please_config "$release_type" > "$repo_dir/release-please-config.json"
        fi
    fi

    # 3. Generate dependabot.yml
    log_info "$repo" "Generating dependabot.yml"
    local ecosystem_block
    ecosystem_block=$(generate_ecosystem_block "$language")
    copy_template "$TEMPLATES_DIR/dependabot.yml" "$repo_dir/.github/dependabot.yml" \
        "ECOSYSTEM_BLOCK=$ecosystem_block"

    # 4. Remove old workflows
    remove_old_workflows "$repo"

    # 5. Set branch protection
    set_branch_protection "$repo"

    # 6. Commit in consumer repo
    if $DRY_RUN; then
        log_dry "[$repo] Would commit: ci: adopt ci-workflows v1 (tier $tier)"
    else
        (
            cd "$repo_dir"
            git add .github/ release-please-config.json 2>/dev/null || true
            # Also stage deletions of old files
            git add -u .mega-linter.yml sonar-project.properties 2>/dev/null || true
            if git diff --cached --quiet; then
                log_warn "$repo" "No changes to commit"
            else
                git commit -m "ci: adopt ci-workflows v1 (tier $tier)"
                log_success "$repo" "Committed: ci: adopt ci-workflows v1 (tier $tier)"
            fi
        )
    fi

    log_success "$repo" "Done"
}

###############################################################################
# Set secrets for a repo
###############################################################################
set_secrets() {
    local tier="$1"
    local repo="$2"
    local deploy="$3"

    log_header "Secrets: $repo (tier $tier)"

    # Source env file
    if [[ ! -f "$HOME/.env" ]]; then
        log_error "$repo" "$HOME/.env not found"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # shellcheck source=/dev/null
    source "$HOME/.env"

    # Get existing secrets
    local existing_secrets
    existing_secrets=$(gh secret list --repo "$OWNER/$repo" 2>/dev/null | awk '{print $1}' || true)

    set_one_secret() {
        local name="$1"
        local value="$2"

        if [[ -z "$value" ]]; then
            log_warn "$repo" "$name not set in ~/.env — skipping"
            return 0
        fi

        if echo "$existing_secrets" | grep -qx "$name"; then
            log_info "$repo" "$name already exists — skipping"
            return 0
        fi

        if $DRY_RUN; then
            log_dry "[$repo] Would set secret $name"
            return 0
        fi

        echo "$value" | gh secret set "$name" --repo "$OWNER/$repo"
        log_success "$repo" "Set secret $name"
    }

    # Tier 1 secrets
    if [[ "$tier" == "1" ]]; then
        set_one_secret "ANTHROPIC_API_KEY" "${ANTHROPIC_API_KEY:-}"
        set_one_secret "CODECOV_TOKEN" "${CODECOV_TOKEN:-}"

        # Deploy secrets
        if [[ "$deploy" == "yes" ]]; then
            set_one_secret "TS_OAUTH_CLIENT_ID" "${TS_OAUTH_CLIENT_ID:-}"
            set_one_secret "TS_OAUTH_SECRET" "${TS_OAUTH_SECRET:-}"
        fi
    fi

    log_success "$repo" "Secrets done"
}

###############################################################################
# Verify a single repo
###############################################################################
verify_repo() {
    local tier="$1"
    local repo="$2"
    local language="$3"

    local repo_dir="$PROJECTS_DIR/$repo"
    local wf_dir="$repo_dir/.github/workflows"
    local status="OK"

    log_header "Verifying $repo (tier $tier, $language)"

    if [[ ! -d "$repo_dir" ]]; then
        log_error "$repo" "[MISSING] Repo directory not found"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    # Check ci.yml exists
    if [[ -f "$wf_dir/ci.yml" ]]; then
        # Check it matches expected template
        local template_name
        template_name=$(get_template "$tier" "$language")
        local expected_content
        expected_content=$(<"$TEMPLATES_DIR/$template_name")

        local actual_content
        actual_content=$(<"$wf_dir/ci.yml")

        if [[ "$actual_content" != "$expected_content" ]]; then
            log_warn "$repo" "[DRIFT] ci.yml differs from template $template_name"
            diff <(echo "$expected_content") <(echo "$actual_content") || true
            status="DRIFT"
        else
            log_success "$repo" "[OK] ci.yml matches $template_name"
        fi
    else
        log_error "$repo" "[MISSING] .github/workflows/ci.yml"
        status="MISSING"
    fi

    # Check dependabot.yml
    if [[ -f "$repo_dir/.github/dependabot.yml" ]]; then
        log_success "$repo" "[OK] dependabot.yml exists"
    else
        log_warn "$repo" "[MISSING] .github/dependabot.yml"
        if [[ "$status" == "OK" ]]; then status="MISSING"; fi
    fi

    # Check supplemental files for tier 1+2
    if [[ "$tier" == "1" || "$tier" == "2" ]]; then
        if [[ -f "$wf_dir/release.yml" ]]; then
            log_success "$repo" "[OK] release.yml exists"
        else
            log_warn "$repo" "[MISSING] release.yml"
            if [[ "$status" == "OK" ]]; then status="MISSING"; fi
        fi

        if [[ -f "$repo_dir/release-please-config.json" ]]; then
            log_success "$repo" "[OK] release-please-config.json exists"
        else
            log_warn "$repo" "[MISSING] release-please-config.json"
            if [[ "$status" == "OK" ]]; then status="MISSING"; fi
        fi
    fi

    if [[ "$tier" == "1" ]]; then
        for f in nightly.yml claude-review.yml; do
            if [[ -f "$wf_dir/$f" ]]; then
                log_success "$repo" "[OK] $f exists"
            else
                log_warn "$repo" "[MISSING] $f"
                if [[ "$status" == "OK" ]]; then status="MISSING"; fi
            fi
        done
    fi

    # Check required secrets
    local existing_secrets
    existing_secrets=$(gh secret list --repo "$OWNER/$repo" 2>/dev/null | awk '{print $1}' || true)

    if [[ "$tier" == "1" ]]; then
        for s in ANTHROPIC_API_KEY CODECOV_TOKEN; do
            if echo "$existing_secrets" | grep -qx "$s"; then
                log_success "$repo" "[OK] Secret $s"
            else
                log_warn "$repo" "[MISSING] Secret $s"
                if [[ "$status" == "OK" ]]; then status="MISSING"; fi
            fi
        done
    fi

    # Check old files are gone
    local old_files=(
        ".github/workflows/megalinter.yml"
        ".github/workflows/codety.yml"
        ".github/workflows/sonarcloud.yml"
        ".mega-linter.yml"
        "sonar-project.properties"
    )
    for f in "${old_files[@]}"; do
        if [[ -f "$repo_dir/$f" ]]; then
            log_warn "$repo" "[STALE] Old file still present: $f"
            if [[ "$status" == "OK" ]]; then status="DRIFT"; fi
        fi
    done

    echo -e "\n${BOLD}$repo: $status${NC}"
    if [[ "$status" != "OK" ]]; then
        FAILURES=$((FAILURES + 1))
    fi
}

###############################################################################
# Usage
###############################################################################
usage() {
    cat <<EOF
Usage: ci-sweep.sh [OPTIONS]

Deploy ci-workflows caller templates to consumer repos.

Options:
  --repo <name>    Process a single repo
  --all            Process all repos in TIER-ASSIGNMENTS.md
  --dry-run        Show what would happen without writing files or calling APIs
  --verify-only    Check current state against expected (no changes)
  --secrets        Set GitHub secrets from ~/.env
  -h, --help       Show this help message

Examples:
  ci-sweep.sh --repo lessons-db --dry-run     Preview changes for one repo
  ci-sweep.sh --all --dry-run                 Preview full sweep
  ci-sweep.sh --repo lessons-db               Deploy to one repo
  ci-sweep.sh --all                           Deploy to all repos
  ci-sweep.sh --verify-only --all             Verify all repos
  ci-sweep.sh --secrets --repo ha-aria        Set secrets for one repo
EOF
    exit 0
}

###############################################################################
# Main
###############################################################################
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo)
                TARGET_REPO="$2"
                shift 2
                ;;
            --all)
                PROCESS_ALL=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --secrets)
                SECRETS_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "ARGS" "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$TARGET_REPO" ]] && ! $PROCESS_ALL; then
        log_error "ARGS" "Must specify --repo <name> or --all"
        usage
    fi

    if [[ -n "$TARGET_REPO" ]] && $PROCESS_ALL; then
        log_error "ARGS" "Cannot use --repo and --all together"
        exit 1
    fi

    if [[ ! -f "$ASSIGNMENTS" ]]; then
        log_error "CONFIG" "TIER-ASSIGNMENTS.md not found at $ASSIGNMENTS"
        exit 1
    fi

    if $DRY_RUN; then
        echo -e "${YELLOW}${BOLD}DRY RUN — no files will be written, no APIs called${NC}\n"
    fi

    # Parse assignments
    local assignments
    assignments=$(parse_assignments)

    if [[ -z "$assignments" ]]; then
        log_error "CONFIG" "No repos found in TIER-ASSIGNMENTS.md"
        exit 1
    fi

    # Process repos
    while IFS='|' read -r tier repo language release_type deploy install_cmd; do
        # Filter to target repo if specified
        if [[ -n "$TARGET_REPO" ]] && [[ "$repo" != "$TARGET_REPO" ]]; then
            continue
        fi

        if $SECRETS_ONLY; then
            set_secrets "$tier" "$repo" "$deploy"
        elif $VERIFY_ONLY; then
            verify_repo "$tier" "$repo" "$language"
        else
            process_repo "$tier" "$repo" "$language" "$release_type" "$deploy"
        fi
    done <<< "$assignments"

    # Check if target repo was found
    if [[ -n "$TARGET_REPO" ]]; then
        local found=false
        while IFS='|' read -r _ repo _ _ _ _; do
            if [[ "$repo" == "$TARGET_REPO" ]]; then
                found=true
                break
            fi
        done <<< "$assignments"

        if ! $found; then
            log_error "CONFIG" "Repo '$TARGET_REPO' not found in TIER-ASSIGNMENTS.md"
            FAILURES=$((FAILURES + 1))
        fi
    fi

    # Summary
    echo ""
    if [[ $FAILURES -gt 0 ]]; then
        log_error "SUMMARY" "$FAILURES failure(s)"
        exit 1
    else
        log_success "SUMMARY" "All operations completed successfully"
    fi
}

main "$@"
