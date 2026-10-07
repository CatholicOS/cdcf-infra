#!/usr/bin/env bash
set -euo pipefail

expected_ip='172.31.250.10'

compose() {
  docker compose "$@"
}

fail() {
  echo "[verify] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[verify] OK: $*"
}

actual_ip="$(compose exec -T db-verifier getent ahostsv4 host.docker.internal | awk 'NR == 1 { print $1 }')"
[[ "${actual_ip}" == "${expected_ip}" ]] \
  || fail "host.docker.internal resolved to ${actual_ip:-nothing}, expected ${expected_ip}"
pass "host.docker.internal resolves to ${expected_ip} from the verifier container"

zitadel_result="$(compose exec -T db-verifier bash -ec \
  'PGPASSWORD="$PGPASSWORD_ZITADEL" exec psql "$@"' _ \
  --host host.docker.internal --username zitadel --dbname zitadel \
  --tuples-only --no-align \
  --command "SELECT current_user || '|' || current_database() || '|' || inet_client_addr();")"
[[ "${zitadel_result}" == zitadel\|zitadel\|172.31.250.* ]] \
  || fail "unexpected Zitadel connection result: ${zitadel_result}"
pass "Zitadel role connects to the zitadel database over the simulation network"

openfga_result="$(compose exec -T db-verifier bash -ec \
  'PGPASSWORD="$PGPASSWORD_OPENFGA" exec psql "$@"' _ \
  --host host.docker.internal --username openfga --dbname openfga \
  --tuples-only --no-align \
  --command "SELECT current_user || '|' || current_database() || '|' || inet_client_addr();")"
[[ "${openfga_result}" == openfga\|openfga\|172.31.250.* ]] \
  || fail "unexpected OpenFGA connection result: ${openfga_result}"
pass "OpenFGA role connects to the openfga database over the simulation network"

scram_roles="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_authid WHERE rolname IN ('zitadel', 'openfga') AND rolpassword LIKE 'SCRAM-SHA-256$%';")"
[[ "${scram_roles}" == '2' ]] || fail "expected two SCRAM role passwords, found ${scram_roles}"
pass "both application role passwords are stored as SCRAM-SHA-256"

layout="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SHOW data_directory;")"
[[ "${layout}" == '/var/lib/postgresql/16/main' ]] \
  || fail "unexpected data_directory: ${layout}"
pass "PostgreSQL uses the Ubuntu 16/main data layout"

config_file="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command 'SHOW config_file;')"
[[ "${config_file}" == '/etc/postgresql/16/main/postgresql.conf' ]] \
  || fail "unexpected config_file: ${config_file}"
pass "PostgreSQL uses /etc/postgresql/16/main/postgresql.conf"

hba_file="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command 'SHOW hba_file;')"
[[ "${hba_file}" == '/etc/postgresql/16/main/pg_hba.conf' ]] \
  || fail "unexpected hba_file: ${hba_file}"
pass "PostgreSQL uses /etc/postgresql/16/main/pg_hba.conf"

password_encryption="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command 'SHOW password_encryption;')"
[[ "${password_encryption}" == 'scram-sha-256' ]] \
  || fail "unexpected password_encryption: ${password_encryption}"
pass "password_encryption is scram-sha-256"

listen_addresses="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command 'SHOW listen_addresses;')"
[[ "${listen_addresses}" == '*' ]] \
  || fail "unexpected listen_addresses: ${listen_addresses}"
pass "listen_addresses is *"

hba_errors="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;")"
[[ "${hba_errors}" == '0' ]] || fail "pg_hba.conf contains ${hba_errors} parse error(s)"
pass "pg_hba.conf parses without errors"

restricted_hba_rules="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND address = '172.31.250.0' AND netmask = '255.255.255.0' AND auth_method = 'scram-sha-256';")"
[[ "${restricted_hba_rules}" == '3' ]] \
  || fail "expected three restricted SCRAM application rules, found ${restricted_hba_rules}"
pass "pg_hba.conf contains the three expected SCRAM rules limited to 172.31.250.0/24"

zitadel_hba_rule="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND database = ARRAY['zitadel'] AND user_name = ARRAY['zitadel'] AND address = '172.31.250.0' AND netmask = '255.255.255.0' AND auth_method = 'scram-sha-256';")"
[[ "${zitadel_hba_rule}" == '1' ]] || fail "the exact zitadel/zitadel HBA rule is missing or duplicated"
pass "pg_hba.conf contains the exact zitadel/zitadel SCRAM rule"

openfga_hba_rule="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND database = ARRAY['openfga'] AND user_name = ARRAY['openfga'] AND address = '172.31.250.0' AND netmask = '255.255.255.0' AND auth_method = 'scram-sha-256';")"
[[ "${openfga_hba_rule}" == '1' ]] || fail "the exact openfga/openfga HBA rule is missing or duplicated"
pass "pg_hba.conf contains the exact openfga/openfga SCRAM rule"

zitadel_probe_hba_rule="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND database = ARRAY['postgres'] AND user_name = ARRAY['zitadel'] AND address = '172.31.250.0' AND netmask = '255.255.255.0' AND auth_method = 'scram-sha-256';")"
[[ "${zitadel_probe_hba_rule}" == '1' ]] || fail "the exact postgres/zitadel HBA rule is missing or duplicated"
pass "pg_hba.conf contains the exact postgres/zitadel SCRAM probe rule"

unsafe_hba_rules="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_hba_file_rules WHERE type = 'host' AND address = '0.0.0.0' AND netmask = '0.0.0.0';")"
[[ "${unsafe_hba_rules}" == '0' ]] || fail "pg_hba.conf contains a global IPv4 rule"
pass "pg_hba.conf contains no 0.0.0.0/0 rule"

encoding="$(compose exec -T postgres-host \
  runuser -u postgres -- psql --dbname postgres --tuples-only --no-align \
  --command 'SHOW server_encoding;')"
[[ "${encoding}" == 'UTF8' ]] || fail "unexpected server encoding: ${encoding}"
pass "the cluster encoding is UTF8"

echo '[verify] All production-host simulation checks passed.'
