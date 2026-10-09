# Zabbix 5.0 Custom (PHP8 / Alpine 3.24)

Zabbix 5.0.47, patched for PHP8 compatibility and repackaged as EOL-free,
vulnerability-scanned Alpine 3.24 container images — `zabbix-server-mysql`,
`zabbix-web-nginx-mysql`, `zabbix-agent2`, and `zabbix-proxy-sqlite3` — staying
config/behavior compatible with the official `zabbix/zabbix-*` images. MySQL-only
backend for the main database; LDAP/SAML removed (confirmed unused in the source
project). `zabbix-proxy-sqlite3` is the one exception: its own local buffer
database is SQLite, same as the official image of that name — it never touches
the main MySQL database. Zabbix itself stays on the 5.0.x line — only the PHP
runtime and base images are updated.

## Quick start

```bash
cp .env.example .env
# edit .env: DB_SERVER_HOST, MYSQL_PASSWORD, etc. — point at your existing MySQL
podman compose up -d
```

Open http://localhost:8080/ (default `ZABBIX_WEB_PORT`).

See [MIGRATION.md](MIGRATION.md) for the full list of PHP 7 → PHP 8 compatibility
fixes applied to the Zabbix source, with root causes and verification notes.

No existing MySQL to test against? Start the bundled throwaway dev database
instead:

```bash
podman compose --profile dev up -d dev-mysql
```

`docker compose` works the same way if you're not using Podman.

## zabbix-proxy

`zabbix-proxy-sqlite3` is configured with the same environment variables as the official image of that name;
`entrypoint.sh` turns them into `zabbix_proxy.conf` at every start. An unset or empty variable leaves the
parameter at Zabbix's default.

| Variable | Parameter | Variable | Parameter |
|---|---|---|---|
| `ZBX_SERVER_HOST` (default `zabbix-server`) | `Server` | `ZBX_CONFIGFREQUENCY` | `ConfigFrequency` |
| `ZBX_SERVER_PORT` (default `10051`) | `ServerPort` | `ZBX_DATASENDERFREQUENCY` | `DataSenderFrequency` |
| `ZBX_HOSTNAME` (default `zabbix-proxy-sqlite3`) | `Hostname`, and the SQLite file `<hostname>.sqlite` | `ZBX_PROXYHEARTBEATFREQUENCY` | `HeartbeatFrequency` |
| `ZBX_HOSTNAMEITEM` | `HostnameItem` | `ZBX_PROXYLOCALBUFFER`, `ZBX_PROXYOFFLINEBUFFER` | `ProxyLocalBuffer`, `ProxyOfflineBuffer` |
| `ZBX_USE_NODE_NAME_AS_DB_NAME=true` | SQLite file named after the container's host name | `ZBX_STARTPOLLERS`, `ZBX_STARTTRAPPERS`, `ZBX_STARTPINGERS`, `ZBX_CACHESIZE`, `ZBX_HISTORYCACHESIZE`, `ZBX_TIMEOUT`, ... (the full list is in `entrypoint.sh`) | the matching `Start*`, `CacheSize`, ... |
| `ZBX_PROXYMODE` (`0` active, `1` passive) | `ProxyMode` | `ZBX_LISTENIP`, `ZBX_LISTENPORT`, `ZBX_SOURCEIP`, `ZBX_DEBUGLEVEL` | the matching parameter |
| `ZBX_TLSCONNECT`, `ZBX_TLSACCEPT`, `ZBX_TLSPSKIDENTITY`, `ZBX_TLSSERVERCERT*`, `ZBX_TLSCIPHER*` | the matching `TLS*` parameter | `ZBX_TLSPSK`, `ZBX_TLSCA`, `ZBX_TLSCERT`, `ZBX_TLSKEY`, `ZBX_TLSCRL` | the content itself, written to a file under `enc_internal` |
| `ZBX_TLSPSKFILE`, `ZBX_TLSCAFILE`, `ZBX_TLSCERTFILE`, `ZBX_TLSKEYFILE`, `ZBX_TLSCRLFILE` | a path; a relative one is looked up in the `enc` volume | `ZBX_LOADMODULE` (comma separated) | `LoadModule` (plus `LoadModulePath`) |

