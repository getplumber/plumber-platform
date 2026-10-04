#!/bin/bash

# Plumber Installer
# Interactive setup wizard for self-managed Plumber instances.
#
# Usage:
#   # Option A: One-liner (clones the repo automatically)
#   curl -fsSL https://raw.githubusercontent.com/getplumber/plumber-platform/main/install.sh | bash
#
#   # Option B: From a cloned repository
#   git clone https://github.com/getplumber/plumber-platform.git plumber-platform
#   cd plumber-platform
#   ./install.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

REPO_URL="https://github.com/getplumber/plumber-platform.git"
RAW_INSTALL_URL="https://raw.githubusercontent.com/getplumber/plumber-platform/main/install.sh"
# PLUMBER_DIR lets an operator put the checkout somewhere else, which is the
# way out when the default name is already taken (see the guard below).
REPO_DIR="${PLUMBER_DIR:-plumber-platform}"

# =============================================================================
# Helpers
# =============================================================================

prompt() {
    local VARNAME="$1"
    local MESSAGE="$2"
    local DEFAULT="${3:-}"
    local VALUE=""

    while true; do
        if [ -n "$DEFAULT" ]; then
            echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(${DEFAULT})${NC}: "
        else
            echo -ne "${BOLD}${MESSAGE}${NC}: "
        fi
        read -r VALUE < /dev/tty
        VALUE="${VALUE:-$DEFAULT}"

        if [ -n "$VALUE" ]; then
            printf -v "$VARNAME" '%s' "$VALUE"
            return
        fi
        echo -e "${RED}  This field is required.${NC}"
    done
}

prompt_secret() {
    local VARNAME="$1"
    local MESSAGE="$2"
    local VALUE=""
    local CHAR=""

    while true; do
        VALUE=""
        echo -ne "${BOLD}${MESSAGE}${NC}: "
        stty -echo < /dev/tty 2>/dev/null || true
        while IFS= read -r -n1 CHAR < /dev/tty; do
            if [[ -z "$CHAR" ]]; then
                break
            elif [[ "$CHAR" == $'\x7f' ]] || [[ "$CHAR" == $'\b' ]]; then
                if [ -n "$VALUE" ]; then
                    VALUE="${VALUE%?}"
                    echo -ne "\b \b"
                fi
            else
                VALUE+="$CHAR"
                echo -ne "*"
            fi
        done
        stty echo < /dev/tty 2>/dev/null || true
        echo ""

        if [ -n "$VALUE" ]; then
            printf -v "$VARNAME" '%s' "$VALUE"
            return
        fi
        echo -e "${RED}  This field is required.${NC}"
    done
}

prompt_secret_optional() {
    local VARNAME="$1"
    local MESSAGE="$2"
    local VALUE=""
    local CHAR=""

    echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(leave empty to skip)${NC}: "
    stty -echo < /dev/tty 2>/dev/null || true
    while IFS= read -r -n1 CHAR < /dev/tty; do
        if [[ -z "$CHAR" ]]; then
            break
        elif [[ "$CHAR" == $'\x7f' ]] || [[ "$CHAR" == $'\b' ]]; then
            if [ -n "$VALUE" ]; then
                VALUE="${VALUE%?}"
                echo -ne "\b \b"
            fi
        else
            VALUE+="$CHAR"
            echo -ne "*"
        fi
    done
    stty echo < /dev/tty 2>/dev/null || true
    echo ""
    printf -v "$VARNAME" '%s' "$VALUE"
}

prompt_optional() {
    local VARNAME="$1"
    local MESSAGE="$2"
    local DEFAULT="${3:-}"

    if [ -n "$DEFAULT" ]; then
        echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(${DEFAULT})${NC}: "
    else
        echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(leave empty to skip)${NC}: "
    fi
    read -r VALUE < /dev/tty
    VALUE="${VALUE:-$DEFAULT}"
    printf -v "$VARNAME" '%s' "$VALUE"
}

env_line() {
    printf "%s='%s'\n" "$1" "$2"
}

