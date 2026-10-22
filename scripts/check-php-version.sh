#!/usr/bin/env bash
# Check that the PHP version pinned in docker/web/Dockerfile is still the latest release of its series.
#
# The PHP in the web image is built from source, not installed as an Alpine package. Trivy therefore cannot
# judge vulnerabilities in PHP itself, and a forgotten version bump would not fail any scan. This script is
# the stand-in: it fails when php.net lists a newer release of the same series (e.g. 8.3.x). When it does,
# take the new version and its SHA-256 from php.net, set PHP_VERSION and PHP_SHA256 in the Dockerfile, then
# rebuild and run scripts/smoke-test.sh.
#
#   PHP_RELEASES_URL   release information URL (default: https://www.php.net/releases/index.php)
#   DOCKERFILE         Dockerfile to check (default: docker/web/Dockerfile)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOCKERFILE="${DOCKERFILE:-docker/web/Dockerfile}"
RELEASES_URL="${PHP_RELEASES_URL:-https://www.php.net/releases/index.php}"

fail() {
	echo "!! ERROR: $1" >&2
	exit 1
}

if python3 -c "import sys" >/dev/null 2>&1; then
	PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
	PY=python
else
	fail "no working python3/python interpreter found"
fi

[ -f "${DOCKERFILE}" ] || fail "${DOCKERFILE} not found"
PINNED="$(sed -n 's/^ARG PHP_VERSION=\([0-9][0-9.]*\)$/\1/p' "${DOCKERFILE}" | head -n 1)"
[ -n "${PINNED}" ] || fail "no 'ARG PHP_VERSION=X.Y.Z' in ${DOCKERFILE}"
SERIES="${PINNED%.*}"

RESPONSE="$(curl -fsSL "${RELEASES_URL}?json&version=${SERIES}")" \
	|| fail "could not fetch the PHP release information (${RELEASES_URL})"
LATEST="$(printf '%s' "${RESPONSE}" | "${PY}" -c 'import json,sys; print(json.load(sys.stdin)["version"])')" \
	|| fail "could not read the release information (no version for the ${SERIES} series)"

echo "PHP ${SERIES} series: pinned in the Dockerfile=${PINNED}  latest on php.net=${LATEST}"

if [ "${LATEST}" = "${PINNED}" ]; then
	echo "PHP version check: up to date"
	exit 0
fi

# If the pinned version is newer (php.net's data lags), it is not outdated.
if [ "$(printf '%s\n%s\n' "${PINNED}" "${LATEST}" | sort -V | tail -n 1)" = "${PINNED}" ]; then
	echo "PHP version check: up to date (pinned version is newer than the release list)"
	exit 0
fi

echo "PHP version check: OUTDATED - ${LATEST} is available; update PHP_VERSION and PHP_SHA256 in ${DOCKERFILE}" >&2
exit 1
