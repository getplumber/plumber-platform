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
REPO_DIR="plumber-platform"

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
    echo "  without losing them. To upgrade an existing install run ./scripts/update.sh; to start over, move .env away first."
    exit 1
fi

# =============================================================================
# Step 2: Choose deployment type
# =============================================================================

prompt_choice DEPLOY_TYPE "Deployment type:" \
    "Production (domain, TLS, reverse proxy)" \
    "Local (localhost, no TLS)"
echo ""

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

if [ "$DEPLOY_TYPE" = "2" ]; then
    COMPOSE_CMD="docker compose -f compose.local.yml"
    NETWORK_NAME="plumber-local_intranet"
else
    COMPOSE_CMD="docker compose"
    NETWORK_NAME="plumber_intranet"
fi

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
run_component_step() {
    [ "$COMPONENT_REQUESTED" = true ] || return 0
    echo ""
    if bash scripts/component-mirror.sh --gitlab-url "$GITLAB_URL" --group "$COMPONENT_GROUP"; then
        return 0
    fi
    INSTALL_EXIT=1
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
    run_bootstrap || true
    run_component_step || true
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Plumber is starting!            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Visit: ${BOLD}${PLUMBER_URL}${NC}"
    if [ "$PLUMBER_SCOPE" = "group" ]; then
        echo -e "  ${DIM}Sign in with a GitLab account that is at least Maintainer of ${ROOT_GROUP}: it is a Plumber Admin${NC}"
    else
        echo -e "  ${DIM}Sign in with a GitLab instance Admin account: it is a Plumber Admin${NC}"
    fi
    echo -e "  ${DIM}and finishes the setup in Settings (access token, SMTP, licence).${NC}"
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
    if [ "$INSTALL_EXIT" != 0 ]; then
        echo -e "${RED}The Plumber component is NOT published yet (see above). Plumber itself is running.${NC}"
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
    if [ "$INSTALL_EXIT" != 0 ]; then
        echo -e "${RED}The Plumber component is NOT published yet (see above).${NC}"
        echo ""
    fi
fi
unset PLUMBER_COMPONENT_TOKEN
exit "$INSTALL_EXIT"
