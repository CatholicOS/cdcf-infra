#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

readonly expected_database_ip='172.31.250.10'
readonly expected_issuer='http://localhost:8090'
readonly openfga_key="${OPENFGA_PRESHARED_KEY:-local-openfga-api-key}"

tmp_files=()

compose() {
  docker compose "$@"
}

db_query() {
  docker compose -f ../postgres/compose.yaml exec -T postgres-host \
    runuser -u postgres -- psql --dbname zitadel --tuples-only --no-align \
    --command "$1"
}

fail() {
  echo "[verify] FAIL: $*" >&2
  exit 1
}

pass() {
  echo "[verify] OK: $*"
}

cleanup() {
  local file
  for file in "${tmp_files[@]}"; do
    rm -f "$file"
  done
}
trap cleanup EXIT

assert_running() {
  local service=$1 container_id status
  container_id="$(compose ps --quiet "$service")"
  [[ -n "$container_id" ]] || fail "$service container does not exist"
  status="$(docker inspect --format '{{.State.Status}}' "$container_id")"
  [[ "$status" == running ]] || fail "$service is $status, expected running"
  pass "$service is running"
}

assert_healthy() {
  local service=$1 container_id health
  container_id="$(compose ps --quiet "$service")"
  health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_id")"
  [[ "$health" == healthy ]] || fail "$service health is $health"
  pass "$service is healthy"
}

docker network inspect cdcf-production-simulation_production-simulation >/dev/null 2>&1 \
  || fail 'PostgreSQL simulation network is missing; start local/production-like/components/postgres first'
docker network inspect cdcf-application-simulation >/dev/null 2>&1 \
  || fail 'application network is missing'
pass 'database and application networks exist'

assert_running zitadel
assert_healthy zitadel
compose exec -T zitadel /app/zitadel ready >/dev/null \
  || fail '/app/zitadel ready failed'
pass 'Zitadel exec readiness probe succeeds'

resolved_database_ip="$(docker inspect \
  --format '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$(compose ps --quiet zitadel)" \
  | sed -n 's/^host\.docker\.internal://p')"
[[ "$resolved_database_ip" == "$expected_database_ip" ]] \
  || fail "Zitadel database host mapping is ${resolved_database_ip:-missing}, expected $expected_database_ip"
pass "Zitadel maps host.docker.internal to $expected_database_ip"

issuer_response="$(curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
  -H 'Host: localhost:8090' \
  http://127.0.0.1:18080/.well-known/openid-configuration)" \
  || fail 'Zitadel OIDC discovery request failed'
actual_issuer="$(sed -n 's/.*"issuer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$issuer_response")"
[[ "$actual_issuer" == "$expected_issuer" ]] \
  || fail "unexpected Zitadel issuer: ${actual_issuer:-missing}, expected $expected_issuer"
pass "Zitadel external issuer is $expected_issuer"

persisted_domain_policy="$(db_query \
  "SELECT CASE WHEN user_login_must_be_domain THEN 'true' ELSE 'false' END FROM projections.domain_policies2 WHERE is_default AND NOT owner_removed;")"
[[ "$persisted_domain_policy" == false ]] \
  || fail "persisted UserLoginMustBeDomain is ${persisted_domain_policy:-missing}, expected false"
pass 'persisted Zitadel domain policy has UserLoginMustBeDomain=false'

bootstrap_identity="$(db_query \
  "SELECT u.username || '|' || h.email || '|' || h.is_email_verified::text FROM projections.users14 u JOIN projections.users14_humans h ON h.user_id = u.id AND h.instance_id = u.instance_id WHERE h.email = 'admin@example.test';")"
[[ "$bootstrap_identity" == 'local-admin@zitadel.localhost|admin@example.test|true' ]] \
  || fail "unexpected persisted bootstrap identity: ${bootstrap_identity:-missing}"
actual_bootstrap_login="${bootstrap_identity%%|*}"
pass "bootstrap human is persisted with verified email and login $actual_bootstrap_login"

compose exec -T zitadel-login node -e \
  "const fs=require('fs'); const p='/zitadel-data/login-client.pat'; if (!fs.statSync(p).isFile() || fs.statSync(p).size === 0) process.exit(1)" \
  || fail 'zitadel-login cannot read login-client.pat'
zitadel_mount_rw="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/zitadel-data"}}{{.RW}}{{end}}{{end}}' "$(compose ps --quiet zitadel)")"
login_mount_rw="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/zitadel-data"}}{{.RW}}{{end}}{{end}}' "$(compose ps --quiet zitadel-login)")"
[[ "$zitadel_mount_rw" == true && "$login_mount_rw" == false ]] \
  || fail "unexpected PAT mount modes: zitadel RW=$zitadel_mount_rw, zitadel-login RW=$login_mount_rw"
