#!/usr/bin/env bash
# Check that no newer release of the imported Zabbix series (e.g. 5.0.48) exists upstream.
#
# This project follows upstream Zabbix source releases (git tags) directly instead of waiting for the official
# container images. Trivy cannot judge vulnerabilities in the Zabbix code itself (it is built from source, not
# installed as an Alpine package), so this script is the stand-in that says "upstream fixed something and it
# has not been imported yet" (the same idea as scripts/check-php-version.sh; both run in the weekly CI).
#
# Only final releases (X.Y.Z) count; alpha, beta and rc tags are ignored. An imported version that is newer
# than or equal to the newest tag is up to date.
#
#   ZBX_GIT_URL   git repository to read tags from (default: https://git.zabbix.com/scm/zbx/zabbix.git)
#   ENV_FILE      file holding the imported version (default: .env.example); it is read from
#                 ZABBIX_VERSION=X.Y.Z, or else ZABBIX_IMAGE_TAG=X.Y.Z-<suffix>
#
# Inside GitHub Actions ($GITHUB_STEP_SUMMARY is set) the result table is also appended to the run page.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ZBX_GIT_URL="${ZBX_GIT_URL:-https://git.zabbix.com/scm/zbx/zabbix.git}"
ENV_FILE="${ENV_FILE:-.env.example}"

fail() {
	echo "!! ERROR: $1" >&2
	exit 1
}

# Result table for the run page. Failing to write it never changes the result of the check.
write_summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		{
			echo "## Zabbix 上流バージョンの確認"
			echo ""
			echo "| 系列 | 取り込み済み | 上流の最新 | 結果 |"
			echo "|---|---|---|---|"
			echo "| ${LINE} | ${CURRENT} | ${LATEST} | $1 |"
			echo ""
			if [ -n "${2:-}" ]; then
				echo "$2"
				echo ""
			fi
		} >> "${GITHUB_STEP_SUMMARY}" || true
	fi
}

[ -f "${ENV_FILE}" ] || fail "${ENV_FILE} not found"
RAW="$(sed -n 's/^ZABBIX_VERSION=//p' "${ENV_FILE}" | head -n 1)"
if [ -z "${RAW}" ]; then
	RAW="$(sed -n 's/^ZABBIX_IMAGE_TAG=//p' "${ENV_FILE}" | head -n 1)"
fi
[ -n "${RAW}" ] || fail "no ZABBIX_VERSION= or ZABBIX_IMAGE_TAG= in ${ENV_FILE}"
if ! [[ "${RAW}" =~ ^(([0-9]+\.[0-9]+)\.[0-9]+)($|-) ]]; then
	fail "cannot read an X.Y.Z version from '${RAW}' in ${ENV_FILE}"
fi
CURRENT="${BASH_REMATCH[1]}"
LINE="${BASH_REMATCH[2]}"

# --refs drops the ^{} lines that annotated tags also produce.
TAGS="$(git ls-remote --tags --refs "${ZBX_GIT_URL}" "refs/tags/${LINE}.*" 2>/dev/null)" \
	|| fail "could not fetch the upstream tags (${ZBX_GIT_URL})"
NAMES="$(printf '%s\n' "${TAGS}" | awk '{print $2}' | sed -n 's#^refs/tags/##p' | sort -u)"
[ -n "${NAMES}" ] || fail "upstream has no ${LINE}.* tag at all (${ZBX_GIT_URL}); check the URL"

# Final releases only. grep exits 1 when nothing matches, which must not abort the script silently.
RELEASES="$(printf '%s\n' "${NAMES}" | grep -E "^${LINE//./\\.}\.[0-9]+$" || true)"
[ -n "${RELEASES}" ] || fail "upstream has no final ${LINE}.x release tag (${ZBX_GIT_URL})"
LATEST="$(printf '%s\n' "${RELEASES}" | sort -V | tail -n 1)"

echo "Zabbix ${LINE} series: imported=${CURRENT}  latest upstream=${LATEST}"

if [ "$(printf '%s\n%s\n' "${CURRENT}" "${LATEST}" | sort -V | tail -n 1)" = "${CURRENT}" ]; then
	echo "Zabbix version check: up to date"
	write_summary "✅ 最新です"
	exit 0
fi

echo "Zabbix version check: OUTDATED - ${LATEST} is available upstream. sources/ carries this project's PHP8 patches, so import the new release and re-apply them, then rebuild." >&2
write_summary "❌ 更新があります" "${LATEST} が上流で公開されています。sources/ にはPHP8互換のパッチが入っているため、新しい版を取り込んでパッチを当て直し、再ビルドしてください。"
exit 1