prompt_choice() {
    local VARNAME="$1"
    local MESSAGE="$2"
    shift 2
    local OPTIONS=("$@")
    local NUM_OPTIONS=${#OPTIONS[@]}

    echo -e "${BOLD}${MESSAGE}${NC}"
    for i in "${!OPTIONS[@]}"; do
        echo "  $((i + 1)). ${OPTIONS[$i]}"
    done

    while true; do
        echo -ne "${BOLD}Choice${NC} ${DIM}(1-${NUM_OPTIONS})${NC}: "
        read -r CHOICE < /dev/tty
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "$NUM_OPTIONS" ]; then
            printf -v "$VARNAME" '%s' "$CHOICE"
            return
        fi
        echo -e "${RED}  Please enter a number between 1 and ${NUM_OPTIONS}.${NC}"
    done
}

prompt_confirm() {
    local MESSAGE="$1"
    local DEFAULT="${2:-Y}"

    if [ "$DEFAULT" = "Y" ]; then
        echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(Y/n)${NC}: "
    else
        echo -ne "${BOLD}${MESSAGE}${NC} ${DIM}(y/N)${NC}: "
    fi
    read -r REPLY < /dev/tty
    REPLY="${REPLY:-$DEFAULT}"

    case "$REPLY" in
        [yY][eE][sS]|[yY]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# Step 1: Detect context and clone if needed
# =============================================================================

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Plumber Installer            ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

if [ ! -f compose.yml ] || [ ! -f scripts/preflight.sh ]; then
    echo "Plumber repository not detected. Cloning..."
    echo ""

    # Check git is available
    if ! command -v git &> /dev/null; then
        echo -e "${RED}Error:${NC} Git is required but not installed."
        echo "  Install it: https://git-scm.com/downloads"
        exit 1
    fi

    # Check docker is available
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error:${NC} Docker is required but not installed."
        echo "  Install it: https://docs.docker.com/get-docker/"
        exit 1
    fi

    if [ -d "$REPO_DIR" ]; then
        # Never pull into a directory that is not this repository.
        #
        # The v1 installer (github.com/getplumber/platform) clones into a
        # directory with this same name, so on any host that still runs v1 the
        # default target is already the LIVE v1 checkout. Pulling there would
        # move a running v1 to a different commit, changing its compose file
        # and image tags under it, and v2 would never be installed at all.
        existing_remote="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
        case "$(printf '%s' "${existing_remote%.git}" | tr '[:upper:]' '[:lower:]')" in
            *getplumber/plumber-platform)
                : # this repository, safe to update
                ;;
            *)
                echo -e "${RED}Error:${NC} ${REPO_DIR}/ already exists and is not a checkout of this repository."
                if [ -n "$existing_remote" ]; then
                    echo "  It is a clone of ${existing_remote}."
                else
                    echo "  It is not a git repository."
                fi
                echo "  Nothing has been changed."
                echo ""
                echo "  Plumber v1 installs into a directory with this same name, so this is most"
                echo "  likely your existing v1. Install v2 beside it, in its own directory:"
                echo ""
                echo "      PLUMBER_DIR=plumber-v2 bash -c \"\$(curl -fsSL ${RAW_INSTALL_URL})\""
                echo ""
                exit 1
                ;;
        esac
        echo "Directory ${REPO_DIR} already exists, updating..."
        cd "$REPO_DIR"
        git pull --ff-only || true
    else
        git clone "$REPO_URL" "$REPO_DIR"
        cd "$REPO_DIR"
    fi
    echo ""
    echo -e "${GREEN}✓${NC} Repository ready at $(pwd)"
    echo ""
fi

if [ -f .env ]; then
    echo -e "${RED}Error:${NC} .env already exists in $(pwd)."
    echo "  It holds PLUMBER_TOKEN_ENCRYPTION_KEY, which seals every stored GitLab secret and cannot be regenerated"
    echo "  without losing them. To upgrade this install run ./scripts/update.sh; to start over, move .env away first."
    echo "  To install a SECOND, separate instance (for example v2 beside v1), give it its own directory:"
    echo "      PLUMBER_DIR=plumber-v2 bash -c \"\$(curl -fsSL ${RAW_INSTALL_URL})\""
    exit 1
fi

# =============================================================================
# Step 1a: Choose deployment type
# =============================================================================
#
# Asked here, before the guards below, because it decides WHICH compose file
# this run will use and therefore which Compose project and which volumes it
# would touch: compose.yml is project "plumber", compose.local.yml is
# "plumber-local". The guards used to run first and always test "plumber", so a
# local install on a host with a production Plumber was refused over a project
# and a volume it was never going to touch, and the volume guard told the
# operator to delete the production database to get past it.

prompt_choice DEPLOY_TYPE "Deployment type:" \
    "Production (domain, TLS, reverse proxy)" \
    "Local (localhost, no TLS)"