As in the official image, the `ZBX_*` variables are removed from the environment `zabbix_proxy` runs with
(`ZBX_CLEAR_ENV=false` keeps them). Variables for features this image is built without — the Java gateway,
IPMI, SNMP traps, SSH and fping — are not supported; the proxy says so with a warning at start instead of
dropping them silently. Run `podman logs zabbix-proxy` after changing the environment and look for
`WARNING` lines.

**Register the proxy before relying on it.** A proxy that starts before it exists on the server cannot fetch
its configuration, and then waits `ConfigFrequency` (3600 s by default) for the next try. The server also
learns about a new proxy only when its own configuration cache refreshes (every 60 s). So after creating the
proxy in the frontend (Administration → Proxies, with the same name as `ZBX_HOSTNAME`) or through the API:

```bash
podman exec zabbix-server zabbix_server -R config_cache_reload   # the server learns about the proxy
podman exec zabbix-proxy  zabbix_proxy  -R config_cache_reload   # the proxy fetches its configuration now
podman logs zabbix-proxy | grep 'received configuration data'    # confirm
```

or set `ZBX_CONFIGFREQUENCY` to something short such as `60`. Active-agent hosts then pick up their checks
within the agent's `RefreshActiveChecks` (120 s by default). "healthy" on the container is only a PID-file
check; `received configuration data` in the log and a recent `lastaccess` in the proxy list are what show it
works.

## Building images

```bash
./scripts/ci-pipeline.sh     # build + PHPUnit + podman compose build + Trivy scan
./scripts/build-images.sh    # build + tag for publishing (see Docker Hub below)
./scripts/push-images.sh     # push the tags build-images.sh produced (requires `podman login docker.io` first)
./scripts/security-scan.sh   # Trivy scan of the images + govulncheck on the Go binary, against whatever is already built locally
./scripts/govulncheck-scan.sh   # just the Go vulnerability check of zabbix_agent2 (security-scan.sh runs it too)
./scripts/smoke-test.sh      # bring the stack up on the bundled dev-mysql and exercise web -> PHP 8 -> MySQL, and proxy -> server
./scripts/test-proxy-entrypoint.sh   # proxy env-variable handling and runtime-control commands (needs no server)
```

`security-scan.sh` runs the same Trivy checks as `ci-pipeline.sh`'s Scan stage (in fact
`ci-pipeline.sh` just calls it), but on its own — no build/test/package step first. Use it to
re-check the images you already have whenever you hear about a new CVE, without rebuilding.
Set `SKIP_DB_UPDATE=1` to skip refreshing Trivy's vulnerability database first (faster, but the
results may miss anything published since your last scan).

`security-scan.sh` also runs `govulncheck-scan.sh`, which extracts `zabbix_agent2` (the only Go program) from
the agent2 image and checks it with [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck)
against the Go vulnerability database. Trivy's database trails that one by hours to a day, and the Go standard
library compiled into the binary is where new advisories land first: on 2026-10-08 govulncheck found 12 that
Trivy still called clean. Policy: **a vulnerability with a published fix fails the check** (the fix is a bump of
the `toolchain` line or a module in `sources/zabbix-5.0.47/src/go/go.mod` plus a rebuild); one without a fix yet
is only a warning. It runs in binary mode, i.e. it reports vulnerable code present in the binary whether or not
agent2 calls it. It needs `govulncheck` on `PATH` (`go install golang.org/x/vuln/cmd/govulncheck@latest`); without
it the check is skipped with a notice, unless `REQUIRE_GOVULNCHECK=1` (GitHub Actions sets it).

