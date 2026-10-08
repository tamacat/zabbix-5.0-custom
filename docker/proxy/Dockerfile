# Zabbix proxy (SQLite3) — Alpine 3.24, built from the existing (unmodified) sources/zabbix-5.0.47/
# C sources, mirroring docker/server/Dockerfile's structure. Unlike zabbix-server, this binary is built
# with --with-sqlite3 instead of --with-mysql: the proxy's own database is a local buffer file, not the
# project's main database (project.md Mandated: main database stays MySQL-only; the SQLite3 buffer here
# is a documented, narrowly-scoped exception — see project.md Corrections, 2026-09-17). No PHP/UI code is
# involved, so this component needed no PHP8 migration work — it is a fresh package of the unmodified
# upstream C proxy daemon.
#
# Build context is the repository root (see compose.yml).

FROM alpine:3.24 AS builder

RUN apk add --no-cache \
		build-base \
		pkgconf \
		pcre-dev \
		sqlite-dev \
		openssl-dev \
		libevent-dev \
		zlib-dev \
		libxml2-dev \
		curl-dev \
		net-snmp-dev

WORKDIR /build
COPY sources/zabbix-5.0.47/ /build/

# Keep make from trying to regenerate the tarball's autotools output — see docker/server/Dockerfile.
RUN touch aclocal.m4 \
	&& find . \( -name configure -o -name config.h.in -o -name Makefile.in \) -exec touch {} +

# Same configure-via-sh and --disable-dependency-tracking workarounds as docker/server/Dockerfile — see
# that file's comments for why. --with-sqlite3 (not --with-mysql) is the one deliberate difference:
# zabbix-proxy-sqlite3 stores its local buffer in a SQLite file, matching the official
# zabbix/zabbix-proxy-sqlite3 image's own database choice.
# --sysconfdir=/etc/zabbix: see docker/server/Dockerfile — makes `zabbix_proxy -R config_cache_reload` work
# without -c, as in the official image.
RUN sh ./configure \
		--sysconfdir=/etc/zabbix \
		--disable-dependency-tracking \
		--enable-proxy \
		--enable-ipv6 \
		--with-sqlite3 \
		--with-net-snmp \
		--with-libcurl \
		--with-libxml2 \
		--with-openssl \
	&& make -j"$(nproc)"

FROM alpine:3.24

# fping: ICMP checks run through the proxy (see docker/server/Dockerfile for the NET_RAW requirement).
RUN apk add --no-cache \
		sqlite-libs \
		pcre \
		openssl \
		libevent \
		zlib \
		libxml2 \
		libcurl \
		net-snmp-libs \
		fping \
		tzdata \
		ca-certificates \
	&& apk upgrade --no-cache zlib
# ^ the base layer already ships zlib 1.3.2-r0 (CVE-2026-85091, fixed in 1.3.2-r1); see docker/server/Dockerfile.

# Same UID/GID 1997 convention as the other 3 images (see docker/server/Dockerfile).
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/src/zabbix_proxy/zabbix_proxy /usr/sbin/zabbix_proxy
COPY --from=builder /build/conf/zabbix_proxy.conf /etc/zabbix/zabbix_proxy.conf.default

# db_data holds the SQLite buffer file — the one piece of local state this component actually owns
# (unlike server/web/agent2, which are stateless besides the mounted config/script dirs). enc is TLS
# material (matching server's own enc dir) for the proxy->server link; externalscripts mirrors server's
# own optional custom-check support. enc_internal is where entrypoint.sh puts TLS material given as plain
# values (ZBX_TLSPSK, ZBX_TLSCERT, ...) rather than as files in enc; modules is the LoadModulePath for
# ZBX_LOADMODULE.
RUN mkdir -p /etc/zabbix /var/lib/zabbix/db_data /var/lib/zabbix/enc /var/lib/zabbix/enc_internal \
		/var/lib/zabbix/externalscripts /var/lib/zabbix/modules /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/proxy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/db_data", "/var/lib/zabbix/enc", "/var/lib/zabbix/externalscripts"]

USER zabbix
EXPOSE 10051

# Process-liveness health check via the PID file entrypoint.sh configures, matching server/agent2's own
# HEALTHCHECK approach.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
	CMD test -f /run/zabbix/zabbix_proxy.pid && kill -0 "$(cat /run/zabbix/zabbix_proxy.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