echo ""

if [ "$DEPLOY_TYPE" = "2" ]; then
    COMPOSE_CMD="docker compose -f compose.local.yml"
    COMPOSE_FILE="compose.local.yml"
else
    COMPOSE_CMD="docker compose"
    COMPOSE_FILE="compose.yml"
fi

# =============================================================================
# Step 1b: Refuse to adopt another Plumber's Compose project
# =============================================================================
#
# compose.yml declares `name: "plumber"`, and so does the v1 compose file
# (github.com/getplumber/platform). Docker Compose keys everything off that
# project name, not off the directory, so running `up` here while v1 exists
# does not create a second stack: it ADOPTS v1's. Observed on a v1 host, from
# a checkout in its own directory:
#
#   docker compose ls
#   NAME     CONFIG FILES
#   plumber  /root/plumber-v2/compose.yml,/root/plumber-platform/compose.yml
#
# v1's backend and frontend containers were replaced with v2 images and its
# postgres container was recreated with v2's credentials on v1's data volume
# (plumber_postgres-data). Nothing was lost only because postgres skips initdb
# on a non-empty data directory, so v2's role did not exist and its backend
# crash-looped on authentication. With a matching password, or a v1 whose
# database user happens to be `plumber`, v2's migrations would have run against
# the live v1 database.
#
# So: if this project name already has containers from another directory, stop.
PROJECT_NAME="$(sed -n 's/^name:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$COMPOSE_FILE" | head -n 1)"
if [ -n "$PROJECT_NAME" ]; then
    # The working directory recorded on each container of that project. Exact,
    # and needs nothing but docker.
    # `|| true` on the whole pipeline, not decoration: grep exits 1 when it
    # filters everything out, which is the NORMAL case on a host with no
    # Plumber yet, and `set -e` would abort the installer before its first
    # prompt. Found by installing on a freshly cleaned host.
    OTHER_DIRS="$(docker ps -a \
        --filter "label=com.docker.compose.project=${PROJECT_NAME}" \
        --format '{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null \
        | grep -v "^$(pwd)$" | grep -v '^$' | sort -u || true)"
    if [ -n "$OTHER_DIRS" ]; then
        echo -e "${RED}Error:${NC} the Compose project \"${PROJECT_NAME}\" already exists on this host, from:"
        echo "$OTHER_DIRS" | sed 's/^/      /'
        echo "  Nothing has been changed."
        echo ""
        echo "  Plumber v1 uses this same project name, so starting here would take over that"
        echo "  stack and its data volume rather than install a second one. Docker Compose"
        echo "  identifies a stack by its project name, not by its directory."
        echo ""
        echo "  Install v2 on a different host. Keep v1 where it is until you have migrated"
        echo "  (see the migration guide), then retire it."
        echo ""
        exit 1
    fi
fi

# =============================================================================
# Step 1c: Refuse to start on another Plumber's database volume
# =============================================================================
#
# Step 1b keys off CONTAINERS, and `docker compose down` removes those while
# keeping the volumes. So on a host that ran v1, after a perfectly ordinary
# `docker compose down`, step 1b passes and nothing stands between v2 and
# v1's database: compose would reuse the existing `plumber_postgres-data`,
# postgres skips initdb on a non-empty data directory, v2's role is never
# created, and the backend crash-loops on authentication with no hint as to
# why. That is the same failure step 1b describes, reached by the path a
# migrating customer actually takes (migration guide, step 2, option B).
#
# install.sh only ever means a FRESH install: it has already refused above if
# this directory has an .env, and an existing install is upgraded with
# scripts/update.sh instead. So there is no case where a database volume for
# this project should already exist, and we can refuse without ambiguity.
#
# Removing it is deliberately NOT offered here: deleting a database is the
# operator's decision, taken with a backup in hand, never an installer's.
if [ -n "$PROJECT_NAME" ]; then
    DB_VOLUME="${PROJECT_NAME}_postgres-data"
    if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qx "$DB_VOLUME"; then
        echo -e "${RED}Error:${NC} the Docker volume \"${DB_VOLUME}\" already exists on this host."
        echo "  Nothing has been changed."
        echo ""
        echo "  This is a fresh install, so it would start on a database it did not create."
        echo "  Plumber v1 uses this same volume name: if you have just stopped a v1 here,"
        echo "  that volume still holds its database, and postgres does not re-initialise a"
        echo "  data directory that already has one. v2 would come up unable to log into it."
        echo ""
        echo "  If you still need what is in it, back it up and keep the dump off this host:"
        echo ""
        echo "      docker run --rm -v ${DB_VOLUME}:/v -v \"\$PWD\":/out alpine \\"
        echo "          tar czf /out/plumber-db-volume.tgz -C /v ."
        echo ""
        echo "  Then remove it and run this installer again:"
        echo ""
        echo "      docker volume rm ${DB_VOLUME}"
        echo ""
        echo "  Migrating from v1? Follow the migration guide: export your v1 configuration"
        echo "  BEFORE removing this volume, or it goes with it."
        echo ""
        exit 1
    fi
