#!/usr/bin/env bash
# CI Pipeline — Zabbix 5.0 PHP8 migration [construction/ci-pipeline/ci-config.md]
#
# Run this on your feature branch BEFORE squash-merging into `main`
# (ci-pipeline-questions.md Q3: pre-merge, so a broken build never reaches `main`).
# Manual trigger only (Q2): run it yourself before every merge, and again whenever
# you rebuild the base images after an Alpine/dependency update.
#
# Exit code 0 = every gate passed, safe to squash-merge.
# Exit code 1 = a blocking gate failed (Test, or a CRITICAL Trivy finding). Fix and re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

UI_DIR="sources/zabbix-5.0.47/ui"

echo "=================================================================="
echo "Stage 1/4: Build — install the diff-scope PHPUnit toolchain"
echo "=================================================================="
(cd "${UI_DIR}" && composer install --dev)

echo "=================================================================="
echo "Stage 2/4: Test — diff-scope regression suite (blocking gate)"
echo "=================================================================="
(cd "${UI_DIR}" && vendor/bin/phpunit --testsuite unit \
  tests/unit/CScreenProblemBreakpointTest.php \
  tests/unit/TriggersIncDecodeTest.php \
  tests/unit/CFrontendSetupTest.php)
(cd "${UI_DIR}" && vendor/bin/phpunit --testsuite integration \
  tests/integration/AuthenticationConfigTest.php)
# The two DB-backed AuthenticationConfigTest cases auto-skip (markTestSkipped) when no
# reachable MySQL is configured. To exercise them for real before a merge that touches
# authentication, start dev-mysql first and pass its connection details:
#   podman compose --profile dev up -d dev-mysql
#   ZBX_TEST_DB_HOST=<dev-mysql host> ZBX_TEST_DB_PORT=3306 ZBX_TEST_DB_USER=zabbix \
#     ZBX_TEST_DB_PASSWORD=zabbix ZBX_TEST_DB_DATABASE=zabbix \
#     (cd sources/zabbix-5.0.47/ui && vendor/bin/phpunit --testsuite integration \
#       tests/integration/AuthenticationConfigTest.php)

echo "=================================================================="
echo "Stage 3/4: Package — build the 3 images via compose.yml"
echo "=================================================================="
# 'podman compose build' (not a bare 'podman build') so the images come out in Docker
# format with HEALTHCHECK enabled — see build-instructions.md "既知の制約".
podman compose build

echo "=================================================================="
echo "Stage 4/4: Scan — Trivy (blocking gate: CRITICAL only; see quality-gates.md)"
echo "=================================================================="
# Delegates to scripts/security-scan.sh (the standalone scan-only script) so the scanning logic has a
# single source of truth, usable both here and on its own without a full build+test+package cycle.
./scripts/security-scan.sh

echo "=================================================================="
echo "All gates passed. Safe to squash-merge this branch into main."
echo "After merging: podman compose up -d, then run the manual smoke test"
echo "(quality-gates.md 'Deploy / Smoke Test')."
echo "=================================================================="
