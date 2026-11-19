#!/usr/bin/env bash
set -euo pipefail
if (( $# < 3 || $# > 4 )); then
    echo "Usage: $0 CANDIDATE_IMAGE AGENT_IMAGE DB_IMAGE [BASELINE_IMAGE]" >&2
    exit 2
fi
candidate=$1 agent_image=$2 db_image=$3
for image in "$@"; do docker image inspect "$image" --format '{{.Id}}' >/dev/null; done
agent=
db=
npm=
volumes=()

remove_phase_containers() {
    if [[ -n $npm ]]; then docker rm -fv "$npm" >/dev/null; npm=; fi
    if [[ -n $agent ]]; then docker rm -fv "$agent" >/dev/null; agent=; fi
}
cleanup() {
    local status=$?
    set +e
    if (( status != 0 )); then echo "Isolated smoke test failed (exit $status)" >&2; fi
    remove_phase_containers
    if [[ -n $db ]]; then docker rm -fv "$db" >/dev/null; fi
    for volume in "${volumes[@]}"; do docker volume rm "$volume" >/dev/null; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

wait_for() {
    local description=$1 attempt
    shift
    for ((attempt=1; attempt<=75; attempt++)); do
        if "$@" >/dev/null 2>&1; then return; fi
        sleep 2
    done
    echo "Timed out waiting for $description" >&2
    return 1
}

# Docker generates new volume IDs. Keep only this fixture between phases.
for ((i=0; i<3; i++)); do volumes+=("$(docker volume create)"); done
db=$(docker run --pull never -d --network none \
    -e MYSQL_ROOT_PASSWORD=smoke-root -e MYSQL_PASSWORD=smoke-db \
    -e MYSQL_DATABASE=npm -e MYSQL_USER=npm "$db_image")
wait_for MariaDB docker exec "$db" sh -ec \
    'MYSQL_PWD=$MYSQL_PASSWORD mysql --protocol=TCP -h127.0.0.1 -unpm npm -N -e "SELECT 1"'

start_phase() {
    # All network connections stay within the database container's private loopback.
    # Every phase gets a new agent, logs and IPC namespace.
    agent=$(docker run --pull never -d --network "container:$db" --ipc shareable \
        --mount "type=volume,src=${volumes[0]},dst=/ext/appsec" \
        -e nginxproxymanager=true -e autoPolicyLoad=true "$agent_image" /cp-nano-agent --standalone --no-upgrade)
    npm=$(docker run --pull never -d --network "container:$db" --ipc "container:$agent" \
        --mount "type=volume,src=${volumes[0]},dst=/ext/appsec" \
        --mount "type=volume,src=${volumes[1]},dst=/etc/letsencrypt" \
        --mount "type=volume,src=${volumes[2]},dst=/data" \
        -e DB_MYSQL_HOST=127.0.0.1 -e DB_MYSQL_USER=npm -e DB_MYSQL_PASSWORD=smoke-db \
        -e DB_MYSQL_NAME=npm -e DISABLE_IPV6=true -e IP_RANGES_FETCH_ENABLED=false \
        -e INITIAL_ADMIN_EMAIL=smoke@example.test -e INITIAL_ADMIN_PASSWORD=smoke-test-admin "$1")
    wait_for 'NPM management API' docker exec "$npm" bash -ec \
        'set -o pipefail; curl -fsS --max-time 3 http://127.0.0.1:81/api/ | jq -es "length == 1 and .[0].status == \"OK\""'
    docker exec -d "$npm" node -e \
        "require('node:http').createServer((req,res) => res.end('aegis-smoke ' + req.url)).listen(18989, '127.0.0.1')"
}
create_fixture() {
    docker exec -i "$npm" bash -euo pipefail <<'IN_CONTAINER'
cp /app/templates/local-policy-open-appsec-enabled-for-proxy-host.yaml /ext/appsec/local_policy.yaml
api=http://127.0.0.1:81/api
echo 'Authenticating the fixture administrator' >&2
token=$(curl -fsS --max-time 15 "$api/tokens" -H 'Content-Type: application/json' \
    -d '{"identity":"smoke@example.test","secret":"smoke-test-admin"}' | jq -er .token)
auth="Authorization: Bearer $token"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=smoke.example.test \
    -addext 'subjectAltName=DNS:smoke.example.test' -keyout /tmp/smoke.key -out /data/smoke.crt 2>/dev/null
echo 'Creating the fixture certificate' >&2
cert=$(curl -fsS --max-time 15 -H "$auth" -H 'Content-Type: application/json' \
    -d '{"provider":"other","nice_name":"Smoke TLS"}' "$api/nginx/certificates" | jq -er .id)
echo 'Uploading the fixture certificate' >&2
curl -fsS --max-time 20 -H "$auth" -F 'certificate=@/data/smoke.crt' -F 'certificate_key=@/tmp/smoke.key' \
    "$api/nginx/certificates/$cert/upload" | jq -e 'has("certificate")' >/dev/null
echo 'Registering the TLS proxy host' >&2
curl -fsS --max-time 45 -H "$auth" -H 'Content-Type: application/json' \
    "$api/nginx/proxy-hosts" --data "$(jq -nc --argjson cert "$cert" \
    '{domain_names:["smoke.example.test"], forward_scheme:"http", forward_host:"127.0.0.1",
    forward_port:18989, certificate_id:$cert,http2_support:true, advanced_config:"", locations:[], use_openappsec:true,
    openappsec_mode:"detect-learn", minimum_confidence:"high"}')" | jq -e '.id > 0 and .enabled == true' >/dev/null
IN_CONTAINER
}
check_phase() {
    docker exec "$npm" nginx -t
    docker exec "$npm" nginx -t -g 'load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so; load_module /usr/lib/nginx/modules/ngx_stream_geoip2_module.so;'
    docker exec "$npm" sh -ec 'grep -qF "smoke.example.test" /ext/appsec/local_policy.yaml
        grep -q "/usr/lib/nginx/modules/libngx_module.so" "/proc/$(cat /run/nginx/nginx.pid)/maps"'
    docker exec "$npm" nginx -s reload
    wait_for 'fresh agent attachment registration and HTTP proxy' check_http_and_waf
    docker exec "$npm" bash -ec 'test "$(curl -fsS --max-time 8 --http2 --cacert /data/smoke.crt \
        --resolve smoke.example.test:443:127.0.0.1 -w " %{http_version}" https://smoke.example.test/tls-probe)" = "aegis-smoke /tls-probe 2"'
    docker exec "$db" sh -ec \
        'test "$(MYSQL_PWD=$MYSQL_PASSWORD mysql --protocol=TCP -h127.0.0.1 -unpm npm -N -e "SELECT COUNT(*) FROM proxy_host WHERE enabled=1 AND is_deleted=0")" = 1'
    docker exec "$npm" nginx -v
    echo "Passed $1: NPM, MariaDB, TLS/HTTP2, proxy, reload, GeoIP2, WAF loading and private IPC registration."
}
check_http_and_waf() {
    docker exec "$npm" sh -ec \
        'test "$(curl -fsS --max-time 4 -H "Host: smoke.example.test" http://127.0.0.1/health-probe)" = "aegis-smoke /health-probe"' \
        && docker exec "$agent" sh -ec \
        'grep -qF "Successfully registered attachment" /var/log/nano_agent/cp-nano-http-transaction-handler.dbg*'
}
if (( $# == 4 )); then
    echo "Testing baseline, candidate and rollback against one temporary database and volume set"
    start_phase "$4"; create_fixture; check_phase baseline; remove_phase_containers
    start_phase "$candidate"; check_phase candidate; remove_phase_containers
    start_phase "$4"; check_phase rollback
else
    start_phase "$candidate"; create_fixture; check_phase candidate
fi