fi

# =============================================================================
# Step 3: Run pre-config checks
# =============================================================================

echo "Running pre-flight checks..."
if [ "$DEPLOY_TYPE" = "2" ]; then
    PREFLIGHT_FLAGS="--pre --local"
else
    PREFLIGHT_FLAGS="--pre"
fi
if ! bash scripts/preflight.sh $PREFLIGHT_FLAGS; then
    echo ""
    echo -e "${RED}Pre-flight checks failed. Please fix the issues above and try again.${NC}"
    exit 1
fi

# =============================================================================
# Step 4: Interactive configuration
# =============================================================================

echo ""
echo -e "${BOLD}Configuration${NC}"
echo "───────────────────────────────────────"
echo ""

# Domain name (production only)
if [ "$DEPLOY_TYPE" = "1" ]; then
    prompt DOMAIN_NAME "Plumber domain name (e.g. plumber.example.com)"

    # Check DNS resolution
    DNS_OK=false
    if command -v dig &> /dev/null; then
        if dig +short "$DOMAIN_NAME" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            DNS_OK=true
        fi
    elif command -v nslookup &> /dev/null; then
        if nslookup "$DOMAIN_NAME" &> /dev/null; then
            DNS_OK=true
        fi
    fi

    if [ "$DNS_OK" = true ]; then
        echo -e "${GREEN}✓${NC} DNS resolves for ${DOMAIN_NAME}"
    else
        echo -e "${RED}!${NC} DNS does not resolve for ${DOMAIN_NAME}"
        echo -e "${DIM}  Create a DNS A record pointing ${DOMAIN_NAME} to your server's public IP.${NC}"
        echo -e "${DIM}  You can continue the setup and configure DNS before starting Plumber.${NC}"
    fi
    echo ""
fi

