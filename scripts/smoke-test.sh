#!/usr/bin/env bash
# End-to-end smoke test of the 4 built images. Brings the whole stack up against the bundled throwaway
# dev-mysql and checks that:
#   - zabbix-server / zabbix-web / zabbix-agent2 / zabbix-proxy all reach "healthy"
#   - zabbix-server and zabbix-proxy actually finish starting up (main process log line)
#   - the proxy really talks to the server: it is registered through the API, picks up its configuration
#     (after the documented `zabbix_server -R` / `zabbix_proxy -R config_cache_reload`, which must work
#     without -c) and shows a recent lastaccess. "healthy" only means a PID file exists, so by itself it
#     says nothing about the proxy being usable.
#   - the web frontend answers, and the JSON-RPC API can log in and read from the database — this is the
#     path through PHP 8, the frontend code this project migrated, into MySQL
#
# Requires the images to be built already (scripts/ci-pipeline.sh or `<engine> compose build`).
# GitHub Actions runs this right after ci-pipeline.sh (.github/workflows/ci-release.yml).
#
# Always targets dev-mysql — it forces COMPOSE_PROFILES=dev and DB_SERVER_HOST=zabbix-dev-mysql regardless
# of what .env says, so it can never log in to (or write a session row into) a real database.
# The stack is left running afterwards, like `compose up -d`; stop it with `<engine> compose down`.
#
#   CONTAINER_ENGINE=podman        # "docker" on GitHub Actions
#   SMOKE_TEST_TIMEOUT=600         # total seconds to wait for the stack (dev-mysql loads the schema on first start)
#   SMOKE_TEST_USER / SMOKE_TEST_PASSWORD   # frontend login (default: Admin / zabbix, the schema's built-in account —
#                                           # override if you changed it in your local dev-mysql)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# .env supplies defaults only: anything already exported by the caller (ZABBIX_IMAGE_TAG=..., CONTAINER_ENGINE=...)
# wins over it, so a specific build can be tested without editing .env.
if [ -f .env ]; then
  _caller_env="$(export -p)"
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
  eval "${_caller_env}"
fi

ENGINE="${CONTAINER_ENGINE:-podman}"
WEB_PORT="${ZABBIX_WEB_PORT:-8080}"
TIMEOUT="${SMOKE_TEST_TIMEOUT:-600}"
API_USER="${SMOKE_TEST_USER:-Admin}"
API_PASSWORD="${SMOKE_TEST_PASSWORD:-zabbix}"
BASE_URL="http://localhost:${WEB_PORT}"

export COMPOSE_PROFILES=dev
export DB_SERVER_HOST=zabbix-dev-mysql
export DB_SERVER_PORT=3306
export MYSQL_PASSWORD="${MYSQL_PASSWORD:-zabbix}"

CONTAINERS=(zabbix-server zabbix-web zabbix-agent2 zabbix-proxy)
DEADLINE=$(( $(date +%s) + TIMEOUT ))

dump_logs() {
  local name
  for name in "${CONTAINERS[@]}" zabbix-dev-mysql; do
    echo "----- ${name} (last 60 lines) -----"
    "${ENGINE}" logs --tail 60 "${name}" 2>&1 || true
  done
}

fail() {
  echo "!! SMOKE TEST FAILED: $1" >&2
  dump_logs
  exit 1
}

# wait_for <description> <command...> — retries until it succeeds or the shared deadline passes.
wait_for() {
  local description="$1"
  shift
  printf 'Waiting for %s ' "${description}"
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "${DEADLINE}" ]; then
      echo "TIMEOUT"
      fail "timed out waiting for ${description}"
    fi
    printf '.'
    sleep 5
  done
  echo "ok"
}

is_healthy() {
  [ "$("${ENGINE}" inspect --format '{{.State.Health.Status}}' "$1")" = "healthy" ]
}

# Captured into a variable first: `logs | grep -q` can trip pipefail when grep exits before logs is done.
log_contains() {
  local output
  output="$("${ENGINE}" logs "$1" 2>&1)" || true
  grep -q -- "$2" <<<"${output}"
}

api() {
  curl -fsS -m 15 -H 'Content-Type: application/json-rpc' -d "$1" "${BASE_URL}/api_jsonrpc.php"
}

api_reports_5_0() {
  local response
  response="$(api '{"jsonrpc":"2.0","method":"apiinfo.version","params":[],"id":1}')"
  grep -q '"result":"5\.0\.' <<<"${response}"
}

# compose.yml gives every service a fixed container_name, so a same-named container left over from another
# compose project (typically a sibling zabbix-6.0-custom checkout on the same machine, even a stopped one)
# makes `compose up` fail with a name clash — and this script would then report that other project's logs.
# Stop at once, with a pointer to the cause instead.
project="${COMPOSE_PROJECT_NAME:-$(basename "${PWD}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"
foreign=()
for name in "${CONTAINERS[@]}" zabbix-dev-mysql; do
  owner="$("${ENGINE}" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${name}" 2>/dev/null)" || continue
  if [ "${owner}" != "${project}" ]; then
    foreign+=("${name} (compose project: ${owner:-none})")
  fi
done
if [ "${#foreign[@]}" -gt 0 ]; then
  echo "!! Containers with this stack's fixed names already exist but belong to a different compose project" >&2
  echo "!! than '${project}':" >&2
  printf '!!   %s\n' "${foreign[@]}" >&2
  echo "!! Take that project down first (\`${ENGINE} compose down\` in its directory) or remove them with" >&2
  echo "!! \`${ENGINE} rm\`; volumes are kept either way." >&2
  exit 1
