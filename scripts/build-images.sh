#!/usr/bin/env bash
# Build & tag the 3 Zabbix images for external distribution (operator request 2026-09-09).
#
# Distinct from scripts/ci-pipeline.sh: that script builds/tags as
# localhost/*-php8migration:${ZABBIX_IMAGE_TAG:-5.0.47-custom} purely for the
# internal CI gate (Test/Package/Scan). This script re-tags those SAME build
# outputs under a public registry namespace and a release-style version tag.
# It never pushes anywhere — see scripts/push-images.sh for that, kept as a
# separate, explicit step.
#
# Naming: <REGISTRY_NAMESPACE>/<component> — mirrors the official image
# naming (zabbix/zabbix-server-mysql, zabbix/zabbix-web-nginx-mysql,
# zabbix/zabbix-agent2), just under your own namespace instead of "zabbix".
# Tag: <zabbix-version>-alpine-b<YYYYMMDD> (build date, UTC). Same tag format
# across all three images, so it deliberately carries no "-php8-" marker —
# only zabbix-web is actually PHP; server (C) and agent2 (Go) aren't.
#
# .env (repo root) is loaded automatically, so ZABBIX_IMAGE_TAG in .env is honored without needing to
# also export it in your shell (unlike `podman compose` itself, this script's .env loading is
# unconditional: a value already exported in your shell for one of these names gets overwritten by
# .env's value, not the other way around — set it in .env if you want it to stick). Override any of
# these via .env or by editing your shell environment after this script's .env load point:
#   REGISTRY_NAMESPACE=tamacat        # Docker Hub namespace / username
#   ZABBIX_VERSION=5.0.47             # must match sources/zabbix-5.0.47/ on disk
#   BUILD_DATE=20260917               # defaults to today (UTC)
#   IMAGE_TAG=5.0.47-alpine-b20260917 # overrides the whole computed tag
#   ZABBIX_IMAGE_TAG=5.0.47-custom    # must match compose.yml's build output tag
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# `podman compose build` reads ZABBIX_IMAGE_TAG (and everything else) straight out of .env on its
# own; this script is a separate process and does NOT inherit .env's values just by living next to
# it, so without this it can end up computing a LOCAL_TAG that never matches what compose actually
# built (whatever .env's ZABBIX_IMAGE_TAG says wins, silently, regardless of this script's default).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-tamacat}"
ZABBIX_VERSION="${ZABBIX_VERSION:-5.0.47}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
IMAGE_TAG="${IMAGE_TAG:-${ZABBIX_VERSION}-alpine-b${BUILD_DATE}}"
LOCAL_TAG="${ZABBIX_IMAGE_TAG:-5.0.47-custom}"

echo "=================================================================="
echo "Building images (podman compose build) — local tag: ${LOCAL_TAG}"
echo "=================================================================="
podman compose build

# component key -> "<local image name>:<destination image name>"
COMPONENTS=(
  "zabbix-server-mysql-php8migration:zabbix-server-mysql"
  "zabbix-web-nginx-mysql-php8migration:zabbix-web-nginx-mysql"
  "zabbix-agent2-php8migration:zabbix-agent2"
)

TAG_FILE="scripts/.last-image-tag"
: > "${TAG_FILE}"

echo ""
echo "=================================================================="
echo "Tagging for ${REGISTRY_NAMESPACE} — release tag: ${IMAGE_TAG}"
echo "=================================================================="
for pair in "${COMPONENTS[@]}"; do
  src_name="${pair%%:*}"
  dst_name="${pair#*:}"
  src="localhost/${src_name}:${LOCAL_TAG}"
  dst="${REGISTRY_NAMESPACE}/${dst_name}:${IMAGE_TAG}"
  echo "  ${src}"
  echo "    -> ${dst}"
  podman tag "${src}" "${dst}"
  echo "${dst}" >> "${TAG_FILE}"
done

echo ""
echo "Tagged images (recorded in ${TAG_FILE} for scripts/push-images.sh):"
cat "${TAG_FILE}"
echo ""
echo "Next: run 'podman login docker.io' (once), then scripts/push-images.sh"
echo "to push these exact tags."
