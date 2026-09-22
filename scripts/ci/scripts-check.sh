#!/usr/bin/env bash
# Syntax + shellcheck for every operator script, then behavioral checks for the
# two scripts with logic worth testing without a running stack:
# scripts/ca-bundle.sh and scripts/preflight.sh --post.
set -euo pipefail
cd "$(dirname "$0")/../.."

for f in install.sh scripts/*.sh scripts/ci/*.sh; do
  bash -n "$f"
  shellcheck -S warning "$f"
done
echo "  ok   syntax + shellcheck"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -r compose.yml compose.local.yml .env.example scripts .docker "$WORK/"
cd "$WORK"
KEY=$(printf 'a%.0s' $(seq 64))
cp .env.example .env
sed -i \
  -e 's|^DOMAIN_NAME=.*|DOMAIN_NAME="plumber.example.com"|' \
  -e 's|^GITLAB_URL=.*|GITLAB_URL="https://gitlab.example.com"|' \
  -e "s|^PLUMBER_TOKEN_ENCRYPTION_KEY=.*|PLUMBER_TOKEN_ENCRYPTION_KEY=\"$KEY\"|" \
  -e 's|^PLUMBER_DB_PASSWORD=.*|PLUMBER_DB_PASSWORD="dbpass"|' \
  -e 's|^PLUMBER_REDIS_PASSWORD=.*|PLUMBER_REDIS_PASSWORD="redispass"|' .env

# ca-bundle.sh: no certs -> no bundle, no env line
bash scripts/ca-bundle.sh >/dev/null
[ ! -f .docker/ca-certificates/plumber-ca.bundle ] || { echo "FAIL: bundle created with no certs"; exit 1; }
! grep -q '^PLUMBER_PROVIDER_CA_BUNDLE=' .env || { echo "FAIL: env line set with no certs"; exit 1; }
# two certs -> one bundle with both, env line set
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/k1.key" -out .docker/ca-certificates/one.pem -subj "/CN=one" -days 1 >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/k2.key" -out .docker/ca-certificates/two.crt -subj "/CN=two" -days 1 >/dev/null 2>&1
bash scripts/ca-bundle.sh >/dev/null
[ "$(grep -c 'BEGIN CERTIFICATE' .docker/ca-certificates/plumber-ca.bundle)" = 2 ] || { echo "FAIL: bundle should hold 2 certs"; exit 1; }
grep -q "^PLUMBER_PROVIDER_CA_BUNDLE='/usr/local/share/ca-certificates/plumber-ca.bundle'" .env || { echo "FAIL: env line missing"; exit 1; }
# rerun is idempotent
bash scripts/ca-bundle.sh >/dev/null
[ "$(grep -c '^PLUMBER_PROVIDER_CA_BUNDLE=' .env)" = 1 ] || { echo "FAIL: duplicate env line"; exit 1; }
[ "$(grep -c 'BEGIN CERTIFICATE' .docker/ca-certificates/plumber-ca.bundle)" = 2 ] || { echo "FAIL: bundle appended"; exit 1; }
# certs removed -> bundle and env line removed
rm .docker/ca-certificates/one.pem .docker/ca-certificates/two.crt
bash scripts/ca-bundle.sh >/dev/null
[ ! -f .docker/ca-certificates/plumber-ca.bundle ] || { echo "FAIL: stale bundle kept"; exit 1; }
! grep -q '^PLUMBER_PROVIDER_CA_BUNDLE=' .env || { echo "FAIL: stale env line kept"; exit 1; }
echo "  ok   ca-bundle.sh"

# preflight --post: a good .env passes (network checks skipped)
PLUMBER_PREFLIGHT_OFFLINE=1 bash scripts/preflight.sh --post >/dev/null || { echo "FAIL: preflight should pass a good .env"; exit 1; }
# a 32-hex key must fail
sed -i "s|^PLUMBER_TOKEN_ENCRYPTION_KEY=.*|PLUMBER_TOKEN_ENCRYPTION_KEY=\"$(printf 'a%.0s' $(seq 32))\"|" .env
if PLUMBER_PREFLIGHT_OFFLINE=1 bash scripts/preflight.sh --post >/dev/null; then echo "FAIL: preflight accepted a 32-char key"; exit 1; fi
echo "  ok   preflight.sh --post"

# component-mirror.sh: argument contract and the dry run (no network involved)
OUT=$(bash scripts/component-mirror.sh --dry-run --gitlab-url gitlab.example.com/ --group /acme/) || { echo "FAIL: dry run should exit 0"; exit 1; }
grep -q "Project:       acme/plumber" <<<"$OUT" || { echo "FAIL: dry run should resolve acme/plumber"; echo "$OUT"; exit 1; }
grep -q "GitLab:        https://gitlab.example.com$" <<<"$OUT" || { echo "FAIL: dry run should normalise the GitLab URL"; echo "$OUT"; exit 1; }
grep -q "component_path = acme/plumber" <<<"$OUT" || { echo "FAIL: dry run should print the Settings value"; exit 1; }
if bash scripts/component-mirror.sh --dry-run --gitlab-url https://gitlab.example.com >/dev/null 2>&1; then echo "FAIL: --group is required"; exit 1; fi
if env -u PLUMBER_COMPONENT_TOKEN bash scripts/component-mirror.sh --gitlab-url https://gitlab.example.com --group acme >/dev/null 2>&1; then echo "FAIL: a missing token must fail before any network call"; exit 1; fi
if bash scripts/component-mirror.sh --dry-run --gitlab-url https://gitlab.example.com --group acme --bogus >/dev/null 2>&1; then echo "FAIL: unknown options must be rejected"; exit 1; fi
echo "  ok   component-mirror.sh"
echo "scripts-check: all good"
