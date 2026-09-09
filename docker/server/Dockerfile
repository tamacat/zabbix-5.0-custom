# Zabbix server — Alpine 3.24, built from the existing (unmodified) sources/zabbix-5.0.47/ C sources
# [FR4.1][FR4.3]. This migration does not change zabbix_server's C code — only its build/runtime container.
#
# Build context is the repository root (see compose.yml). Multi-stage: compile in a build-tools
# stage, ship only the resulting binary plus runtime shared libraries in the final image.

FROM alpine:3.24 AS builder

RUN apk add --no-cache \
		build-base \
		pkgconf \
		pcre-dev \
		mariadb-connector-c-dev \
		openssl-dev \
		libevent-dev \
		zlib-dev \
		libxml2-dev \
		curl-dev \
		net-snmp-dev

WORKDIR /build
COPY sources/zabbix-5.0.47/ /build/

# build-and-test found ./configure lost its executable bit somewhere in this repo's checkout/copy
# history (COPY preserves the source filesystem's permission bits, and this workspace's copy of
# sources/zabbix-5.0.47/configure is not marked executable) — invoke it via `sh` instead of relying on
# the exec bit, which works regardless of how the file's permissions travel.
#
# --with-mysql per code-generation-plan.md Step 4.3. net-snmp/libcurl/libxml2/openssl are included so the
# server binary keeps the optional integrations (SNMP checks, web monitoring, XML/TLS) the upstream
# zabbix/zabbix-server-mysql image also ships, matching the "same env vars and behavior" mandate
# [project.md Mandated] rather than a stripped-down rebuild.
# --disable-dependency-tracking: build-and-test found config.status fails to bootstrap automake's
# dependency-tracking makefile fragments in this container filesystem (a known autotools issue tied to
# how file timestamps travel through COPY/layer extraction); irrelevant anyway for a one-shot image
# build with no incremental rebuilds, and configure's own error message names this as the fix.
RUN sh ./configure \
		--disable-dependency-tracking \
		--enable-server \
		--enable-ipv6 \
		--with-mysql \
		--with-net-snmp \
		--with-libcurl \
		--with-libxml2 \
		--with-openssl \
	&& make -j"$(nproc)"

FROM alpine:3.24

RUN apk add --no-cache \
		mariadb-connector-c \
		pcre \
		openssl \
		libevent \
		zlib \
		libxml2 \
		libcurl \
		net-snmp-libs \
		tzdata \
		ca-certificates \
		su-exec

# UID/GID 1997 (not 101) — build-and-test found 101 collides with nginx's own group in the web image;
# kept consistent across all three images even though this one doesn't install nginx.
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/src/zabbix_server/zabbix_server /usr/sbin/zabbix_server
COPY --from=builder /build/conf/zabbix_server.conf /etc/zabbix/zabbix_server.conf.default

RUN mkdir -p /etc/zabbix /var/lib/zabbix/alertscripts /var/lib/zabbix/externalscripts /var/lib/zabbix/enc \
		/var/lib/zabbix/export /var/lib/zabbix/modules /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/server/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/alertscripts", "/var/lib/zabbix/externalscripts", "/var/lib/zabbix/enc"]

# build-and-test: no `USER zabbix` here (unlike web/agent2) — entrypoint.sh needs root briefly to run
# update-ca-certificates when a verification database's CA is mounted in (see entrypoint.sh), then drops
# to the zabbix user itself via su-exec before exec'ing zabbix_server. The daemon process still never
# runs as root.

# Process-liveness health check via the PID file entrypoint.sh configures [reliability-design.md /
# monitoring-design.md — server: PIDファイルの存在確認によるプロセス生存確認].
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD test -f /run/zabbix/zabbix_server.pid && kill -0 "$(cat /run/zabbix/zabbix_server.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
