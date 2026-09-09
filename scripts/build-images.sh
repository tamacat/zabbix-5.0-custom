#!/usr/bin/env bash
# Build & tag the 3 Zabbix images for external distribution (operator request 2026-09-09).
#
# Distinct from scripts/ci-pipeline.sh: that script builds/tags as
# localhost/*-php8migration:${ZABBIX_IMAGE_TAG:-5.0.47-php8} purely for the
# internal CI gate (Test/Package/Scan). This script re-tags those SAME build
# outputs under a public registry namespace and a release-style version tag.
# It never pushes anywhere — see scripts/push-images.sh for that, kept as a
# separate, explicit step.
#
# Naming: <REGISTRY_NAMESPACE>/<component> — mirrors the official image
# naming (zabbix/zabbix-server-mysql, zabbix/zabbix-web-nginx-mysql,
# zabbix/zabbix-agent2), just under your own namespace instead of "zabbix".
# Tag: <zabbix-version>-alpine-php8-b<YYYYMMDD> (build date, UTC).
#
# Override any of these via environment variables:
#   REGISTRY_NAMESPACE=tamacat        # Docker Hub namespace / username
#   ZABBIX_VERSION=5.0.47             # must match sources/zabbix-5.0.47/ on disk
#   BUILD_DATE=20260909               # defaults to today (UTC)
#   IMAGE_TAG=5.0.47-alpine-php8-b20260909   # overrides the whole computed tag
#   ZABBIX_IMAGE_TAG=5.0.47-php8      # must match compose.yml's build output tag
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REGISTRY_NAMESPACE="${REGISTRY_NAMESPACE:-tamacat}"
ZABBIX_VERSION="${ZABBIX_VERSION:-5.0.47}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y%m%d)}"
IMAGE_TAG="${IMAGE_TAG:-${ZABBIX_VERSION}-alpine-php8-b${BUILD_DATE}}"
LOCAL_TAG="${ZABBIX_IMAGE_TAG:-5.0.47-php8}"

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
