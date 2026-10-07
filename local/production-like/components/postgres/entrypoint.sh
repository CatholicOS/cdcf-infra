#!/usr/bin/env bash
set -euo pipefail

readonly pg_major=16
readonly pg_cluster=main
readonly pg_data="/var/lib/postgresql/${pg_major}/${pg_cluster}"
readonly pg_config="/etc/postgresql/${pg_major}/${pg_cluster}"
readonly simulation_subnet='172.31.250.0/24'

: "${ZITADEL_DB_PASSWORD:?ZITADEL_DB_PASSWORD is required}"
: "${OPENFGA_DB_PASSWORD:?OPENFGA_DB_PASSWORD is required}"

if [[ ! -s "${pg_data}/PG_VERSION" ]]; then
  if [[ -e "${pg_config}/postgresql.conf" ]]; then
    echo "PostgreSQL config exists but the data cluster is missing; reset both simulation volumes." >&2
    exit 1
  fi

  install -d -o postgres -g postgres -m 0700 "${pg_data}"
  install -d -o root -g postgres -m 0750 "${pg_config}"

  pg_createcluster \
    --datadir="${pg_data}" \
    --start-conf=manual \
    "${pg_major}" "${pg_cluster}" \
    -- \
    --auth-local=peer \
    --auth-host=scram-sha-256 \
    --encoding=UTF8

  cat >> "${pg_config}/postgresql.conf" <<'CONF'

# CDCF local production-host simulation
listen_addresses = '*'
password_encryption = 'scram-sha-256'
CONF

  cat >> "${pg_config}/pg_hba.conf" <<HBA

# CDCF local production-host simulation: application network only
host  zitadel  zitadel  ${simulation_subnet}  scram-sha-256
host  openfga  openfga  ${simulation_subnet}  scram-sha-256
# Zitadel start-from-init probes the postgres system database.
host  postgres  zitadel  ${simulation_subnet}  scram-sha-256
HBA

  pg_ctlcluster "${pg_major}" "${pg_cluster}" start

  runuser -u postgres -- psql \
    --dbname postgres \
    --set ON_ERROR_STOP=1 \
    --set zitadel_password="${ZITADEL_DB_PASSWORD}" \
    --set openfga_password="${OPENFGA_DB_PASSWORD}" <<'SQL'
CREATE ROLE zitadel WITH LOGIN CREATEDB PASSWORD :'zitadel_password';
CREATE DATABASE zitadel OWNER zitadel;
CREATE ROLE openfga WITH LOGIN PASSWORD :'openfga_password';
CREATE DATABASE openfga OWNER openfga;
SQL

  pg_ctlcluster "${pg_major}" "${pg_cluster}" stop
elif [[ ! -s "${pg_config}/postgresql.conf" || ! -s "${pg_config}/pg_hba.conf" ]]; then
  echo "PostgreSQL data exists but its Ubuntu cluster config is missing; reset both simulation volumes." >&2
  exit 1
fi

exec pg_ctlcluster "${pg_major}" "${pg_cluster}" start --foreground