# GitLab URL
prompt GITLAB_URL "GitLab instance URL (e.g. https://gitlab.example.com)"
GITLAB_URL="${GITLAB_URL%/}"
if [[ ! "$GITLAB_URL" =~ ^https?:// ]]; then
    GITLAB_URL="https://${GITLAB_URL}"
fi

# Connection scope
echo ""
prompt_choice SCOPE_CHOICE "Connection scope:" \
    "Whole GitLab instance (OAuth application created by an instance Admin)" \
    "One root group (OAuth application created in that group)"
if [ "$SCOPE_CHOICE" = "2" ]; then
    PLUMBER_SCOPE="group"
    echo -e "${DIM}Use the exact group path as GitLab shows it (the 'full_path', e.g. my-company).${NC}"
    prompt ROOT_GROUP "Root group path"
    ROOT_GROUP="${ROOT_GROUP#/}"
    ROOT_GROUP="${ROOT_GROUP%/}"
else
    PLUMBER_SCOPE="instance"
    ROOT_GROUP=""
fi

# GitLab OIDC
echo ""
echo "───────────────────────────────────────"
echo -e "${BOLD}GitLab OIDC Application${NC}"
echo ""

if [ "$PLUMBER_SCOPE" = "group" ]; then
    GITLAB_APP_URL="${GITLAB_URL}/groups/${ROOT_GROUP}/-/settings/applications"
else
    GITLAB_APP_URL="${GITLAB_URL}/admin/applications"
fi

if [ "$DEPLOY_TYPE" = "1" ]; then
    PLUMBER_URL="https://${DOMAIN_NAME}"
else
    PLUMBER_URL="http://localhost:3000"
fi
REDIRECT_URI="${PLUMBER_URL}/api/v1/auth/callback"

echo "  1. Open this link to create a new application:"
echo ""
echo -e "     ${BOLD}${GITLAB_APP_URL}${NC}"
echo ""
echo "  2. Fill in the following:"
echo -e "     - Name:         ${BOLD}Plumber${NC}"
echo -e "     - Redirect URI: ${BOLD}${REDIRECT_URI}${NC}"
echo -e "     - Confidential: ${BOLD}yes${NC} (keep the box checked)"
echo -e "     - Scopes:       ${BOLD}api${NC}"
echo ""
echo "  3. Click Save and copy the credentials below"
echo ""

prompt GITLAB_OAUTH2_CLIENT_ID "Application ID"
prompt_secret GITLAB_OAUTH2_CLIENT_SECRET "Secret"

# The GitLab access token is not part of the install: an Admin sets it in Settings.

# CI/CD component copy (optional): a project in the customer's GitLab that mirrors
# gitlab.com/getplumber/plumber and publishes its latest version to the CI/CD catalog.
# The token is used by scripts/component-mirror.sh for this run only, never stored.
COMPONENT_REQUESTED=false
COMPONENT_GROUP=""
echo ""
echo "───────────────────────────────────────"
echo -e "${BOLD}Plumber CI/CD component${NC} ${DIM}(optional)${NC}"
echo ""
echo -e "${DIM}Pipelines include the Plumber component from gitlab.com/getplumber/plumber. If your GitLab${NC}"
echo -e "${DIM}cannot reach gitlab.com, or you prefer a local copy, the installer can copy it into a project${NC}"
echo -e "${DIM}of your instance and publish it to your CI/CD catalog. This needs:${NC}"
echo -e "${DIM}  - a token with the 'api' scope from an Owner of the target group (or an instance Admin),${NC}"
echo -e "${DIM}    used for this run only${NC}"
echo -e "${DIM}  - a runner available to the new project, able to pull registry.gitlab.com/gitlab-org/release-cli${NC}"
if prompt_confirm "Copy the Plumber component into your GitLab and publish it?" "N"; then
    COMPONENT_REQUESTED=true
    prompt COMPONENT_GROUP "Group that receives the 'plumber' project (full path)" "${ROOT_GROUP}"
    COMPONENT_GROUP="${COMPONENT_GROUP#/}"
    COMPONENT_GROUP="${COMPONENT_GROUP%/}"
    prompt_secret PLUMBER_COMPONENT_TOKEN "GitLab token (Owner of ${COMPONENT_GROUP}, api scope)"
    export PLUMBER_COMPONENT_TOKEN
fi

# Certificate method & Database (production only)

if [ "$DEPLOY_TYPE" = "1" ]; then
    echo ""
    echo "───────────────────────────────────────"
    prompt_choice CERT_CHOICE "TLS certificate method:" \
        "Let's Encrypt (automatic, server must be reachable from internet)" \
        "Custom certificates (provide your own .pem files)"

    if [ "$CERT_CHOICE" = "1" ]; then
        CERT_PROFILE="letsencrypt"
        CERT_RESOLVER="le"
    else
        CERT_PROFILE="custom-certs"
        CERT_RESOLVER=""
        echo ""
        echo -e "${DIM}Place your certificate files at:${NC}"
        echo "  .docker/traefik/certs/plumber_fullchain.pem"
        echo "  .docker/traefik/certs/plumber_privkey.pem"

        if [ -f .docker/traefik/certs/plumber_fullchain.pem ] && [ -f .docker/traefik/certs/plumber_privkey.pem ]; then
            echo -e "  ${GREEN}✓${NC} Certificate files found"
        else
            echo -e "  ${YELLOW}!${NC} Certificate files not found yet (add them before starting)"
        fi
    fi

    # Custom CA
    USE_CUSTOM_CA=false
    echo ""
    echo -e "${BOLD}Custom Certificate Authority${NC}"
    echo ""
    echo -e "${DIM}If your GitLab instance or your Plumber certificates are signed by${NC}"
    echo -e "${DIM}a custom Certificate Authority (private CA), Plumber needs the root${NC}"
    echo -e "${DIM}CA certificate to trust those connections.${NC}"
    echo ""

    if prompt_confirm "Are you using a custom CA?" "N"; then
        USE_CUSTOM_CA=true
        echo ""
        echo "  Add your root CA certificate file (.pem or .crt) to:"
        echo ""
        echo -e "     ${BOLD}.docker/ca-certificates/${NC}"
        echo ""

        mkdir -p .docker/ca-certificates

        CA_FILES=$(find .docker/ca-certificates -maxdepth 1 -type f \( -name "*.pem" -o -name "*.crt" \) 2>/dev/null | wc -l | tr -d ' ')
        if [ "$CA_FILES" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC} Found ${CA_FILES} CA certificate(s) in .docker/ca-certificates/"
        else
            echo -e "  ${YELLOW}!${NC} No CA certificates found yet (add them before starting)"
        fi
    fi

    # Database
    echo ""
    echo "───────────────────────────────────────"
    prompt_choice DB_CHOICE "Database:" \
        "Internal (managed PostgreSQL container)" \
        "External (connect to your own PostgreSQL)"

    if [ "$DB_CHOICE" = "1" ]; then
        DB_PROFILE=",internal-db"
    else
        DB_PROFILE=""
        echo ""
        prompt PLUMBER_DB_HOST "Database host"
        prompt_optional PLUMBER_DB_PORT "Database port" "5432"
        prompt PLUMBER_DB_USER "Database user"
        prompt_optional PLUMBER_DB_NAME "Database name" "plumber"
        prompt_secret PLUMBER_DB_PASSWORD_EXT "Database password"
        echo ""
        echo -e "${DIM}SSL mode options: disable, require, verify-ca, verify-full${NC}"
        prompt_optional PLUMBER_DB_SSLMODE "SSL mode" "disable"

        prompt_optional PLUMBER_DB_TIMEZONE "Timezone" "UTC"

    fi

    COMPOSE_PROFILES="${CERT_PROFILE}${DB_PROFILE}"
fi

# =============================================================================
# Step 5: Generate secrets
# =============================================================================

echo ""
echo "───────────────────────────────────────"
echo "Generating secrets..."

PLUMBER_TOKEN_ENCRYPTION_KEY=$(openssl rand -hex 32)
if [ -z "${PLUMBER_DB_PASSWORD_EXT:-}" ]; then
    PLUMBER_DB_PASSWORD=$(openssl rand -hex 16)
else
    PLUMBER_DB_PASSWORD="${PLUMBER_DB_PASSWORD_EXT}"
fi
PLUMBER_REDIS_PASSWORD=$(openssl rand -hex 16)

echo -e "${GREEN}✓${NC} Secrets generated"
echo -e "${DIM}  PLUMBER_TOKEN_ENCRYPTION_KEY seals every stored GitLab secret. Back up .env: the key cannot be rotated.${NC}"

# =============================================================================
# Step 6: Read the pinned image version (compose.yml)
# =============================================================================

# Both app images are pinned to one release tag in the compose files; a release
# moves them together and `scripts/update.sh` only has to pull the repository.
PINNED_VERSION=$(sed -n 's|^ *image: docker.io/getplumber/platform-backend:\(v[0-9][0-9.]*\)$|\1|p' compose.yml | head -n 1)
if [ -z "${PINNED_VERSION}" ]; then
    echo -e "${RED}Error:${NC} compose.yml does not pin the platform-backend image to a release tag."
    exit 1
fi
echo -e "${GREEN}✓${NC} Platform version: ${PINNED_VERSION}"

# =============================================================================
# Step 7: Write .env
# =============================================================================

write_common_env() {
    echo ""
    echo "# GitLab"
    env_line GITLAB_URL "$GITLAB_URL"
    echo ""
    echo "# Secrets (PLUMBER_TOKEN_ENCRYPTION_KEY cannot be rotated: back this file up)"
    env_line PLUMBER_TOKEN_ENCRYPTION_KEY "$PLUMBER_TOKEN_ENCRYPTION_KEY"
    env_line PLUMBER_DB_PASSWORD "$PLUMBER_DB_PASSWORD"
    env_line PLUMBER_REDIS_PASSWORD "$PLUMBER_REDIS_PASSWORD"
    if [ "$COMPONENT_REQUESTED" = true ]; then
        echo ""
        echo "# Local copy of the Plumber CI/CD component (refresh it with ./scripts/update.sh --component)"
        env_line PLUMBER_COMPONENT_PROJECT "${COMPONENT_GROUP}/plumber"
    fi
}

if [ "$DEPLOY_TYPE" = "2" ]; then
    {
        cat <<'HEADER'
###############################################################################
# Plumber local configuration file                                            #
# Documentation: https://getplumber.io/docs/installation/local-docker-compose #
###############################################################################
HEADER
        write_common_env
    } > .env
else
    {
        cat <<'HEADER'
##########################################################################
# Plumber configuration file                                             #
# Documentation: https://getplumber.io/docs/installation/docker-compose/ #
##########################################################################
HEADER
        echo ""
        echo "# Main configuration"
        env_line DOMAIN_NAME "$DOMAIN_NAME"
        write_common_env
        echo ""
        echo "# Deployment profile"
        env_line COMPOSE_PROFILES "$COMPOSE_PROFILES"
        env_line CERT_RESOLVER "$CERT_RESOLVER"
        if [ "${DB_CHOICE:-}" = "2" ]; then
            echo ""
            echo "# External database configuration"
            env_line PLUMBER_DB_HOST "$PLUMBER_DB_HOST"
            env_line PLUMBER_DB_PORT "$PLUMBER_DB_PORT"
            env_line PLUMBER_DB_USER "$PLUMBER_DB_USER"
            env_line PLUMBER_DB_NAME "$PLUMBER_DB_NAME"
            env_line PLUMBER_DB_SSLMODE "$PLUMBER_DB_SSLMODE"
            env_line PLUMBER_DB_TIMEZONE "$PLUMBER_DB_TIMEZONE"
        fi
    } > .env
fi

echo -e "${GREEN}✓${NC} Configuration written to .env"

if [ "${USE_CUSTOM_CA:-false}" = true ]; then
    bash scripts/ca-bundle.sh
fi

# =============================================================================
# Step 8: Run post-config checks
# =============================================================================

echo ""
echo "Running post-config validation..."
if [ "$DEPLOY_TYPE" = "2" ]; then
    bash scripts/preflight.sh --post --local || true
else
    bash scripts/preflight.sh --post || true
fi

# =============================================================================
# Step 9: Launch
# =============================================================================

echo ""
echo "───────────────────────────────────────"
echo ""

# COMPOSE_CMD, COMPOSE_FILE and PROJECT_NAME were fixed at step 1a, before the
# guards that depend on them.
#
# Read the network off the Compose project name in the file actually in use,
# instead of repeating the literal here. The readiness probe below joins this
# network to reach the backend, and a probe pointed at a network that does not
# exist cannot succeed: every attempt fails, the backend is declared not ready
# whatever it is doing, and bootstrap is skipped. Deriving it keeps the two
# from drifting apart silently.
NETWORK_NAME="${PROJECT_NAME}_intranet"

print_bootstrap_hint() {
    echo ""
    echo "  To configure the GitLab connection later, run from this directory:"
    echo ""
    echo "  read -rs -p \"OAuth application secret: \" PLUMBER_BOOTSTRAP_CLIENT_SECRET; echo; export PLUMBER_BOOTSTRAP_CLIENT_SECRET"
    echo -e "    ${BOLD}${COMPOSE_CMD} exec -T -e PLUMBER_BOOTSTRAP_CLIENT_SECRET \\"
    echo -e "      backend plumber-bootstrap -base-url ${GITLAB_URL} -client-id ${GITLAB_OAUTH2_CLIENT_ID} -scope ${PLUMBER_SCOPE}${ROOT_GROUP:+ -root-group ${ROOT_GROUP}}${NC}"
}

run_bootstrap() {
    echo ""
    echo "Waiting for the backend (first boot runs the database migrations)..."
    local READY=false
    for _ in $(seq 1 60); do
        if docker run --rm --network "$NETWORK_NAME" curlimages/curl:8.11.1 -sf http://backend:8080/readyz > /dev/null 2>&1; then
            READY=true
            break
        fi
        sleep 3
    done
    if [ "$READY" != true ]; then
        echo -e "${RED}!${NC} The backend did not become ready in 3 minutes. Check: ${COMPOSE_CMD} logs backend"
        print_bootstrap_hint
        return 1
    fi
    echo -e "${GREEN}✓${NC} Backend ready"

    echo "Configuring the GitLab connection..."
    export PLUMBER_BOOTSTRAP_CLIENT_SECRET="$GITLAB_OAUTH2_CLIENT_SECRET"
    local -a EXEC_ENV=(-e PLUMBER_BOOTSTRAP_CLIENT_SECRET)
    local -a ARGS=(-base-url "$GITLAB_URL" -client-id "$GITLAB_OAUTH2_CLIENT_ID" -scope "$PLUMBER_SCOPE")
    if [ "$PLUMBER_SCOPE" = "group" ]; then
        ARGS+=(-root-group "$ROOT_GROUP")
    fi
    # shellcheck disable=SC2086
    if $COMPOSE_CMD exec -T "${EXEC_ENV[@]}" backend plumber-bootstrap "${ARGS[@]}"; then
        echo -e "${GREEN}✓${NC} GitLab connection configured"
        unset PLUMBER_BOOTSTRAP_CLIENT_SECRET
    else
        echo -e "${RED}!${NC} Bootstrap failed (see the message above)."
        unset PLUMBER_BOOTSTRAP_CLIENT_SECRET
        print_bootstrap_hint
        return 1
    fi
}

# The component copy runs last so a slow or failing publish never leaves the platform
# half-installed. Its verdict is the installer's: not published means a non-zero exit.
INSTALL_EXIT=0
BOOTSTRAP_FAILED=false
COMPONENT_FAILED=false
run_component_step() {
    [ "$COMPONENT_REQUESTED" = true ] || return 0
    echo ""
    if bash scripts/component-mirror.sh --gitlab-url "$GITLAB_URL" --group "$COMPONENT_GROUP"; then
        return 0
    fi
    INSTALL_EXIT=1
    COMPONENT_FAILED=true
    echo ""
    echo "  To publish it later, run from this directory:"
    echo "  read -rs -p \"GitLab token: \" PLUMBER_COMPONENT_TOKEN; echo; export PLUMBER_COMPONENT_TOKEN"
    echo -e "    ${BOLD}./scripts/component-mirror.sh --gitlab-url ${GITLAB_URL} --group ${COMPONENT_GROUP}${NC}"
    return 1
}

if prompt_confirm "Start Plumber now?"; then
    echo ""
    echo "Starting Plumber..."
    $COMPOSE_CMD up -d
    # Not `|| true`. Without the GitLab connection the instance row stays
    # scope-NULL, every role resolves to none, and NOBODY can sign in: the
    # install is unusable, not imperfect. It used to exit 0 under the green
    # banner, so an operator (or a script) read it as success.
    run_bootstrap || { BOOTSTRAP_FAILED=true; INSTALL_EXIT=1; }
    run_component_step || true
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Plumber is starting!            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Visit: ${BOLD}${PLUMBER_URL}${NC}"
    if [ "$BOOTSTRAP_FAILED" = true ]; then
        echo -e "  ${RED}You cannot sign in yet: the GitLab connection is not configured.${NC}"
    else
        if [ "$PLUMBER_SCOPE" = "group" ]; then
            echo -e "  ${DIM}Sign in with a GitLab account that is at least Maintainer of ${ROOT_GROUP}: it is a Plumber Admin${NC}"
        else
            echo -e "  ${DIM}Sign in with a GitLab instance Admin account: it is a Plumber Admin${NC}"
        fi
        echo -e "  ${DIM}and finishes the setup in Settings (access token, SMTP, licence).${NC}"
    fi
    echo ""
    echo "  Useful commands:"
    echo "    ${COMPOSE_CMD} ps       # Check service status"
    echo "    ${COMPOSE_CMD} logs -f  # View logs"
    echo "    ./scripts/update.sh     # Update to latest version"
    if [ "$COMPONENT_REQUESTED" = true ]; then
        echo "    ./scripts/update.sh --component  # Also refresh the component copy"
    fi
    echo "    ./scripts/backup.sh 18   # Back up the database and .env"
    echo ""
    if [ "$COMPONENT_FAILED" = true ]; then
        echo -e "${RED}The Plumber component is NOT published yet (see above). Plumber itself is running.${NC}"
        echo ""
    fi
    if [ "$BOOTSTRAP_FAILED" = true ]; then
        echo -e "${RED}The GitLab connection is NOT configured, so no one can sign in yet.${NC}"
        echo -e "${RED}Plumber itself is running. Run the command above to finish, then sign in.${NC}"
        echo ""
    fi
else
    run_component_step || true
    echo ""
    echo -e "${GREEN}Configuration complete!${NC}"
    echo ""
    echo "  To start Plumber, run:"
    echo -e "    ${BOLD}${COMPOSE_CMD} up -d${NC}"
    echo ""
    echo -e "  Then visit: ${BOLD}${PLUMBER_URL}${NC}"
    print_bootstrap_hint
    echo ""
    if [ "$COMPONENT_FAILED" = true ]; then
        echo -e "${RED}The Plumber component is NOT published yet (see above).${NC}"
        echo ""
    fi
fi
unset PLUMBER_COMPONENT_TOKEN
exit "$INSTALL_EXIT"