`smoke-test.sh` needs the images built first. It always targets the bundled `dev-mysql` (it forces
`COMPOSE_PROFILES=dev` and `DB_SERVER_HOST=zabbix-dev-mysql`, whatever `.env` says), waits for all four
containers to be healthy, then logs in through the Zabbix API and reads the built-in "Zabbix server" host.
It also registers the proxy through the API and requires it to receive its configuration from the server
and show a recent `lastaccess` — "healthy" only means a PID file exists, so it says nothing about the proxy
actually working. It leaves the stack running afterwards (`podman compose down` to stop it).

All scripts use Podman by default; set `CONTAINER_ENGINE=docker` to use Docker instead (the GitHub
Actions workflow does).

## Continuous Integration

[`.github/workflows/ci-release.yml`](.github/workflows/ci-release.yml) runs on every push and pull
request to `main`, every Monday 03:00 UTC (to rebuild on the current Alpine packages and re-scan against
the latest CVE database — edit the cron to change that), and on manual dispatch.

| Job | What it does |
|---|---|
| `lint` | Advisory only: hadolint on the four Dockerfiles, shellcheck on the scripts. Never blocks. |
| `verify` | `scripts/ci-pipeline.sh` (PHPUnit, build the 4 images, Trivy — CRITICAL findings block — and govulncheck on agent2 — a Go vulnerability with a published fix blocks), then `scripts/test-proxy-entrypoint.sh` and `scripts/smoke-test.sh`. |
| `publish` | After approval on the `production` environment: rebuilds the images, re-scans exactly what is about to be pushed, pushes to Docker Hub (`scripts/build-images.sh` → `security-scan.sh` → `push-images.sh`), signs each image with cosign (keyless) and attaches a CycloneDX SBOM. Skipped for pull requests. |

Before `publish` can run, this repository's GitHub settings need a one-time setup (a workflow file
cannot do it):

1. **Settings → Environments → New environment** named `production`, with yourself as a **required
   reviewer** (this is the self-review gate before anything is published). Optionally restrict it to
   the `main` branch under *Deployment branches*, so a manual dispatch from another branch cannot publish.
2. **Settings → Secrets and variables → Actions**: add repository secrets `DOCKERHUB_USERNAME`
   (`tamacat`) and `DOCKERHUB_TOKEN` (a Docker Hub access token scoped to push only).

Published tags follow the same `<zabbix-version>-alpine-b<build-date>` format as a local
`scripts/build-images.sh` run (the date is fixed when `verify` runs). Verify a signature with:

```bash
cosign verify tamacat/zabbix-server-mysql:5.0.47-alpine-b20260926 \
  --certificate-identity-regexp 'https://github.com/tamacat/zabbix-5.0-custom/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Docker Hub

Pre-built images are published here:

| Component | Docker Hub |
|---|---|
| zabbix-server-mysql | [tamacat/zabbix-server-mysql](https://hub.docker.com/r/tamacat/zabbix-server-mysql) |
| zabbix-web-nginx-mysql | [tamacat/zabbix-web-nginx-mysql](https://hub.docker.com/r/tamacat/zabbix-web-nginx-mysql) |
| zabbix-agent2 | [tamacat/zabbix-agent2](https://hub.docker.com/r/tamacat/zabbix-agent2) |
| zabbix-proxy-sqlite3 | [tamacat/zabbix-proxy-sqlite3](https://hub.docker.com/r/tamacat/zabbix-proxy-sqlite3) |

Tag format: `<zabbix-version>-alpine-b<build-date>` (same format across all four
images; only `zabbix-web` is actually PHP, so the tag doesn't call out PHP8
specifically) — e.g.:

```bash
podman pull tamacat/zabbix-server-mysql:5.0.47-alpine-b20260917
```

## Layout

| Path | Contents |
|---|---|
| `sources/zabbix-5.0.47/` | Patched Zabbix source (PHP8 compatibility fixes, LDAP/SAML removed) |
| `docker/` | Dockerfiles + entrypoints for server / web / agent2 / proxy, plus the dev-only `dev-mysql` verification database |
| `scripts/` | Build, CI, and publish scripts |
| `compose.yml`, `.env.example` | Container orchestration |

## License

Zabbix itself is GPL-licensed — see `sources/zabbix-5.0.47/COPYING`.
