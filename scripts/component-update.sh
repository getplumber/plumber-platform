#!/bin/bash

# Plumber CI/CD component update
# Refreshes your GitLab's copy of the Plumber CI/CD component (gitlab.com/getplumber/plumber)
# and publishes its latest version to your CI/CD catalog. Works for any Plumber install:
# Docker Compose, the Helm chart or anything else. It needs this scripts/ directory (it runs
# scripts/component-mirror.sh), curl and git, nothing from a running stack.
#
# Usage:
#   ./scripts/component-update.sh [--gitlab-url URL] [--project GROUP/NAME] [--publish-only] [--timeout SECONDS] [--dry-run]
#
# Each value is taken from the environment when set, else from the option, else asked for:
#   GitLab URL         GITLAB_URL                  --gitlab-url URL       prompt
#   Component project  PLUMBER_COMPONENT_PROJECT   --project GROUP/NAME   prompt   (full path, e.g. my-group/plumber)
#   GitLab token       PLUMBER_COMPONENT_TOKEN     (never an option)      prompt   (Owner of the group, api scope)
#
# Options:
#   --publish-only       Skip the copy, only flag the project and publish the latest tag
#   --timeout SECONDS    How long to wait for the publish pipeline (default: 600)
#   --dry-run            Print what would be done, touch nothing (no token needed)
#
# The token is used for this run only and never stored. Exit codes: 0 published,
# 1 not published (the reason is printed), 2 usage.

set -euo pipefail

RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIRROR="${SCRIPT_DIR}/component-mirror.sh"

OPT_GITLAB_URL=""
OPT_PROJECT=""
MIRROR_ARGS=()
DRY_RUN=false

usage() {
    sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gitlab-url) OPT_GITLAB_URL="${2:-}"; shift 2 ;;
        --project) OPT_PROJECT="${2:-}"; shift 2 ;;
        --publish-only) MIRROR_ARGS+=(--publish-only); shift ;;
        --timeout) MIRROR_ARGS+=(--timeout "${2:-}"); shift 2 ;;
        --dry-run) DRY_RUN=true; MIRROR_ARGS+=(--dry-run); shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Error:${NC} unknown option: $1"; usage ;;
    esac
done

[ -f "$MIRROR" ] || { echo -e "${RED}Error:${NC} ${MIRROR} is missing. This script needs the whole scripts/ directory of the plumber-platform repository."; exit 1; }

# A prompt needs a terminal; without one a missing value is an error, never a hang.
can_prompt() { ( exec < /dev/tty ) 2>/dev/null; }

# resolve <label> <environment variable> <option value> <option name> <prompt>
# Sets VALUE and SOURCE. Environment first, then the option, then the prompt.
VALUE=""
SOURCE=""
resolve() {
    local label="$1" var="$2" opt_value="$3" opt_name="$4" prompt="$5"
    if [ -n "${!var:-}" ]; then
        VALUE="${!var}"; SOURCE="from the environment (${var})"; return
    fi
    if [ -n "$opt_value" ]; then
        VALUE="$opt_value"; SOURCE="from ${opt_name}"; return
    fi
    if ! can_prompt; then
        echo -e "${RED}Error:${NC} ${label} is not set and there is no terminal to ask on. Set ${var} or pass ${opt_name}."
        exit 2
    fi
    while :; do
        echo -ne "${BOLD}${prompt}${NC}: "
        read -r VALUE < /dev/tty
        [ -n "$VALUE" ] && break
        echo -e "${RED}  This field is required.${NC}"
    done
    SOURCE="from the prompt"
}

resolve "GitLab URL" GITLAB_URL "$OPT_GITLAB_URL" --gitlab-url "GitLab instance URL (e.g. https://gitlab.example.com)"
GITLAB_URL="${VALUE%/}"
[[ "$GITLAB_URL" =~ ^https?:// ]] || GITLAB_URL="https://${GITLAB_URL}"
GITLAB_URL_SOURCE="$SOURCE"

resolve "Component project" PLUMBER_COMPONENT_PROJECT "$OPT_PROJECT" --project "Component project full path (e.g. my-group/plumber)"
PROJECT_PATH="${VALUE#/}"; PROJECT_PATH="${PROJECT_PATH%/}"
PROJECT_SOURCE="$SOURCE"
if [[ "$PROJECT_PATH" != */* ]]; then
    echo -e "${RED}Error:${NC} the component project must be a full path with its group, e.g. my-group/plumber (got '${PROJECT_PATH}')."
    exit 2
fi
GROUP="${PROJECT_PATH%/*}"
NAME="${PROJECT_PATH##*/}"

echo ""
echo -e "${BOLD}Plumber CI/CD component update${NC}"
echo -e "  GitLab:   ${GITLAB_URL} ${DIM}(${GITLAB_URL_SOURCE})${NC}"
echo -e "  Project:  ${PROJECT_PATH} ${DIM}(${PROJECT_SOURCE})${NC}"

if [ "$DRY_RUN" = false ] && [ -z "${PLUMBER_COMPONENT_TOKEN:-}" ]; then
    if ! can_prompt; then
        echo -e "${RED}Error:${NC} PLUMBER_COMPONENT_TOKEN is not set and there is no terminal to ask on. Export it (never pass it as an argument)."
        exit 2
    fi
    read -rs -p "GitLab token (Owner of ${GROUP}, api scope, used for this run only): " PLUMBER_COMPONENT_TOKEN < /dev/tty
    echo ""
    [ -n "$PLUMBER_COMPONENT_TOKEN" ] || { echo -e "${RED}Error:${NC} a token is required."; exit 2; }
    export PLUMBER_COMPONENT_TOKEN
fi

STATUS=0
bash "$MIRROR" --gitlab-url "$GITLAB_URL" --group "$GROUP" --project "$NAME" "${MIRROR_ARGS[@]}" || STATUS=$?
unset PLUMBER_COMPONENT_TOKEN
exit "$STATUS"
