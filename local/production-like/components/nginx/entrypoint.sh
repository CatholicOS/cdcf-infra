#!/bin/sh
set -eu

SOURCE_CONFIG=/etc/nginx/production/zitadel.conf
RUNTIME_CONFIG=/etc/nginx/conf.d/default.conf

fail() {
    printf '%s\n' "ERROR: $*" >&2
    exit 1
}

assert_count() {
    expected_count=$1
    directive=$2
    actual_count=$(grep -F -c "$directive" "$SOURCE_CONFIG" || true)

    if [ "$actual_count" -ne "$expected_count" ]; then
        fail "production nginx configuration changed.
Expected exactly ${expected_count} occurrence(s) of:
${directive}
Found: ${actual_count}

Review local/production-like/components/nginx before continuing."
    fi
}

[ -f "$SOURCE_CONFIG" ] || fail "production nginx configuration is missing: $SOURCE_CONFIG"
: "${NGINX_FORWARDED_PROTO:?NGINX_FORWARDED_PROTO is required}"

# The shared source must remain environment-neutral and preserve the client Host
# header, including its local port. Only the forwarded protocol is substituted.
assert_count 2 'proxy_set_header Host $http_host;'
assert_count 2 'proxy_set_header X-Forwarded-Host $http_host;'
assert_count 2 'proxy_set_header X-Forwarded-Proto ${NGINX_FORWARDED_PROTO};'

case "$NGINX_FORWARDED_PROTO" in
    http|https) ;;
    *) fail 'NGINX_FORWARDED_PROTO must be either http or https' ;;
esac

# Pass an explicit variable list so envsubst never expands native nginx
# variables such as $http_host, $remote_addr, or $proxy_add_x_forwarded_for.
envsubst '${NGINX_FORWARDED_PROTO}' < "$SOURCE_CONFIG" > "$RUNTIME_CONFIG"

nginx -t
printf '%s\n' '[nginx-simulation] Configuration validated; starting nginx.'
exec nginx -g 'daemon off;'
