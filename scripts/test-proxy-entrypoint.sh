#!/usr/bin/env bash
# Tests for the built zabbix-proxy-sqlite3 image that need no Zabbix server: how docker/proxy/entrypoint.sh
# turns the official image's environment variables into zabbix_proxy.conf (and what it does with ones it
# cannot honour), and that the runtime-control commands work without -c, as in the official images.
#
# Each case starts the real image (it just keeps retrying to reach a server that does not exist) and inspects
# the generated config, the container's environment and its log. Needs the images built first
# (scripts/ci-pipeline.sh or `<engine> compose build`). GitHub Actions runs this after ci-pipeline.sh.
#
#   CONTAINER_ENGINE=podman    # "docker" on GitHub Actions
#   PROXY_IMAGE / SERVER_IMAGE / AGENT2_IMAGE   override the images under test
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

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
TAG="${ZABBIX_IMAGE_TAG:-5.0.47-custom}"
PROXY_IMAGE="${PROXY_IMAGE:-localhost/zabbix-proxy-sqlite3-php8migration:${TAG}}"
SERVER_IMAGE="${SERVER_IMAGE:-localhost/zabbix-server-mysql-php8migration:${TAG}}"
AGENT2_IMAGE="${AGENT2_IMAGE:-localhost/zabbix-agent2-php8migration:${TAG}}"
CONF=/etc/zabbix/zabbix_proxy.conf
LABEL=zbx-entrypoint-test
export MSYS_NO_PATHCONV=1

pass=0
failed=0
cleanup() { "${ENGINE}" ps -a --filter "label=${LABEL}" -q | xargs -r "${ENGINE}" rm -f >/dev/null 2>&1; }

