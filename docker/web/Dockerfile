# Zabbix web (Nginx + PHP-FPM) — Alpine 3.24 / PHP8.x [FR3.1][FR3.2][project.md Mandated: Alpine 3.24,
# zabbix/zabbix-web-nginx-mysql compatibility].
#
# Build context is the repository root (see compose.yml) so this Dockerfile can COPY the migrated
# ui/ tree from sources/zabbix-5.0.47/ui/. Test-only files (tests/, composer.json, phpunit.xml.dist) are
# excluded via the repository-root .dockerignore — this production image never installs Composer/PHPUnit.
#
# NOTE: Alpine 3.24 postdates this migration's knowledge base. The php83-* package names below are the
# best-available match for "the latest stable PHP8.x Alpine 3.24 ships" [tech-stack-decisions.md]; verify
# them against the real Alpine 3.24 package index at first build and adjust PHP_PKG/PHP_INI_DIR if the
# default PHP version has moved on by then (see code-summary.md).

FROM alpine:3.24

ARG PHP_PKG=php83
ARG PHP_INI_DIR=/etc/php83

# PHP extensions per requirements.md FR3.3 (ldap intentionally excluded — see FR2.1/CFrontendSetupTest.php).
RUN apk add --no-cache \
		nginx \
		${PHP_PKG} \
		${PHP_PKG}-fpm \
		${PHP_PKG}-opcache \
		${PHP_PKG}-mbstring \
		${PHP_PKG}-sockets \
		${PHP_PKG}-bcmath \
		${PHP_PKG}-gd \
		${PHP_PKG}-xml \
		${PHP_PKG}-xmlwriter \
		${PHP_PKG}-xmlreader \
		${PHP_PKG}-openssl \
		${PHP_PKG}-ctype \
		${PHP_PKG}-session \
		${PHP_PKG}-gettext \
		${PHP_PKG}-mysqli \
		${PHP_PKG}-phar \
		${PHP_PKG}-tokenizer \
		${PHP_PKG}-fileinfo \
		${PHP_PKG}-iconv \
		${PHP_PKG}-dom \
		tzdata

# Non-root execution [security-design.md "コンテナ実行ユーザー設計" — UID/GID decided here, 1997:1997.
# build-and-test discovered that 101:101 collides with the "nginx" group/user the nginx apk package
# itself creates on install (confirmed: `apk add nginx` on Alpine 3.24 yields group nginx:101), so this
# Dockerfile cannot use that GID; 1997 matches the UID/GID convention the upstream zabbix/zabbix-*
# images use for the zabbix user, which does not collide with any package installed above].
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY docker/web/conf/nginx.conf /etc/nginx/nginx.conf
COPY docker/web/conf/opcache.ini ${PHP_INI_DIR}/conf.d/99-opcache-zabbix.ini
COPY docker/web/conf/zabbix.ini ${PHP_INI_DIR}/conf.d/99-zabbix.ini

# ui/conf/zabbix.conf.php does not exist in source (only the .example ships) — entrypoint.sh generates the
# real one at container start from environment variables, so it is never baked into the image.
COPY --chown=zabbix:zabbix sources/zabbix-5.0.47/ui/ /usr/share/zabbix/

RUN mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi \
	&& chown -R zabbix:zabbix /usr/share/zabbix /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
		/tmp/nginx-uwsgi /tmp/nginx-scgi

COPY docker/web/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/usr/share/zabbix/conf"]

USER zabbix
EXPOSE 8080

# Shallow health check only — HTTP endpoint response, no DB connectivity check
# [reliability-design.md "webコンテナのヘルスチェックは浅いチェックとする"][Q4].
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
	CMD wget -q -O /dev/null http://127.0.0.1:8080/ || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
