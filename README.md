# Zabbix 5.0 Custom (PHP8 / Alpine 3.24)

Zabbix 5.0.47, patched for PHP8 compatibility and repackaged as EOL-free,
vulnerability-scanned Alpine 3.24 container images — `zabbix-server-mysql`,
`zabbix-web-nginx-mysql`, and `zabbix-agent2` — staying config/behavior
compatible with the official `zabbix/zabbix-*` images. MySQL-only backend;
LDAP/SAML removed (confirmed unused in the source project). Zabbix itself
stays on the 5.0.x line — only the PHP runtime and base images are updated.

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
```

## Docker Hub

Pre-built images are published here:

| Component | Docker Hub |
|---|---|
| zabbix-server-mysql | [tamacat/zabbix-server-mysql](https://hub.docker.com/r/tamacat/zabbix-server-mysql) |
| zabbix-web-nginx-mysql | [tamacat/zabbix-web-nginx-mysql](https://hub.docker.com/r/tamacat/zabbix-web-nginx-mysql) |
| zabbix-agent2 | [tamacat/zabbix-agent2](https://hub.docker.com/r/tamacat/zabbix-agent2) |

Tag format: `<zabbix-version>-alpine-b<build-date>` (same format across all three
images; only `zabbix-web` is actually PHP, so the tag doesn't call out PHP8
specifically) — e.g.:

```bash
podman pull tamacat/zabbix-server-mysql:5.0.47-alpine-b20260912
```

## Layout

| Path | Contents |
|---|---|
| `sources/zabbix-5.0.47/` | Patched Zabbix source (PHP8 compatibility fixes, LDAP/SAML removed) |
| `docker/` | Dockerfiles + entrypoints for server / web / agent2, plus the dev-only `dev-mysql` verification database |
| `scripts/` | Build, CI, and publish scripts |
| `compose.yml`, `.env.example` | Container orchestration |

## License

Zabbix itself is GPL-licensed — see `sources/zabbix-5.0.47/COPYING`.
