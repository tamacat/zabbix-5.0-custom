# Zabbix web (Nginx + PHP-FPM) — Alpine 3.24 / PHP8.x [FR3.1][FR3.2][project.md Mandated: Alpine 3.24,
# zabbix/zabbix-web-nginx-mysql compatibility].
#
# Build context is the repository root (see compose.yml) so this Dockerfile can COPY the migrated
# ui/ tree from sources/zabbix-5.0.47/ui/. Test-only files (tests/, composer.json, phpunit.xml.dist) are
# excluded via the repository-root .dockerignore — this production image never installs Composer/PHPUnit.
#
# NOTE: PHP is built from the official source in the php-build stage below, not installed from Alpine's
# php83 packages (see the comment there). PHP_INI_DIR is the config directory that build uses.

# PHP is compiled from the official source instead of using Alpine's php83 packages, so a PHP
# security release (2026-10-21: PHP 8.3.36 fixes two unauthenticated remote-code-execution flaws) can be
# taken the day it is published instead of whenever Alpine packages it. The extension set is the one the
# Alpine packages provided and Zabbix needs, and nothing else (no curl, sodium, sqlite3, ...).

# PHP version and SHA-256. To upgrade, take both from https://www.php.net/releases/index.php?json&version=8.3
# (verified 2026-10-22). Trivy cannot see PHP's own vulnerabilities (this PHP is not an Alpine package), so
# scripts/check-php-version.sh and the scheduled CI run watch for a newer release.
ARG PHP_VERSION=8.3.36
ARG PHP_SHA256=dd54693aa334c5c4d72e9aee96b082c2473750a18a6c1d105789c93a3b1692fd

# ---------------------------------------------------------------------------------------
# Build PHP (php-fpm and the CLI)
# ---------------------------------------------------------------------------------------
FROM alpine:3.24 AS php-build

ARG PHP_VERSION
ARG PHP_SHA256

# hadolint ignore=DL3017
RUN apk upgrade --no-cache

# linux-headers: the sockets extension uses the kernel header linux/filter.h.
RUN apk add --no-cache \
		build-base linux-headers autoconf bison re2c pkgconf curl xz \
		libxml2-dev openssl-dev zlib-dev pcre2-dev oniguruma-dev gettext-dev \
		libpng-dev libjpeg-turbo-dev freetype-dev libwebp-dev

WORKDIR /usr/src
RUN curl -fsSL -o php.tar.xz "https://www.php.net/distributions/php-${PHP_VERSION}.tar.xz" \
	&& echo "${PHP_SHA256}  php.tar.xz" | sha256sum -c - \
	&& tar -xJf php.tar.xz --strip-components=1

# Start from --disable-all and add only what Zabbix needs: the same set the Alpine php83 packages gave
# (bcmath ctype dom fileinfo filter gd gettext iconv mbstring mysqli mysqlnd openssl session sockets
# tokenizer xml xmlreader xmlwriter zlib, plus phar and opcache). The layout follows the Alpine packages
# (/etc/php83, php83 and php-fpm83) so entrypoint.sh and the conf.d files need no change.
RUN ./configure \
		--prefix=/usr \
		--sysconfdir=/etc/php83 \
		--localstatedir=/var \
		--program-suffix=83 \
		--with-config-file-path=/etc/php83 \
		--with-config-file-scan-dir=/etc/php83/conf.d \
		--disable-all --disable-cgi --disable-phpdbg --without-pear \
		--enable-cli --enable-fpm \
		--enable-bcmath --enable-ctype --enable-dom --enable-fileinfo --enable-filter \
		--enable-gd --with-freetype --with-jpeg --with-webp \
		--with-gettext --with-iconv --enable-mbstring \
		--enable-mysqlnd --with-mysqli=mysqlnd --with-mysql-sock=/run/mysqld/mysqld.sock \
		--with-openssl --enable-session --enable-sockets --enable-tokenizer \
		--enable-xml --enable-xmlreader --enable-xmlwriter --with-libxml \
		--with-zlib --with-external-pcre --enable-phar --enable-opcache \
	&& make -j"$(nproc)" \
	&& make install-cli install-fpm install-modules INSTALL_ROOT=/php-root \
	&& strip /php-root/usr/bin/php83 /php-root/usr/sbin/php-fpm83 \
	# The Alpine package shipped a production php.ini (display_errors off, errors logged not shown). A
	# source build installs none, so use PHP's own production template. conf.d/99-*.ini override it.
	&& mkdir -p /php-root/etc/php83/conf.d /php-root/etc/php83/php-fpm.d \
	&& cp php.ini-production /php-root/etc/php83/php.ini \
	# OPcache is built as a shared library (opcache.so) and must be loaded by an ini file.
	&& echo "zend_extension=opcache" > /php-root/etc/php83/conf.d/00_opcache.ini

