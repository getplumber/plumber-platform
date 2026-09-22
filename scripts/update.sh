#!/bin/bash

# Plumber Update Script
# Updates your self-managed Plumber Platform to the release pinned in the compose files.
#
# Usage:
#   ./scripts/update.sh [--component]
#
# This script:
#   1. Stops running containers (using the current compose config)
#   2. Pulls the latest changes from the git repository (the image tags live in
#      compose.yml and compose.local.yml, so the pull is the version bump)
#   3. Rebuilds the custom CA bundle if you use one
#   4. Starts containers with the new images (the backend migrates the database on boot)
#   5. With --component: refreshes the local copy of the Plumber CI/CD component
#      (PLUMBER_COMPONENT_PROJECT in .env) and publishes its latest version to your
#      CI/CD catalog. Asks for a GitLab token (Owner of the group, api scope), used
#      for this run only.
#
# Upgrades are sequential and additive: rolling back is checking out the previous
# release tag (git checkout vX.Y.Z) and starting again. Never downgrade the database by hand.

set -euo pipefail

UPDATE_COMPONENT=false
for arg in "$@"; do
    case "$arg" in
        --component) UPDATE_COMPONENT=true ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)"; exit 2 ;;
    esac
done

RED='\033[0;31m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

if [ ! -f compose.yml ] || [ ! -f scripts/preflight.sh ]; then
    echo -e "${RED}Error:${NC} This script must be run from the Plumber platform repository root."
    exit 1
fi
if [ ! -f .env ]; then
    echo -e "${RED}Error:${NC} .env file not found. Run ./install.sh first."
    exit 1
fi

if grep -q "^DOMAIN_NAME=" .env 2>/dev/null; then
    DEPLOY_TYPE="production"
    COMPOSE_CMD="docker compose"
else
    DEPLOY_TYPE="local"
    COMPOSE_CMD="docker compose -f compose.local.yml"
fi

echo ""
echo -e "${BOLD}Updating Plumber (${DEPLOY_TYPE})...${NC}"
echo "───────────────────────────────────────"

echo ""
echo "Stopping containers..."
$COMPOSE_CMD down --remove-orphans
echo -e "${GREEN}✓${NC} Containers stopped"

echo ""
echo "Pulling latest changes..."
git pull
echo -e "${GREEN}✓${NC} Repository updated"

PINNED_VERSION=$(sed -n 's|^ *image: docker.io/getplumber/platform-backend:\(v[0-9][0-9.]*\)$|\1|p' compose.yml | head -n 1)
if [ -z "${PINNED_VERSION}" ]; then
    echo -e "${RED}Error:${NC} compose.yml does not pin the platform-backend image to a release tag."
    exit 1
fi
echo -e "${GREEN}✓${NC} Platform: ${PINNED_VERSION}"

# Installs made before the tags moved into the compose files carry a PLATFORM_VERSION
# line in .env; it is not read any more, drop it so nobody edits it expecting a rollback.
if grep -q '^PLATFORM_VERSION=' .env 2>/dev/null; then
    sed -i."" -e '/^# Image version (managed by versions.env, synced by scripts\/update.sh)$/d' -e '/^PLATFORM_VERSION=/d' .env
    rm -f .env."" 2>/dev/null || true
    echo -e "${GREEN}✓${NC} Removed the obsolete PLATFORM_VERSION line from .env (the tags are pinned in compose.yml)"
fi

echo ""
bash scripts/ca-bundle.sh

echo ""
echo "Starting containers..."
$COMPOSE_CMD up -d

echo ""
echo -e "${GREEN}✓ Plumber has been updated to ${PINNED_VERSION}!${NC}"
echo ""

if [ "$UPDATE_COMPONENT" = true ]; then
    COMPONENT_PROJECT=$(sed -n "s/^PLUMBER_COMPONENT_PROJECT=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" .env | head -n 1)
    GITLAB_URL_ENV=$(sed -n "s/^GITLAB_URL=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}$/\1/p" .env | head -n 1)
    if [ -z "$COMPONENT_PROJECT" ] || [ -z "$GITLAB_URL_ENV" ]; then
        echo -e "${RED}Error:${NC} .env has no PLUMBER_COMPONENT_PROJECT (or GITLAB_URL). Run the copy once by hand:"
        echo "  PLUMBER_COMPONENT_TOKEN=... ./scripts/component-mirror.sh --gitlab-url <gitlab url> --group <group>"
        exit 1
    fi
    COMPONENT_GROUP="${COMPONENT_PROJECT%/*}"
    COMPONENT_NAME="${COMPONENT_PROJECT##*/}"
    echo -e "${BOLD}Refreshing the CI/CD component copy ${COMPONENT_PROJECT}...${NC}"
    if [ -z "${PLUMBER_COMPONENT_TOKEN:-}" ]; then
        read -rs -p "GitLab token (Owner of ${COMPONENT_GROUP}, api scope, used for this run only): " PLUMBER_COMPONENT_TOKEN < /dev/tty
        echo ""
        export PLUMBER_COMPONENT_TOKEN
    fi
    bash scripts/component-mirror.sh --gitlab-url "$GITLAB_URL_ENV" --group "$COMPONENT_GROUP" --project "$COMPONENT_NAME"
    unset PLUMBER_COMPONENT_TOKEN
fi
