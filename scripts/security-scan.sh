#!/usr/bin/env bash
# Vulnerability scan for the 4 built Zabbix images (Trivy) — standalone, so you can run it on its own
# without going through the whole build+test+package cycle in scripts/ci-pipeline.sh (which calls this
# script for its own Scan stage, rather than duplicating this logic).
#
# Run it yourself whenever you become aware of an Alpine/dependency update. GitHub Actions
# (.github/workflows/ci-release.yml) also runs it on every push/PR and on a weekly schedule, and once more
# on the exact images about to be published.
#
# Requires the 4 images to already be built (`podman compose build` / scripts/ci-pipeline.sh) and the
# `trivy` CLI to be installed and on PATH. Set CONTAINER_ENGINE=docker to look for them in Docker.
#
# After the Trivy scans it also runs scripts/govulncheck-scan.sh on the Go binary in the agent2 image: Trivy's
# database lags the Go vulnerability database by hours to a day, and a fixable Go advisory fails this script
# too (see that script for the policy). It is skipped, with a notice, when `govulncheck` is not installed,
# unless REQUIRE_GOVULNCHECK=1 (GitHub Actions sets it).
#
# Exit code 0 = every image passed the blocking gate (CRITICAL == 0 across the board) and the Go check passed.
# Exit code 1 = at least one image has a CRITICAL finding, a Go vulnerability with a published fix was found,
#               OR an image is missing/couldn't be scanned.
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
ENGINE="${CONTAINER_ENGINE:-podman}"
IMAGE_TAG="${ZABBIX_IMAGE_TAG:-5.0.47-custom}"
IMAGES=(
  "localhost/zabbix-server-mysql-php8migration:${IMAGE_TAG}"
  "localhost/zabbix-web-nginx-mysql-php8migration:${IMAGE_TAG}"
  "localhost/zabbix-agent2-php8migration:${IMAGE_TAG}"
  "localhost/zabbix-proxy-sqlite3-php8migration:${IMAGE_TAG}"
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

# Inputs for the GitHub Actions Job Summary (scripts/ci_summary.py). Display-only: every failure here is
# swallowed, so nothing in this function can change the scan result. The workflow's verify job sets
# SCAN_SUMMARY_FILE (per-image counts, written as JSON Lines) and SBOM_DIR (CycloneDX SBOMs, used to show
# what changed since the previous build); anywhere else both are unset and this does nothing.
record_image() {
  local image="$1" verdict="$2" report

  if [ -n "${SCAN_SUMMARY_FILE:-}" ]; then
    report="$(mktemp)"
    if trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --skip-db-update --format json --output "${report}" "${image}" >/dev/null 2>&1; then
      python3 scripts/ci_summary.py record-trivy --input "${report}" --target "${image}" \
        --verdict "${verdict}" --summary-file "${SCAN_SUMMARY_FILE}" || true
    fi
    rm -f "${report}"
  fi

  if [ -n "${SBOM_DIR:-}" ]; then
    mkdir -p "${SBOM_DIR}" || true
    trivy image --format cyclonedx --skip-db-update \
      --output "${SBOM_DIR}/$(echo "${image}" | tr '/:' '__').cyclonedx.json" "${image}" >/dev/null 2>&1 || true
  fi
}

for image in "${IMAGES[@]}"; do
  echo ""
  echo "=================================================================="
  echo "Scanning ${image}"
  echo "=================================================================="

  if ! "${ENGINE}" image inspect "${image}" >/dev/null 2>&1; then
    echo "!! Image not found locally: ${image}"
    echo "!! Build it first: ${ENGINE} compose build   (or scripts/ci-pipeline.sh / scripts/build-images.sh)"
    overall_status=1
    continue
  fi

  echo "--- Full report (informational, all severities) ---"
  trivy image --severity CRITICAL,HIGH,MEDIUM,LOW --skip-db-update "${image}"

  echo "--- Blocking gate (CRITICAL only; see quality-gates.md 'Gate 3') ---"
  gate_verdict=Pass
  if ! trivy image --severity CRITICAL --exit-code 1 --skip-db-update "${image}"; then
    overall_status=1
    gate_verdict=Fail
  fi
  record_image "${image}" "${gate_verdict}"
done

echo ""
echo "=================================================================="
echo "Go vulnerability check (zabbix_agent2)"
echo "=================================================================="
go_verdict=Pass
if ! ./scripts/govulncheck-scan.sh; then
  overall_status=1
  go_verdict=Fail
fi
if [ -n "${SCAN_SUMMARY_FILE:-}" ]; then
  python3 scripts/ci_summary.py record-step --name "govulncheck (zabbix_agent2)" --result "${go_verdict}" \
    --summary-file "${SCAN_SUMMARY_FILE}" || true
fi

echo ""
echo "=================================================================="
if [ "${overall_status}" -eq 0 ]; then
  echo "All images passed: zero CRITICAL findings, no fixable Go vulnerabilities."
else
  echo "FAILED: see above for the image(s) with CRITICAL findings, fixable Go vulnerabilities, or missing images."
  echo "HIGH/MEDIUM/LOW findings do not block by themselves — compare them against the known"
  echo "baseline in aidlc/spaces/default/intents/260905-php8-migration/construction/ci-pipeline/quality-gates.md"
  echo "before treating a new one as acceptable."
fi
echo "=================================================================="

exit "${overall_status}"
