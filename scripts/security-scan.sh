#!/usr/bin/env bash
# Vulnerability scan for the 3 built Zabbix images (Trivy) — standalone, so you can run it on its own
# without going through the whole build+test+package cycle in scripts/ci-pipeline.sh (which calls this
# script for its own Scan stage, rather than duplicating this logic).
#
# Manual trigger only (ci-pipeline-questions.md Q2): run this yourself whenever you become aware of an
# Alpine/dependency update, or just periodically. There is no automated schedule.
#
# Requires the 3 images to already be built (`podman compose build` / scripts/ci-pipeline.sh) and the
# `trivy` CLI to be installed and on PATH.
#
# Exit code 0 = every image passed the blocking gate (CRITICAL == 0 across the board).
# Exit code 1 = at least one image has a CRITICAL finding, OR an image is missing/couldn't be scanned.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# See scripts/build-images.sh for why this is needed: `podman compose build` reads ZABBIX_IMAGE_TAG
# straight out of .env; a plain shell default here would silently look for the wrong local tag whenever
# .env sets one.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

SKIP_DB_UPDATE="${SKIP_DB_UPDATE:-0}"
IMAGE_TAG="${ZABBIX_IMAGE_TAG:-5.0.47-custom}"
IMAGES=(
  "localhost/zabbix-server-mysql-php8migration:${IMAGE_TAG}"
  "localhost/zabbix-web-nginx-mysql-php8migration:${IMAGE_TAG}"
  "localhost/zabbix-agent2-php8migration:${IMAGE_TAG}"
)

if [ "${SKIP_DB_UPDATE}" != "1" ]; then
  echo "=================================================================="
  echo "Refreshing Trivy's vulnerability database..."
  echo "=================================================================="
  trivy image --download-db-only
else
  echo "Skipping Trivy DB refresh (SKIP_DB_UPDATE=1) — results may miss recently published CVEs."
fi

overall_status=0

for image in "${IMAGES[@]}"; do
  echo ""
  echo "=================================================================="
  echo "Scanning ${image}"
  echo "=================================================================="

  if ! podman image exists "${image}"; then
    echo "!! Image not found locally: ${image}"
    echo "!! Build it first: podman compose build   (or scripts/ci-pipeline.sh / scripts/build-images.sh)"
    overall_status=1
    continue
  fi

  echo "--- Full report (informational, all severities) ---"
  trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --skip-db-update "${image}"

  echo "--- Blocking gate (CRITICAL only; see quality-gates.md 'Gate 3') ---"
  if ! trivy image --severity CRITICAL --exit-code 1 --skip-db-update "${image}"; then
    overall_status=1
  fi
done

echo ""
echo "=================================================================="
if [ "${overall_status}" -eq 0 ]; then
  echo "All images passed: zero CRITICAL findings."
else
  echo "FAILED: see above for the image(s) with CRITICAL findings (or missing images)."
  echo "HIGH/MEDIUM/LOW findings do not block by themselves — compare them against the known"
  echo "baseline in aidlc/spaces/default/intents/260905-php8-migration/construction/ci-pipeline/quality-gates.md"
  echo "before treating a new one as acceptable."
fi
echo "=================================================================="

exit "${overall_status}"
