#!/bin/bash

# Plumber CI/CD component mirror
# Copies the Plumber GitLab CI/CD component (gitlab.com/getplumber/plumber) into a
# project of your own GitLab instance and publishes its latest version to that
# instance's CI/CD catalog. Safe to run again: it refreshes the copy and publishes
# a newer version when there is one.
#
# Usage:
#   PLUMBER_COMPONENT_TOKEN=<token> ./scripts/component-mirror.sh --gitlab-url https://gitlab.example.com --group my-group
#
# Options:
#   --gitlab-url URL     Your GitLab instance (required)
#   --group PATH         Full path of the group that receives the project (required)
#   --project NAME       Project path inside the group (default: plumber)
#   --source URL         Git URL to copy from (default: https://gitlab.com/getplumber/plumber.git)
#   --publish-only       Skip the copy, only flag the project and publish the latest tag
#   --timeout SECONDS    How long to wait for the publish pipeline (default: 600)
#   --dry-run            Print what would be done, touch nothing
#
# The token comes from the PLUMBER_COMPONENT_TOKEN environment variable, never from
# the command line, and is used only for this run. It needs the `api` scope and an
# Owner of the group (or an instance Admin): flagging a project as a CI/CD catalog
# project is an Owner action in GitLab.
#
# Exit codes: 0 published, 1 not published (the reason is printed), 2 usage.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SOURCE_DEFAULT="https://gitlab.com/getplumber/plumber.git"
DESCRIPTION="Plumber CLI component for checking CI/CD pipeline and repo compliance"

GITLAB_URL=""
GROUP=""
PROJECT="plumber"
SOURCE="${PLUMBER_COMPONENT_SOURCE:-$SOURCE_DEFAULT}"
PUBLISH_ONLY=false
DRY_RUN=false
TIMEOUT=600

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gitlab-url) GITLAB_URL="${2:-}"; shift 2 ;;
        --group) GROUP="${2:-}"; shift 2 ;;
        --project) PROJECT="${2:-}"; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        --publish-only) PUBLISH_ONLY=true; shift ;;
        --timeout) TIMEOUT="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo -e "${RED}Error:${NC} unknown option: $1"; usage ;;
    esac
done

[ -n "$GITLAB_URL" ] || { echo -e "${RED}Error:${NC} --gitlab-url is required."; usage; }
[ -n "$GROUP" ] || { echo -e "${RED}Error:${NC} --group is required."; usage; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo -e "${RED}Error:${NC} --timeout must be a number of seconds."; usage; }

