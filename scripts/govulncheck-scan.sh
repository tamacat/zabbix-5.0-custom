#!/usr/bin/env bash
# Go vulnerability check (govulncheck) of the Go program in the built images: zabbix_agent2, extracted from the
# agent2 image. scripts/security-scan.sh runs this after its Trivy scans.
#
# Why this exists next to Trivy: Trivy's vulnerability database is rebuilt a few times a day from several
# sources, so advisories published the same day are often missing, and the Go standard library compiled into a
# binary is where they land first. govulncheck reads the Go vulnerability database (vuln.go.dev) directly. On
# 2026-10-08 it found 12 advisories in the agent2 binary that Trivy still reported as clean.
#
# It runs in binary mode: it lists vulnerabilities whose vulnerable symbols are present in the binary. That mode
# cannot tell whether the code is actually called (source mode can, but needs the whole build tree), so it errs
# on the safe side.
#
# Policy: FAIL when at least one finding has a published fix — the fix is then a bump away (a newer `toolchain`
# line or module version in sources/zabbix-5.0.47/src/go/go.mod, then a rebuild). Findings with no fix yet are
# printed as warnings and do not fail: there is nothing to bump.
#
# Needs `govulncheck` on PATH (go install golang.org/x/vuln/cmd/govulncheck@latest) and network access to
# vuln.go.dev. Without it the check is skipped with a notice, unless REQUIRE_GOVULNCHECK=1 (GitHub Actions sets it).
#
#   CONTAINER_ENGINE=podman   # "docker" on GitHub Actions
#   AGENT2_IMAGE=...          # image to check; default localhost/zabbix-agent2-php8migration:<ZABBIX_IMAGE_TAG>
#   REQUIRE_GOVULNCHECK=1     # a missing govulncheck is an error instead of a skip
#
# Exit status: 0 = clean (or skipped), 1 = fixable vulnerabilities, or the check could not be completed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# .env supplies defaults only: anything already exported by the caller wins over it.
if [ -f .env ]; then
  _caller_env="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  eval "${_caller_env}"
fi

ENGINE="${CONTAINER_ENGINE:-podman}"
TAG="${ZABBIX_IMAGE_TAG:-5.0.47-custom}"
IMAGE="${AGENT2_IMAGE:-localhost/zabbix-agent2-php8migration:${TAG}}"
BINARY_PATH=/usr/sbin/zabbix_agent2

fail() {
  echo "!! $1" >&2
  exit 1
}

if ! command -v govulncheck >/dev/null 2>&1; then
  if [ "${REQUIRE_GOVULNCHECK:-0}" = "1" ]; then
    fail "govulncheck is required (REQUIRE_GOVULNCHECK=1) but is not on PATH"
  fi
  echo "govulncheck is not installed: skipping the Go vulnerability check."
  echo "  install it with: go install golang.org/x/vuln/cmd/govulncheck@latest   (REQUIRE_GOVULNCHECK=1 turns this into an error)"
  exit 0
fi

if python3 -c "import sys" >/dev/null 2>&1; then
  PY=python3
elif python -c "import sys" >/dev/null 2>&1; then
  PY=python
else
  fail "no working python3/python found (needed to read govulncheck's JSON report)"
fi

if ! "${ENGINE}" image inspect "${IMAGE}" >/dev/null 2>&1; then
  fail "image not found locally: ${IMAGE} (build it first: ${ENGINE} compose build zabbix-agent2)"
fi

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT

echo "Go vulnerability check (govulncheck, binary mode): ${BINARY_PATH} from ${IMAGE}"
# Streamed through stdout so it works the same with a remote Podman machine, where `cp` into a host path does not.
MSYS_NO_PATHCONV=1 "${ENGINE}" run --rm --entrypoint cat "${IMAGE}" "${BINARY_PATH}" > "${work}/zabbix_agent2" \
  || fail "could not read ${BINARY_PATH} out of ${IMAGE}"
[ "$(wc -c < "${work}/zabbix_agent2")" -gt 1000000 ] || fail "${BINARY_PATH} from ${IMAGE} is unexpectedly small"

govulncheck -mode=binary -format=json "${work}/zabbix_agent2" > "${work}/report.json" 2> "${work}/govulncheck.err" \
  || fail "govulncheck failed: $(tail -3 "${work}/govulncheck.err" | tr '\n' ' ')"

"${PY}" - "${work}/report.json" <<'PYEOF'
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
messages, pos = [], 0
while True:
    while pos < len(text) and text[pos].isspace():
        pos += 1
    if pos >= len(text):
        break
    message, pos = decoder.raw_decode(text, pos)
    messages.append(message)

config = next((m["config"] for m in messages if "config" in m), None)
if config is None:
    print("!! govulncheck produced no result (no config message in its report)")
    sys.exit(2)

osv = {m["osv"]["id"]: m["osv"] for m in messages if "osv" in m}
findings = {}
for m in messages:
    finding = m.get("finding")
    if not finding:
        continue
    entry = findings.setdefault(finding["osv"], {"fixed": set(), "where": set()})
    trace = (finding.get("trace") or [{}])[0]
    entry["where"].add("%s@%s" % (trace.get("module", "?"), trace.get("version", "?")))
    if finding.get("fixed_version"):
        entry["fixed"].add(finding["fixed_version"])

print("  database: %s, last modified %s; scanner %s" % (
    config.get("db"), config.get("db_last_modified"), config.get("scanner_version")))

fixable = {k: v for k, v in findings.items() if v["fixed"]}
unfixed = {k: v for k, v in findings.items() if not v["fixed"]}


def describe(vuln_id, entry):
    record = osv.get(vuln_id, {})
    aliases = ",".join(record.get("aliases", []))
    summary = (record.get("summary") or "").strip()
    return "%s%s  %s  %s" % (vuln_id, " (%s)" % aliases if aliases else "", ", ".join(sorted(entry["where"])), summary)


for vuln_id, entry in sorted(fixable.items()):
    print("  FIX AVAILABLE  %s\n                 fixed in %s" % (describe(vuln_id, entry), ", ".join(sorted(entry["fixed"]))))
for vuln_id, entry in sorted(unfixed.items()):
    print("  no fix yet     %s" % describe(vuln_id, entry))

if not findings:
    print("  No vulnerabilities found.")
if unfixed:
    print("  %d finding(s) without a published fix: warning only." % len(unfixed))
if fixable:
    print("")
    print("!! %d vulnerabilit%s with a published fix. Raise the `toolchain` line or the module version in" % (
        len(fixable), "y" if len(fixable) == 1 else "ies"))
    print("!! sources/zabbix-5.0.47/src/go/go.mod (go get <module>@<fixed version>), then rebuild the agent2 image.")
    sys.exit(1)
PYEOF
status=$?
case "${status}" in
  0) exit 0 ;;
  1) exit 1 ;;
  *) fail "could not evaluate the govulncheck report" ;;
esac
