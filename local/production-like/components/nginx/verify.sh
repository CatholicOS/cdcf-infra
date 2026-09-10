#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

ok() {
    printf '%s\n' "[verify] OK: $*"
}

fail() {
    printf '%s\n' "[verify] FAIL: $*" >&2
    exit 1
}

discovery_file="$(mktemp)"

cleanup() {
    rm -f "$discovery_file"
}
trap cleanup EXIT

NETWORK=cdcf-auth-test_default
SOURCE_CONFIG=/etc/nginx/production/zitadel.conf
RUNTIME_CONFIG=/etc/nginx/conf.d/default.conf

docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || fail "auth network $NETWORK does not exist; start local/dev first"
ok "auth network $NETWORK exists"

container_id=$(docker compose ps --quiet nginx-host)
[ -n "$container_id" ] || fail 'nginx-host container does not exist'
[ "$(docker inspect --format '{{.State.Status}}' "$container_id")" = running ] \
    || fail 'nginx-host is not running'
ok 'nginx-host is running'

health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$container_id")
[ "$health" = healthy ] || fail "nginx-host health status is $health"
ok 'nginx-host is healthy'

docker compose exec -T nginx-host nginx -t >/dev/null 2>&1 \
    || fail 'nginx -t failed'
ok 'nginx -t succeeds'

docker compose exec -T nginx-host test -f "$SOURCE_CONFIG" \
    || fail 'production source is missing in nginx-host'
docker compose exec -T nginx-host test -f "$RUNTIME_CONFIG" \
    || fail 'runtime configuration is missing'
ok 'production source and runtime configuration are present'

mount_rw=$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/production/zitadel.conf"}}{{.RW}}{{end}}{{end}}' "$container_id")
[ "$mount_rw" = false ] || fail 'production nginx configuration mount is not read-only'
ok 'production nginx configuration is mounted read-only'

docker compose exec -T nginx-host getent hosts zitadel >/dev/null 2>&1 \
    || fail 'Docker DNS cannot resolve zitadel'
docker compose exec -T nginx-host getent hosts zitadel-login >/dev/null 2>&1 \
    || fail 'Docker DNS cannot resolve required zitadel-login'
ok 'Docker DNS resolves zitadel and zitadel-login'

docker compose exec -T nginx-host curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    http://zitadel:8080/debug/ready >/dev/null \
    || fail 'Zitadel is not reachable from nginx-host'
docker compose exec -T nginx-host curl --fail --silent --show-error \
    --connect-timeout 5 --max-time 15 \
    http://zitadel-login:3000/ui/v2/login/healthy >/dev/null \
    || fail 'Zitadel Login V2 is not reachable from nginx-host'
ok 'real Zitadel and Zitadel Login V2 services are reachable from nginx-host'

assert_runtime_count() {
    expected_count=$1
    directive=$2
    actual_count=$(docker compose exec -T nginx-host grep -F -c "$directive" "$RUNTIME_CONFIG" || true)
    [ "$actual_count" -eq "$expected_count" ] \
        || fail "expected $expected_count occurrence(s) of '$directive', found $actual_count"
}

assert_runtime_count 2 'proxy_set_header Host $http_host;'
assert_runtime_count 2 'proxy_set_header X-Forwarded-Host $http_host;'
assert_runtime_count 2 'proxy_set_header X-Forwarded-Proto http;'
ok 'shared Host handling and local forwarded protocol are exact'

docker compose exec -T nginx-host grep -F 'Content-Security-Policy' "$RUNTIME_CONFIG" >/dev/null \
    || fail 'production CSP is missing from runtime configuration'
ok 'production CSP is preserved'

curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    http://127.0.0.1:8090/debug/ready >/dev/null \
    || fail 'local nginx readiness route failed'
ok 'GET /debug/ready succeeds through local nginx'

discovery_code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
    --output "$discovery_file" --write-out '%{http_code}' \
    -H 'Host: localhost:8090' \
    http://127.0.0.1:8090/.well-known/openid-configuration) \
    || fail 'OIDC discovery request failed'
[ "$discovery_code" = 200 ] \
    || fail "OIDC discovery returned HTTP $discovery_code instead of 200"

expected_issuer=http://localhost:8090
actual_issuer=$(sed -n 's/.*"issuer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$discovery_file" | head -n 1)
[ -n "$actual_issuer" ] \
    || fail 'OIDC discovery response does not contain a readable issuer'
[ "$actual_issuer" = "$expected_issuer" ] \
    || fail "unexpected OIDC issuer: $actual_issuer, expected $expected_issuer"
ok "OIDC issuer is $actual_issuer"
ok 'real OIDC discovery route succeeds through nginx and Zitadel'

console_code=$(curl --silent --show-error --connect-timeout 5 --max-time 15 \
    --output /dev/null --write-out '%{http_code}' \
    -H 'Host: localhost:8090' \
    http://127.0.0.1:8090/ui/console/) \
    || fail 'admin console request failed'
case "$console_code" in
    2??|3??) ok "GET /ui/console/ returned expected HTTP $console_code" ;;
    *) fail "GET /ui/console/ returned unexpected HTTP $console_code" ;;
esac

ok 'all nginx simulation checks passed'