fi

echo "=================================================================="
echo "Starting the stack (${ENGINE} compose up -d --no-build, dev-mysql profile)"
echo "=================================================================="
"${ENGINE}" compose up -d --no-build || fail "compose up failed — are the images built? (scripts/ci-pipeline.sh)"

echo ""
echo "=================================================================="
echo "Waiting for the stack (up to ${TIMEOUT}s; dev-mysql loads the schema on its first start)"
echo "=================================================================="
for name in "${CONTAINERS[@]}"; do
  wait_for "${name} to be healthy" is_healthy "${name}"
done
wait_for "zabbix-server to finish starting (connected to the database)" \
  log_contains zabbix-server 'server #0 started \[main process\]'
wait_for "zabbix-proxy to finish starting (its SQLite buffer created)" \
  log_contains zabbix-proxy 'proxy #0 started \[main process\]'
wait_for "the web frontend and its API to answer" api_reports_5_0

echo ""
echo "=================================================================="
echo "Frontend / API checks (web -> PHP 8 -> MySQL)"
echo "=================================================================="
login_page="$(curl -fsS -m 15 "${BASE_URL}/index.php")" || fail "the login page request failed"
grep -q "Zabbix" <<<"${login_page}" || fail "the login page did not render"
echo "login page renders"

login_response="$(api "{\"jsonrpc\":\"2.0\",\"method\":\"user.login\",\"params\":{\"user\":\"${API_USER}\",\"password\":\"${API_PASSWORD}\"},\"id\":2}")" \
  || fail "user.login request failed"
token="$(sed -n 's/.*"result":"\([^"]*\)".*/\1/p' <<<"${login_response}")"
[ -n "${token}" ] || fail "user.login returned no session token: ${login_response}"
echo "API login ok"

hosts_response="$(api "{\"jsonrpc\":\"2.0\",\"method\":\"host.get\",\"params\":{\"output\":[\"host\"]},\"auth\":\"${token}\",\"id\":3}")" \
  || fail "host.get request failed"
grep -q '"host":"Zabbix server"' <<<"${hosts_response}" \
  || fail "host.get did not return the built-in 'Zabbix server' host: ${hosts_response}"
echo "host.get returned the built-in 'Zabbix server' host (database read ok)"

echo ""
echo "=================================================================="
echo "Proxy -> server link (register the proxy, reload config without -c, expect configuration + lastaccess)"
echo "=================================================================="
# The proxy was started together with everything else, before it existed on the server, so its first
# configuration request was refused; that is the normal situation after registering a proxy, and the runbook
# for it is a reload on both sides. Neither command is given -c: that they work as is, like in the official
# images, is part of what is tested.
proxy_name="${ZBX_PROXY_HOSTNAME:-zabbix-proxy-sqlite3}"

proxy_get="$(api "{\"jsonrpc\":\"2.0\",\"method\":\"proxy.get\",\"params\":{\"output\":[\"proxyid\"],\"filter\":{\"host\":\"${proxy_name}\"}},\"auth\":\"${token}\",\"id\":4}")" \
  || fail "proxy.get request failed"
if ! grep -q '"proxyid"' <<<"${proxy_get}"; then
  create_response="$(api "{\"jsonrpc\":\"2.0\",\"method\":\"proxy.create\",\"params\":{\"host\":\"${proxy_name}\",\"status\":5},\"auth\":\"${token}\",\"id\":5}")" \
    || fail "proxy.create request failed"
  grep -q '"proxyids"' <<<"${create_response}" || fail "proxy.create did not register '${proxy_name}': ${create_response}"
  echo "registered proxy '${proxy_name}' on the server"
else
  echo "proxy '${proxy_name}' is already registered"
fi

reload="$("${ENGINE}" exec zabbix-server zabbix_server -R config_cache_reload 2>&1)" \
  || fail "zabbix_server -R config_cache_reload (without -c) failed: ${reload}"
echo "zabbix_server -R config_cache_reload: ${reload}"
reload="$("${ENGINE}" exec zabbix-proxy zabbix_proxy -R config_cache_reload 2>&1)" \
  || fail "zabbix_proxy -R config_cache_reload (without -c) failed: ${reload}"
echo "zabbix_proxy -R config_cache_reload: ${reload}"

wait_for "zabbix-proxy to receive its configuration from the server" \
  log_contains zabbix-proxy 'received configuration data from server'

proxy_lastaccess_is_recent() {
  local response lastaccess now
  response="$(api "{\"jsonrpc\":\"2.0\",\"method\":\"proxy.get\",\"params\":{\"output\":[\"lastaccess\"],\"filter\":{\"host\":\"${proxy_name}\"}},\"auth\":\"${token}\",\"id\":6}")" || return 1
  lastaccess="$(sed -n 's/.*"lastaccess":"\([0-9]*\)".*/\1/p' <<<"${response}")"
  [ -n "${lastaccess}" ] && [ "${lastaccess}" -gt 0 ] || return 1
  now="$("${ENGINE}" exec zabbix-server date +%s)" || return 1
  [ $(( now - lastaccess )) -lt 60 ]
}
wait_for "proxy.get to report a recent lastaccess for '${proxy_name}'" proxy_lastaccess_is_recent

echo ""
echo "=================================================================="
echo "Smoke test passed."
echo "=================================================================="
