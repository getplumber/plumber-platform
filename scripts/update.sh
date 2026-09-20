#!/bin/bash

# Plumber Update Script
# Updates your self-managed Plumber Platform to the release pinned in the compose files.
#
# Usage:
#   ./scripts/update.sh
#
# This script:
#   1. Stops running containers (using the current compose config)
#   2. Pulls the latest changes from the git repository (the image tags live in
#      compose.yml and compose.local.yml, so the pull is the version bump)
#   3. Rebuilds the custom CA bundle if you use one
#   4. Starts containers with the new images (the backend migrates the database on boot)
#
# Upgrades are sequential and additive: rolling back is checking out the previous
# release tag (git checkout vX.Y.Z) and starting again. Never downgrade the database by hand.

set -euo pipefail

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
