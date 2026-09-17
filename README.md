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

## Building images

```bash
./scripts/ci-pipeline.sh     # build + PHPUnit + podman compose build + Trivy scan
./scripts/build-images.sh    # build + tag for publishing (see Docker Hub below)
./scripts/push-images.sh     # push the tags build-images.sh produced (requires `podman login docker.io` first)
./scripts/security-scan.sh   # Trivy scan only, against whatever images are already built locally
```

`security-scan.sh` runs the same Trivy checks as `ci-pipeline.sh`'s Scan stage (in fact
`ci-pipeline.sh` just calls it), but on its own — no build/test/package step first. Use it to
re-check the images you already have whenever you hear about a new CVE, without rebuilding.
Set `SKIP_DB_UPDATE=1` to skip refreshing Trivy's vulnerability database first (faster, but the
results may miss anything published since your last scan).

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