pass 'Login V2 PAT exists and is readable through the read-only consumer mount'

login_pat="$(compose exec -T zitadel-login node -e \
  "process.stdout.write(require('fs').readFileSync('/zitadel-data/login-client.pat','utf8').trim())")"
login_local_admin_tmp="$(mktemp)"
tmp_files+=("$login_local_admin_tmp")
login_email_tmp="$(mktemp)"
tmp_files+=("$login_email_tmp")
login_actual_tmp="$(mktemp)"
tmp_files+=("$login_actual_tmp")

try_login() {
  local login_name=$1 output_file=$2
  curl --silent --show-error --connect-timeout 5 --max-time 15 \
    --output "$output_file" --write-out '%{http_code}' \
    -H 'Host: localhost:8090' \
    -H "Authorization: Bearer $login_pat" \
    -H 'Content-Type: application/json' \
    -X POST http://127.0.0.1:18080/v2/sessions \
    --data "{\"checks\":{\"user\":{\"loginName\":\"$login_name\"},\"password\":{\"password\":\"LocalTest1!\"}}}"
}

local_admin_code="$(try_login local-admin "$login_local_admin_tmp")" \
  || fail 'bootstrap login request for local-admin failed'
email_code="$(try_login admin@example.test "$login_email_tmp")" \
  || fail 'bootstrap login request for admin@example.test failed'
actual_login_code="$(try_login "$actual_bootstrap_login" "$login_actual_tmp")" \
  || fail "bootstrap login request for $actual_bootstrap_login failed"

[[ "$local_admin_code" == 404 && "$email_code" == 404 ]] \
  || fail "unexpected bootstrap aliases: local-admin HTTP $local_admin_code, email HTTP $email_code; expected both 404"
[[ "$actual_login_code" == 201 ]] \
  || fail "actual bootstrap login $actual_bootstrap_login returned HTTP $actual_login_code, expected 201"
grep -F '"sessionToken"' "$login_actual_tmp" >/dev/null \
  || fail 'successful bootstrap login response contains no session token'
pass "Zitadel v4.15.0 accepts $actual_bootstrap_login; local-admin and admin@example.test are not login names"

assert_running zitadel-login
assert_healthy zitadel-login
compose exec -T zitadel-login node /app/healthcheck.mjs \
  http://localhost:3000/ui/v2/login/healthy >/dev/null \
  || fail 'Login V2 image-native healthcheck failed'
pass 'Login V2 image-native healthcheck succeeds after Zitadel is healthy'

migrate_id="$(compose ps --all --quiet openfga-migrate)"
[[ -n "$migrate_id" ]] || fail 'openfga-migrate container does not exist'
migrate_exit="$(docker inspect --format '{{.State.ExitCode}}' "$migrate_id")"
[[ "$migrate_exit" == 0 ]] || fail "OpenFGA migration exited with code $migrate_exit"
pass 'OpenFGA migration completed successfully'

assert_running openfga
assert_healthy openfga
compose exec -T openfga /usr/local/bin/grpc_health_probe -addr=localhost:8081 >/dev/null \
  || fail 'OpenFGA gRPC health probe failed'
pass 'OpenFGA gRPC health probe succeeds'

unauthenticated_code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
  --output /dev/null --write-out '%{http_code}' \
  http://127.0.0.1:18081/stores)" \
  || fail 'OpenFGA unauthenticated request failed'
[[ "$unauthenticated_code" == 401 ]] \
  || fail "OpenFGA unauthenticated request returned HTTP $unauthenticated_code, expected 401"

openfga_tmp="$(mktemp)"
tmp_files+=("$openfga_tmp")
authenticated_code="$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
  --output "$openfga_tmp" --write-out '%{http_code}' \
  -H "Authorization: Bearer $openfga_key" \
  http://127.0.0.1:18081/stores)" \
  || fail 'OpenFGA authenticated request failed'
[[ "$authenticated_code" == 200 ]] \
  || fail "OpenFGA authenticated request returned HTTP $authenticated_code, expected 200"
grep -F '"stores"' "$openfga_tmp" >/dev/null \
  || fail 'OpenFGA authenticated response is not a stores document'
pass 'OpenFGA HTTP API is reachable and preshared authentication is enforced'

echo '[verify] All application simulation checks passed.'