# ---------------------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------------------

FROM alpine:3.24

ARG PHP_INI_DIR=/etc/php83

# Refresh the package index and take any already-published security fix for openssl (libssl3/
# libcrypto3) and zlib ahead of installing everything else. The alpine:3.24 base layer is a point-in-time
# snapshot; apk update/upgrade pulls whatever Alpine's v3.24 stable branch has published since,
# independent of when that base layer was last pulled (zlib 1.3.2-r0 in the base layer carries
# CVE-2026-85091, fixed in 1.3.2-r1). Targeted (not a blanket `apk upgrade`) to keep the rest of the
# image's package versions reproducible.
RUN apk update && apk upgrade --no-cache libssl3 libcrypto3 zlib

# Runtime libraries for what PHP links against (the counterparts of the -dev packages above; libgcc is
# needed by opcache.so). The PHP extension list is in the php-build stage.
RUN apk add --no-cache \
		font-ipa \
		nginx \
		libxml2 libssl3 libcrypto3 zlib pcre2 oniguruma gettext-libs \
		libpng libjpeg-turbo freetype libwebp libgcc \
		tzdata

# Only /usr and /etc are copied: the build result also holds /var/run as a directory, and in Alpine
# /var/run is a symlink to /run, which BuildKit refuses to copy a directory over.
COPY --from=php-build /php-root/usr/ /usr/
COPY --from=php-build /php-root/etc/ /etc/

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

# Fail the build if a shared library PHP needs is missing. opcache.so also needs libgcc_s.so.1, which ldd on
# the php binary does not list, so also check that PHP can load OPcache.
RUN ! ldd /usr/bin/php83 /usr/sbin/php-fpm83 | grep -i "not found" \
	&& php83 -m | grep -qx mysqli && php83 -m | grep -qx "Zend OPcache" \
	&& printf '[global]\n[www]\nuser = nobody\nlisten = 127.0.0.1:9000\npm = dynamic\npm.max_children = 2\npm.start_servers = 1\npm.min_spare_servers = 1\npm.max_spare_servers = 1\n' > /tmp/fpm-check.conf \
	&& php-fpm83 -t -y /tmp/fpm-check.conf && rm /tmp/fpm-check.conf

# ui/conf/zabbix.conf.php does not exist in source (only the .example ships) — entrypoint.sh generates the
# real one at container start from environment variables, so it is never baked into the image.
COPY --chown=zabbix:zabbix sources/zabbix-5.0.47/ui/ /usr/share/zabbix/

# Graph text font with Japanese glyphs: ZBX_GRAPH_FONT_NAME is 'IPAPGothic' (include/defines.inc.php), looked up
# as assets/fonts/IPAPGothic.ttf. The bundled DejaVuSans.ttf has no CJK glyphs, so Japanese item names, host
# names and legends in graphs came out as boxes. font-ipa (IPA Gothic/Mincho, TTF) is installed above.
RUN ln -s /usr/share/fonts/ipafont/ipagp.ttf /usr/share/zabbix/assets/fonts/IPAPGothic.ttf

# These directories are empty in the Zabbix tarball, and git does not keep empty directories, so a checkout
# (CI, a fresh clone) does not have them and the COPY above cannot bring them along. The frontend expects
# them all the same: Administration -> General -> Modules -> "Scan directory" iterates ui/modules and throws
# if it is missing, and local/ is where site-specific controllers, views and config are meant to go.
RUN mkdir -p /usr/share/zabbix/modules /usr/share/zabbix/conf/certs /usr/share/zabbix/local/conf \
		/usr/share/zabbix/local/app/controllers /usr/share/zabbix/local/app/partials /usr/share/zabbix/local/app/views \
	&& mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi \
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
