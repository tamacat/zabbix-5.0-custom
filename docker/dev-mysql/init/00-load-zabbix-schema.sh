#!/bin/sh
# Loads the existing, unmodified Zabbix 5.0.47 MySQL schema/data into the verification/dev database
# [FR6.2][code-generation-plan.md Step 4.9].
#
# This does NOT duplicate sources/zabbix-5.0.47/database/mysql/*.sql into docker/ — compose.yml
# bind-mounts that directory read-only into this dev-mysql container at /zabbix-schema-src, and this
# script (itself picked up by the official mysql image's /docker-entrypoint-initdb.d/ convention, which
# runs *.sh files it finds there) applies the four files in the exact order Zabbix's own install docs
# require: schema.sql (DDL) must run before images.sql/data.sql (they INSERT into those tables), and
# double.sql (the optional IEEE754 numeric-range migration) runs last. Alphabetical order would run
# data.sql before schema.sql and break the load, which is exactly why this script exists instead of
# relying on the init mechanism's default filename-sort behavior for the four files directly.

set -eu

SRC_DIR="/zabbix-schema-src"

echo "**** Loading Zabbix 5.0.47 MySQL schema into '${MYSQL_DATABASE}' (dev/verification database)..."

for f in schema.sql images.sql data.sql double.sql; do
	if [ ! -f "${SRC_DIR}/${f}" ]; then
		echo "**** ERROR: ${SRC_DIR}/${f} not found (expected the sources/zabbix-5.0.47/database/mysql/ bind mount)." >&2
		exit 1
	fi

	echo "**** Applying ${f}..."
	mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "${SRC_DIR}/${f}"
done

# build-and-test found the built-in "Zabbix server" host's pre-seeded agent interface (data.sql) points
# at DNS name "zabbix-server" — correct for the traditional same-host server+agent deployment
# schema.sql/data.sql assume, but wrong for this project's split-container topology, where the agent
# actually runs in the separate zabbix-agent2 container. Without this, the server tries to poll itself
# for the agent check and the Web UI shows "Zabbix agent is not available" indefinitely. Real production
# MySQL needs this same one-time fix (or the operator's own equivalent) for whatever their actual agent
# host/interface topology is — this script only handles the dev/verification database.
echo "**** Pointing the built-in 'Zabbix server' host's agent interface at the zabbix-agent2 container..."
mysql --user=root --password="${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" <<'SQL'
UPDATE interface i JOIN hosts h ON h.hostid = i.hostid
SET i.dns = 'zabbix-agent2'
WHERE h.host = 'Zabbix server' AND i.type = 1;
SQL

echo "**** Zabbix schema load complete."