ok()  { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL - $1"; }

# start <case> [docker run options...] — a detached proxy that is waiting out its connection retries.
start() {
  local name="zbxept-$1"
  shift
  "${ENGINE}" run -d --label "${LABEL}" --name "${name}" "$@" "${PROXY_IMAGE}" >/dev/null || return 1
  for _ in $(seq 1 30); do
    "${ENGINE}" logs "${name}" 2>&1 | grep -q 'using configuration file' && return 0
    [ "$("${ENGINE}" inspect --format '{{.State.Running}}' "${name}")" = "true" ] || return 0
    sleep 1
  done
}
WORK="$(mktemp -d)"
trap 'cleanup; rm -rf "${WORK}"' EXIT

# dry <case> [docker run options...] — runs the real entrypoint, but with a stand-in zabbix_proxy that just
# prints the generated config, so nothing has to start (cases with files or modules that do not exist would
# make the real daemon exit). The config goes to ${WORK}/<case>.conf, the entrypoint's own messages to
# ${WORK}/<case>.err, its exit status to ${WORK}/<case>.rc.
dry() {
  local name="$1"
  shift
  # The script below runs inside the container, so it is deliberately single-quoted.
  # shellcheck disable=SC2016
  "${ENGINE}" run --rm --label "${LABEL}" "$@" --entrypoint sh "${PROXY_IMAGE}" -c '
    mkdir -p /tmp/stub \
      && printf "#!/bin/sh\ncat /etc/zabbix/zabbix_proxy.conf\n" > /tmp/stub/zabbix_proxy \
      && chmod +x /tmp/stub/zabbix_proxy \
      && PATH=/tmp/stub:$PATH exec /usr/local/bin/entrypoint.sh' \
    >"${WORK}/${name}.conf" 2>"${WORK}/${name}.err"
  echo $? >"${WORK}/${name}.rc"
}
logs() {
  if [ -f "${WORK}/$1.err" ]; then cat "${WORK}/$1.err"; else "${ENGINE}" logs "zbxept-$1" 2>&1; fi
}
conf() {
  if [ -f "${WORK}/$1.conf" ]; then cat "${WORK}/$1.conf"; else "${ENGINE}" exec "zbxept-$1" cat "${CONF}"; fi
}
running() { [ "$("${ENGINE}" inspect --format '{{.State.Running}}' "zbxept-$1")" = "true" ]; }
wait_log() { # wait_log <case> <regex> — up to 30 s
  for _ in $(seq 1 30); do logs "$1" | grep -q -- "$2" && return 0; sleep 1; done
  return 1
}
expect() { # expect <case> <line>
  if grep -qxF -- "$2" <<<"$(conf "$1")"; then ok "$1: $2"; else bad "$1: expected '$2' in ${CONF}"; fi
}
expect_absent() { # expect_absent <case> <parameter>
  if grep -q -- "^$2" <<<"$(conf "$1")"; then bad "$1: unexpected $2 line"; else ok "$1: no $2 line"; fi
}
daemon_env_has() { "${ENGINE}" exec "zbxept-$1" sh -c "tr '\\0' '\\n' < /proc/1/environ | grep -q '$2'"; }

echo "== defaults (no variables) =="
start defaults
expect defaults 'Server=zabbix-server'
expect defaults 'ServerPort=10051'
expect defaults 'Hostname=zabbix-proxy-sqlite3'
expect defaults 'DBName=/var/lib/zabbix/db_data/zabbix-proxy-sqlite3.sqlite'
expect_absent defaults ProxyMode
expect_absent defaults ConfigFrequency
expect_absent defaults TLSConnect
if logs defaults | grep -q 'WARNING'; then bad "defaults: unexpected warning in the log"; else ok "defaults: no warnings"; fi

echo "== official variables reach the configuration =="
start vars \
  -e ZBX_HOSTNAME=my-proxy -e ZBX_SERVER_HOST=zbxept-defaults -e ZBX_SERVER_PORT=10055 -e ZBX_PROXYMODE=0 \
  -e ZBX_CONFIGFREQUENCY=120 -e ZBX_DATASENDERFREQUENCY=2 -e ZBX_PROXYOFFLINEBUFFER=48 \
  -e ZBX_PROXYLOCALBUFFER=1 -e ZBX_PROXYHEARTBEATFREQUENCY=30 -e ZBX_DEBUGLEVEL=4 -e ZBX_STARTPOLLERS=2 \
  -e ZBX_CACHESIZE=16M -e ZBX_TIMEOUT=10 -e ZBX_LISTENPORT=10061 -e ZBX_ENABLEREMOTECOMMANDS=1
for line in Server=zbxept-defaults ServerPort=10055 Hostname=my-proxy \
            DBName=/var/lib/zabbix/db_data/my-proxy.sqlite ProxyMode=0 ConfigFrequency=120 \
            DataSenderFrequency=2 ProxyOfflineBuffer=48 ProxyLocalBuffer=1 HeartbeatFrequency=30 \
            DebugLevel=4 StartPollers=2 CacheSize=16M Timeout=10 ListenPort=10061 EnableRemoteCommands=1; do
  expect vars "${line}"
done
if logs vars | grep -q 'WARNING'; then bad "vars: unexpected warning in the log"; else ok "vars: no warnings"; fi
wait_log vars 'started \[icmp pinger #1\]' # the last process of the startup sequence
if [ "$(logs vars | grep -c 'started \[poller #')" = "2" ]; then ok "vars: ZBX_STARTPOLLERS=2 started 2 pollers"
else bad "vars: expected 2 poller processes"; fi

echo "== passive mode =="
start passive -e ZBX_PROXYMODE=1 -e ZBX_SERVER_HOST=127.0.0.1
expect passive 'ProxyMode=1'
if wait_log passive 'Starting Zabbix Proxy (passive)' && running passive; then ok "passive: zabbix_proxy runs in passive mode"
else bad "passive: zabbix_proxy did not start in passive mode"; logs passive | tail -5; fi

echo "== HostnameItem, node name as DB name, modules =="
dry hostitem -e ZBX_HOSTNAMEITEM=system.hostname -e ZBX_USE_NODE_NAME_AS_DB_NAME=TRUE --hostname node-7 \
  -e ZBX_LOADMODULE=a.so,b.so
expect hostitem 'HostnameItem=system.hostname'
expect_absent hostitem 'Hostname='
expect hostitem 'DBName=/var/lib/zabbix/db_data/node-7.sqlite'
expect hostitem 'LoadModulePath=/var/lib/zabbix/modules'
expect hostitem 'LoadModule=a.so'
expect hostitem 'LoadModule=b.so'

echo "== TLS: PSK given as a value =="
psk=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
start tls -e ZBX_TLSCONNECT=psk -e ZBX_TLSACCEPT=psk -e ZBX_TLSPSKIDENTITY=psk-id-1 -e "ZBX_TLSPSK=${psk}"
expect tls 'TLSConnect=psk'
expect tls 'TLSAccept=psk'
expect tls 'TLSPSKIdentity=psk-id-1'
expect tls 'TLSPSKFile=/var/lib/zabbix/enc_internal/TLSPSKFile'
psk_file=/var/lib/zabbix/enc_internal/TLSPSKFile
if [ "$("${ENGINE}" exec zbxept-tls cat "${psk_file}")" = "${psk}" ]; then ok "tls: the PSK value was written to ${psk_file}"
else bad "tls: ${psk_file} does not hold the PSK"; fi
if [ "$("${ENGINE}" exec zbxept-tls stat -c %a "${psk_file}")" = "600" ]; then ok "tls: the PSK file is mode 600"
else bad "tls: the PSK file is not mode 600"; fi
# PID 1 is zabbix_proxy itself (the entrypoint exec's it), so this is the environment the daemon runs with.
if daemon_env_has tls '^ZBX_'; then bad "tls: ZBX_* variables (incl. the PSK) are still in the daemon's environment"
else ok "tls: ZBX_* variables were cleared from the daemon's environment"; fi

echo "== TLS: certificates given as file names (relative ones live in the enc volume) =="
# These files and modules do not exist, so the real zabbix_proxy would refuse to start: a dry run.
dry tlsfiles -e ZBX_TLSCONNECT=cert -e ZBX_TLSCAFILE=ca.crt -e ZBX_TLSCERTFILE=/abs/proxy.crt -e ZBX_TLSKEYFILE=proxy.key
expect tlsfiles 'TLSCAFile=/var/lib/zabbix/enc/ca.crt'
expect tlsfiles 'TLSCertFile=/abs/proxy.crt'
expect tlsfiles 'TLSKeyFile=/var/lib/zabbix/enc/proxy.key'

echo "== ZBX_CLEAR_ENV=false keeps the variables =="
start keepenv -e ZBX_CLEAR_ENV=false -e ZBX_HOSTNAME=keep-env
if daemon_env_has keepenv '^ZBX_HOSTNAME=keep-env'; then ok "keepenv: ZBX_HOSTNAME is still in the daemon's environment"
else bad "keepenv: ZBX_CLEAR_ENV=false should keep the variables"; fi

echo "== variables this image cannot honour are reported, not dropped silently =="
dry unsupported -e ZBX_FPINGLOCATION=/usr/sbin/fping -e ZBX_JAVAGATEWAY_ENABLE=true -e ZBX_TLSCONNECT=psk \
  -e ZBX_TLSPSKIDENTITY=x -e ZBX_TLSPSK=00112233445566778899aabbccddeeff
for var in ZBX_FPINGLOCATION ZBX_JAVAGATEWAY_ENABLE; do
  if logs unsupported | grep -q "WARNING: ${var} is set but is not supported"; then ok "unsupported: warning for ${var}"
  else bad "unsupported: no warning for ${var}"; fi
done
if logs unsupported | grep -q 'WARNING: ZBX_TLS'; then bad "unsupported: wrongly warned about a supported variable"
else ok "unsupported: no warning for a supported variable"; fi

echo "== a value that would inject a config line is refused =="
dry inject -e $'ZBX_HOSTNAME=a
TLSConnect=unencrypted'
if [ "$(cat "${WORK}/inject.rc")" = "0" ]; then bad "inject: a hostname containing a line break was accepted"
elif logs inject | grep -q 'line break'; then ok "inject: refused with a clear message"
else bad "inject: refused, but without the expected message"; fi

echo "== runtime control works without -c (as in the official images) =="
# The help output is captured first: `grep -q` closing the pipe early would fail the pipeline under pipefail.
default_path() {
  local help
  help="$("${ENGINE}" run --rm --label "${LABEL}" --entrypoint "$1" "$2" -h 2>&1)"
  grep -qF "$3" <<<"${help}"
}
for spec in "zabbix_proxy:${PROXY_IMAGE}:/etc/zabbix/zabbix_proxy.conf" \
            "zabbix_server:${SERVER_IMAGE}:/etc/zabbix/zabbix_server.conf" \
            "zabbix_agent2:${AGENT2_IMAGE}:/etc/zabbix/zabbix_agent2.conf"; do
  binary="${spec%%:*}"
  rest="${spec#*:}"
  image="${rest%:*}"
  path="${rest##*:}"
  if default_path "${binary}" "${image}" "${path}"; then ok "${binary} defaults to ${path}"
  else bad "${binary} does not default to ${path}"; fi
done
echo "== ICMP checks need fping, usable by the zabbix user once the container has NET_RAW =="
# Without fping Zabbix marks every icmpping/icmppingsec/icmppingloss item unsupported ("At least one of
# '/usr/sbin/fping', '/usr/sbin/fping6' must exist"). Alpine's fping carries cap_net_raw, so the only other
# requirement is the capability, which compose.yml grants (Podman's defaults lack it, Docker's include it).
for spec in "proxy:${PROXY_IMAGE}" "server:${SERVER_IMAGE}"; do
  name="${spec%%:*}"
  image="${spec#*:}"
  if [ "$("${ENGINE}" run --rm --label "${LABEL}" --entrypoint sh "${image}" -c 'command -v fping' 2>/dev/null)" = "/usr/sbin/fping" ]; then
    ok "${name}: /usr/sbin/fping is installed (Zabbix's default FpingLocation)"
  else bad "${name}: /usr/sbin/fping is missing"; fi
  ping_out="$("${ENGINE}" run --rm --label "${LABEL}" --user zabbix --cap-add NET_RAW --entrypoint fping "${image}" -c1 -t500 127.0.0.1 2>&1)"
  if grep -q '0% loss' <<<"${ping_out}"; then ok "${name}: the zabbix user can ping 127.0.0.1 with fping"
  else bad "${name}: fping as the zabbix user failed: ${ping_out}"; fi
done

out="$("${ENGINE}" exec zbxept-defaults zabbix_proxy -R config_cache_reload 2>&1)"
if grep -q 'command sent successfully' <<<"${out}"; then ok "zabbix_proxy -R config_cache_reload (no -c) on a running proxy"
else bad "zabbix_proxy -R config_cache_reload failed: ${out}"; fi

echo
echo "${pass} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
