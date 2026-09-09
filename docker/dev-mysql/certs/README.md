# dev-mysql TLS certificates (dev-only, intentionally committed)

These files are a purpose-built CA + server certificate for the `zabbix-dev-mysql` verification
database only [FR6.2]. They exist because `zabbix_server`'s mariadb-connector-c build never skips
TLS certificate verification (see `test-results.md` in the build-and-test stage record for the full
investigation) — MySQL 8.4's own auto-generated self-signed certificate fails both the certificate-chain
check and, once that's fixed by trusting the CA, the separate hostname check (its CN doesn't match
`zabbix-dev-mysql`). These files are generated once, matching that fixed container name, so both
`dev-mysql` (via `--ssl-ca`/`--ssl-cert`/`--ssl-key` in `compose.yml`) and `zabbix-server` (via
`TRUST_DB_CA_FILE`, trusted at the OS level in `entrypoint.sh`) agree on the same identity.

**The private key (`server-key.pem`, `ca-key.pem`) is committed on purpose.** This secures a throwaway,
never-in-production local verification database that already ships default weak credentials
(`zabbix`/`zabbix`) — the key protects nothing of real value, and requiring every clone to regenerate
certs before `podman compose --profile dev up` would just be friction for a dev convenience feature.
Never reuse these files, or generate them the same way, for anything that isn't disposable.

## Regenerating (only needed if the container_name changes)

```bash
cd docker/dev-mysql/certs
openssl req -x509 -newkey rsa:2048 -days 36500 -nodes -keyout ca-key.pem -out ca.pem \
	-subj "/CN=Zabbix PHP8 Migration Dev CA"
openssl req -newkey rsa:2048 -nodes -keyout server-key.pem -out server-req.pem \
	-subj "/CN=zabbix-dev-mysql"
printf 'subjectAltName = DNS:zabbix-dev-mysql,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage = serverAuth\n' > server-ext.cnf
openssl x509 -req -in server-req.pem -days 36500 -CA ca.pem -CAkey ca-key.pem -CAcreateserial \
	-out server-cert.pem -extfile server-ext.cnf
rm server-req.pem server-ext.cnf ca.srl
```