GITLAB_URL="${GITLAB_URL%/}"
[[ "$GITLAB_URL" =~ ^https?:// ]] || GITLAB_URL="https://${GITLAB_URL}"
GROUP="${GROUP#/}"; GROUP="${GROUP%/}"
PROJECT="${PROJECT#/}"; PROJECT="${PROJECT%/}"
FULL_PATH="${GROUP}/${PROJECT}"
HOST="${GITLAB_URL#*://}"
API="${GITLAB_URL}/api/v4"

if [ "$DRY_RUN" = true ]; then
    echo "Dry run, nothing is created or pushed."
    echo "  GitLab:        ${GITLAB_URL}"
    echo "  Project:       ${FULL_PATH}"
    echo "  Source:        ${SOURCE}"
    echo "  Steps:         check token role and runners, create or reuse the project (with a description),"
    if [ "$PUBLISH_ONLY" = true ]; then
        echo "                 skip the copy (--publish-only),"
    else
        echo "                 push every branch and tag of the source with ci.skip,"
    fi
    echo "                 flag the project as a CI/CD catalog project, run the release pipeline"
    echo "                 on the latest tag, wait for it (up to ${TIMEOUT}s) and verify the catalog version."
    echo "  Then set in Plumber Settings > Component: component_path = ${FULL_PATH}"
    exit 0
fi

TOKEN="${PLUMBER_COMPONENT_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo -e "${RED}Error:${NC} PLUMBER_COMPONENT_TOKEN is not set (export it, never pass it as an argument)."
    exit 2
fi
for tool in curl git; do
    command -v "$tool" > /dev/null 2>&1 || { echo -e "${RED}Error:${NC} ${tool} is required."; exit 1; }
done

WORK=""
cleanup() {
    [ -n "$WORK" ] && rm -rf "$WORK"
    unset TOKEN PLUMBER_COMPONENT_TOKEN
}
trap cleanup EXIT

# --- tiny JSON readers: the FIRST occurrence of a key, which in GitLab's answers is the
# top-level field (nested objects such as namespace or user come later) ---------------------
json_str() { grep -o "\"$1\":\"[^\"]*\"" <<<"$2" | head -n 1 | sed 's/^"[^"]*":"//; s/"$//'; }
json_num() { grep -o "\"$1\":[0-9]*" <<<"$2" | head -n 1 | sed 's/^.*://'; }
json_true() { grep -q "\"$1\":true" <<<"$2"; }
json_false() { grep -q "\"$1\":false" <<<"$2"; }
urlenc() { printf '%s' "$1" | sed 's|/|%2F|g; s|\.|%2E|g'; }

HTTP_CODE=""
BODY=""
api() { # api <METHOD> <path> [curl data args...]
    local method="$1" path="$2"; shift 2
    local out
    out=$(curl -sS --connect-timeout 10 --max-time 120 -X "$method" \
        -H "PRIVATE-TOKEN: ${TOKEN}" -w $'\n%{http_code}' "$@" "${API}${path}") || {
        echo -e "${RED}Error:${NC} cannot reach ${API}${path}"; exit 1; }
    HTTP_CODE="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}
graphql() { # graphql <query string, already JSON-escaped>
    local out
    out=$(curl -sS --connect-timeout 10 --max-time 120 -X POST \
        -H "PRIVATE-TOKEN: ${TOKEN}" -H "Content-Type: application/json" \
        -w $'\n%{http_code}' --data "{\"query\":\"$1\"}" "${GITLAB_URL}/api/graphql") || {
        echo -e "${RED}Error:${NC} cannot reach ${GITLAB_URL}/api/graphql"; exit 1; }
    HTTP_CODE="${out##*$'\n'}"
    BODY="${out%$'\n'*}"
}
fail() { echo -e "${RED}!${NC} $1"; echo -e "${RED}Component NOT published.${NC}"; exit 1; }

echo ""
echo -e "${BOLD}Plumber CI/CD component: ${FULL_PATH} on ${HOST}${NC}"
echo "───────────────────────────────────────"

# --- 1. Who is the token, and can it publish? ----------------------------------------------
api GET /user
[ "$HTTP_CODE" = "200" ] || fail "the token is not accepted by ${GITLAB_URL} (HTTP ${HTTP_CODE}). It needs the api scope."
USER_ID=$(json_num id "$BODY")
USERNAME=$(json_str username "$BODY")
IS_ADMIN=false
json_true is_admin "$BODY" && IS_ADMIN=true
echo -e "${GREEN}✓${NC} Token accepted (${USERNAME})"

api GET "/groups/$(urlenc "$GROUP")"
[ "$HTTP_CODE" = "200" ] || fail "group '${GROUP}' not found or not visible to this token (HTTP ${HTTP_CODE})."
GROUP_ID=$(json_num id "$BODY")
GROUP_VISIBILITY=$(json_str visibility "$BODY")
echo -e "${GREEN}✓${NC} Group ${GROUP} (id ${GROUP_ID}, ${GROUP_VISIBILITY})"

if [ "$IS_ADMIN" = false ]; then
    api GET "/groups/${GROUP_ID}/members/all/${USER_ID}"
    LEVEL=$(json_num access_level "$BODY")
    if [ "$HTTP_CODE" != "200" ] || [ "${LEVEL:-0}" -lt 50 ]; then
        fail "${USERNAME} is not an Owner of ${GROUP} (access level ${LEVEL:-none}). Flagging the project as a CI/CD catalog project needs an Owner of the group or an instance Admin."
    fi
fi
echo -e "${GREEN}✓${NC} ${USERNAME} can publish to the catalog"

# --- 2. The project, with a description (the catalog refuses a project without one) -------
api GET "/projects/$(urlenc "$FULL_PATH")"
if [ "$HTTP_CODE" = "404" ]; then
    api POST /projects \
        --data-urlencode "name=${PROJECT}" --data-urlencode "path=${PROJECT}" \
        --data-urlencode "namespace_id=${GROUP_ID}" --data-urlencode "description=${DESCRIPTION}" \
        --data-urlencode "visibility=${GROUP_VISIBILITY}" --data-urlencode "initialize_with_readme=false"
    [ "$HTTP_CODE" = "201" ] || fail "cannot create ${FULL_PATH} (HTTP ${HTTP_CODE}): ${BODY}"
    PROJECT_ID=$(json_num id "$BODY")
    echo -e "${GREEN}✓${NC} Project ${FULL_PATH} created (id ${PROJECT_ID})"
elif [ "$HTTP_CODE" = "200" ]; then
    PROJECT_ID=$(json_num id "$BODY")
    echo -e "${GREEN}✓${NC} Project ${FULL_PATH} exists (id ${PROJECT_ID})"
    if [ -z "$(json_str description "$BODY")" ]; then
        api PUT "/projects/${PROJECT_ID}" --data-urlencode "description=${DESCRIPTION}"
        [ "$HTTP_CODE" = "200" ] || fail "cannot set the project description (HTTP ${HTTP_CODE})."
        echo -e "${GREEN}✓${NC} Description set (required by the catalog)"
    fi
    if json_false jobs_enabled "$BODY" || grep -q '"builds_access_level":"disabled"' <<<"$BODY"; then
        fail "CI/CD is disabled on ${FULL_PATH}; publishing needs a pipeline. Enable it in the project settings and run again."
    fi
else
    fail "cannot read ${FULL_PATH} (HTTP ${HTTP_CODE})."
fi
PROJECT_URL="${GITLAB_URL}/${FULL_PATH}"

# --- 3. A runner must be able to pick the publish job -------------------------------------
api GET "/projects/${PROJECT_ID}/runners?status=online&per_page=1"
if [ "$HTTP_CODE" != "200" ] || [ "$BODY" = "[]" ]; then
    fail "no online runner is available to ${FULL_PATH}. The publish pipeline needs one (shared, group or project runner) that can pull registry.gitlab.com/gitlab-org/release-cli."
fi
echo -e "${GREEN}✓${NC} An online runner is available"

# --- 4. Copy: every branch and tag of the source, without triggering a pipeline per tag ----
if [ "$PUBLISH_ONLY" = false ]; then
    WORK=$(mktemp -d)
    echo "Copying ${SOURCE}..."
    git clone --quiet --mirror "$SOURCE" "$WORK/repo" || fail "cannot clone ${SOURCE}."
    # The token reaches git through a credential helper reading the environment: it is never on
    # the command line, never in the remote URL, never in any file.
    git -C "$WORK/repo" \
        -c credential.helper= \
        -c 'credential.helper=!f() { echo username=oauth2; echo "password=${PLUMBER_COMPONENT_TOKEN}"; }; f' \
        push --quiet --prune -o ci.skip "${PROJECT_URL}.git" \
        'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' \
        || fail "cannot push to ${PROJECT_URL}."
    echo -e "${GREEN}✓${NC} Branches and tags copied to ${PROJECT_URL}"
fi

# --- 5. Latest semver tag on the copy --------------------------------------------------------
api GET "/projects/${PROJECT_ID}/repository/tags?order_by=version&sort=desc&per_page=1"
[ "$HTTP_CODE" = "200" ] || fail "cannot list the tags of ${FULL_PATH} (HTTP ${HTTP_CODE})."
LATEST_TAG=$(json_str name "$BODY")
[[ "$LATEST_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "no semver tag found on ${FULL_PATH} (got '${LATEST_TAG}'); nothing to publish."
echo -e "${GREEN}✓${NC} Latest version: ${LATEST_TAG}"

# --- 6. Flag the project as a CI/CD catalog project (GraphQL only, Owner action) -----------
graphql "mutation { catalogResourcesCreate(input: {projectPath: \\\"${FULL_PATH}\\\"}) { errors } }"
if [ "$HTTP_CODE" != "200" ] || grep -q '"errors":\[[^]]' <<<"$BODY"; then
    # An already-flagged project answers with an error; the query below is the truth.
    graphql "{ ciCatalogResource(fullPath: \\\"${FULL_PATH}\\\") { id } }"
    grep -q '"id":"gid://gitlab/Ci::Catalog::Resource/' <<<"$BODY" \
        || fail "cannot flag ${FULL_PATH} as a CI/CD catalog project: ${BODY}"
fi
echo -e "${GREEN}✓${NC} Flagged as a CI/CD catalog project"

# --- 7. Publish the latest version: a release made by a pipeline (the only way in) ---------
is_published() {
    graphql "{ ciCatalogResource(fullPath: \\\"${FULL_PATH}\\\") { versions(first: 50) { nodes { name } } } }"
    grep -q "\"name\":\"${LATEST_TAG}\"" <<<"$BODY"
}
if is_published; then
    echo -e "${GREEN}✓${NC} ${LATEST_TAG} is already in the catalog"
else
    api POST "/projects/${PROJECT_ID}/pipeline?ref=$(urlenc "$LATEST_TAG")"
    [ "$HTTP_CODE" = "201" ] || fail "cannot start the release pipeline on ${LATEST_TAG} (HTTP ${HTTP_CODE}): ${BODY}"
    PIPELINE_ID=$(json_num id "$BODY")
    PIPELINE_URL="${PROJECT_URL}/-/pipelines/${PIPELINE_ID}"
    echo "Release pipeline started: ${PIPELINE_URL}"
    echo -ne "${DIM}Waiting for it (up to ${TIMEOUT}s)...${NC}"
    STATUS="created"
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while :; do
        api GET "/projects/${PROJECT_ID}/pipelines/${PIPELINE_ID}"
        STATUS=$(json_str status "$BODY")
        case "$STATUS" in
            success|failed|canceled|skipped) break ;;
        esac
        if [ "$(date +%s)" -ge "$DEADLINE" ]; then break; fi
        echo -n "."
        sleep 10
    done
    echo ""
    case "$STATUS" in
        success) echo -e "${GREEN}✓${NC} Release pipeline succeeded" ;;
        created|pending|waiting_for_resource)
            fail "the release pipeline was not picked up by a runner within ${TIMEOUT}s: ${PIPELINE_URL}. Check the runners, then run: PLUMBER_COMPONENT_TOKEN=... ./scripts/component-mirror.sh --gitlab-url ${GITLAB_URL} --group ${GROUP} --publish-only" ;;
        running|preparing)
            fail "the release pipeline is still running after ${TIMEOUT}s: ${PIPELINE_URL}. When it succeeds the version is published; otherwise run again with --publish-only." ;;
        *)
            fail "the release pipeline ended with status '${STATUS}': ${PIPELINE_URL}. Fix the cause (usually the runner cannot pull registry.gitlab.com/gitlab-org/release-cli), then run again with --publish-only." ;;
    esac
    api GET "/projects/${PROJECT_ID}/releases/$(urlenc "$LATEST_TAG")"
    [ "$HTTP_CODE" = "200" ] || fail "the pipeline succeeded but no release exists for ${LATEST_TAG}: ${PIPELINE_URL}"
    is_published || fail "the release exists but the catalog does not list ${LATEST_TAG} yet. Check ${PROJECT_URL} and run again with --publish-only."
fi

echo ""
echo -e "${GREEN}${BOLD}Component published: ${HOST}/${FULL_PATH}/plumber@${LATEST_TAG}${NC}"
echo ""
echo "  In Plumber, as an Admin, set Settings > Component:"
echo -e "    component_path: ${BOLD}${FULL_PATH}${NC}"
echo -e "    component_ref:  ${BOLD}(empty)${NC} to follow the latest version, or ${BOLD}${LATEST_TAG}${NC} to pin it"
echo ""
echo "  Pipelines include it with:"
echo "    include:"
echo "      - component: ${HOST}/${FULL_PATH}/plumber@${LATEST_TAG}"
if [ "$GROUP_VISIBILITY" = "private" ]; then
    echo ""
    echo -e "  ${YELLOW}Note:${NC} ${GROUP} is private: only projects whose pipelines can read ${FULL_PATH} can include it."
fi
echo ""
