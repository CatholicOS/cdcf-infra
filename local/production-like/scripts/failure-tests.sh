#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

pass() { echo "[failure-test] OK: $*"; }
fail() { echo "[failure-test] FAIL: $*" >&2; exit 1; }

restore_stack() {
  docker compose up -d --wait >/dev/null
}
trap restore_stack EXIT

migrate_id="$(docker compose ps --all --quiet openfga-migrate)"
[[ -n "$migrate_id" ]] \
  || fail 'openfga-migrate baseline container does not exist'

[[ "$(docker inspect --format '{{.State.ExitCode}}' "$migrate_id")" == 0 ]] \
  || fail 'OpenFGA migration baseline was not successful'

docker compose stop postgres-host >/dev/null

postgres_id="$(docker compose ps --all --quiet postgres-host)"
[[ -n "$postgres_id" ]] \
  || fail 'postgres-host container does not exist'

[[ "$(docker inspect --format '{{.State.Status}}' "$postgres_id")" != running ]] \
  || fail 'postgres-host is still running after docker compose stop'

if timeout 15s docker compose run --rm --no-deps \
  openfga-migrate migrate --timeout 10s >/dev/null 2>&1; then
  fail 'OpenFGA unexpectedly migrated while postgres-host was stopped'
else
  migrate_status=$?
fi

[[ "$migrate_status" -ne 124 ]] \
  || fail 'OpenFGA migration hit the outer 15s timeout while postgres-host was stopped'

pass 'OpenFGA database operation fails when confirmed PostgreSQL is unavailable'
docker compose up -d --wait postgres-host >/dev/null

docker compose stop zitadel-login >/dev/null
login_code="$(curl --connect-timeout 5 --max-time 15 --silent --show-error \
  --output /dev/null --write-out '%{http_code}' \
  -H 'Host: localhost:8090' \
  http://127.0.0.1:8090/ui/v2/login/healthy || true)"
[[ "$login_code" == 000 || "$login_code" == 502 || "$login_code" == 503 || "$login_code" == 504 ]] \
  || fail "Login V2 outage returned HTTP $login_code, expected timeout or proxy 502/503/504"

backend_code="$(curl --connect-timeout 5 --max-time 15 --silent --show-error \
  --output /dev/null --write-out '%{http_code}' \
  http://127.0.0.1:8090/debug/ready || true)"
[[ "$backend_code" == 200 ]] \
  || fail "Zitadel backend route returned HTTP $backend_code while Login V2 was stopped"

pass 'Login V2 outage is isolated while Zitadel backend routing remains available'

restore_stack
trap - EXIT
./scripts/verify.sh
pass 'stack recovered and all integration checks pass'