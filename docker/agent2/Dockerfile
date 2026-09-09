# Zabbix agent2 — Alpine 3.24, built from the existing (unmodified) sources/zabbix-5.0.47/src/go Go
# sources [FR5.1]. This migration does not change zabbix_agent2's Go code — only its build/runtime
# container. The go.mod's "go 1.19" is a minimum-compatibility floor, not a pin — Alpine 3.24's `go`
# package (whatever recent version that is) builds this module fine as a newer, backward-compatible
# toolchain.
#
# Build context is the repository root (see compose.yml).

FROM alpine:3.24 AS builder

# build-and-test found that `go build ./cmd/zabbix_agent2` in isolation fails: pkg/tls and pkg/zbxlib
# cgo-include C headers (config.h, common.h) and link against static libs (libzbxcommon.a, libzbxcrypto.a,
# etc.) that only exist after the project's own top-level `./configure && make` runs — agent2 is NOT a
# self-contained Go module, it is cgo-bridged into the same C codebase the server binary is built from.
# src/go/Makefile.am confirms this: its `build` target runs
# `CGO_CFLAGS="${CGO_CFLAGS}" CGO_LDFLAGS="${CGO_LDFLAGS}" go build ...`, where those two Makefile
# variables are populated by `./configure`'s autoconf substitution — so `sh ./configure --enable-agent2`
# followed by `make` in src/go/ (using ITS generated Makefile, not a bare `go build`) is the actually
# correct build path, not an invention.
RUN apk add --no-cache go build-base git autoconf automake libtool pcre-dev openssl-dev zlib-dev

WORKDIR /build
COPY sources/zabbix-5.0.47/ /build/

RUN sh ./configure --disable-dependency-tracking --enable-agent2 --with-openssl

# go-sqlite3 (a transitive plugin dependency of zabbix_agent2 itself, not excluded by targeting only
# ./cmd/zabbix_agent2) uses glibc-only pread64/pwrite64/off64_t symbol names that musl's headers do not
# expose under that name by default; -D_LARGEFILE64_SOURCE is the standard, widely-used fix that makes
# musl provide those aliases (the same flag Alpine's own php83/mysql-client packages rely on internally
# for large-file support).
#
# build-and-test found that `make -C src/go build` in isolation fails: the top-level `make` (unqualified)
# builds src/libs/*'s static .a files FIRST and only then descends into src/go, in that dependency
# order — invoking src/go's Makefile target directly skips the C library build entirely, so the linker
# can't find any of the .a files CGO_LDFLAGS points at. The plain top-level `make` is required; passing
# CGO_CFLAGS as a `make` command-line variable (not an `ENV`) is required too, confirmed by testing —
# Makefile.in's own `CGO_CFLAGS = @CGO_CFLAGS@` assignment overrides an inherited environment value, but
# a command-line `make VAR=...` override always wins and correctly propagates into the src/go sub-make.
RUN make -j"$(nproc)" CGO_CFLAGS="-I/build/include -D_LARGEFILE64_SOURCE" \
	&& cp src/go/bin/zabbix_agent2 /build/bin/zabbix_agent2

FROM alpine:3.24

# zabbix_agent2 links against these as shared libraries (-lssl -lcrypto -lz -lpcre in the build stage's
# link command); the runtime image needs their .so runtime packages, not just the builder's *-dev ones.
RUN apk add --no-cache ca-certificates tzdata openssl libcrypto3 zlib pcre

# UID/GID 1997 (not 101) — build-and-test found 101 collides with nginx's own group in the web image;
# kept consistent across all three images even though this one doesn't install nginx.
RUN addgroup -g 1997 -S zabbix \
	&& adduser -D -S -H -u 1997 -G zabbix -s /sbin/nologin zabbix

COPY --from=builder /build/bin/zabbix_agent2 /usr/sbin/zabbix_agent2

RUN mkdir -p /etc/zabbix /var/lib/zabbix/enc /run/zabbix \
	&& chown -R zabbix:zabbix /etc/zabbix /var/lib/zabbix /run/zabbix

COPY docker/agent2/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/zabbix/enc"]

USER zabbix
EXPOSE 10050

# Process-liveness health check via the PID file entrypoint.sh configures
# [reliability-design.md / monitoring-design.md — agent2: プロセス生存確認].
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
	CMD test -f /run/zabbix/zabbix_agent2.pid && kill -0 "$(cat /run/zabbix/zabbix_agent2.pid)" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
