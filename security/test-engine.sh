#!/usr/bin/env bash
set -euo pipefail

image=${1:?Usage: security/test-engine.sh LOCAL_IMAGE}
id=$(docker image inspect --format '{{.Id}}' "$image")
docker run --rm -i --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev \
    --security-opt no-new-privileges --entrypoint /bin/sh "$id" -eu <<'CONTAINER'
cd /tmp
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -keyout key.pem -out cert.pem 2>/dev/null
cat > nginx.conf <<'NGINX'
user nobody nogroup;
worker_processes 1;
pid /tmp/nginx.pid;
error_log stderr warn;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path /tmp/client;
    proxy_temp_path /tmp/proxy;
    fastcgi_temp_path /tmp/fastcgi;
    uwsgi_temp_path /tmp/uwsgi;
    scgi_temp_path /tmp/scgi;
    server {
        listen 127.0.0.1:8443 ssl;
        http2 on;
        ssl_protocols TLSv1.3;
        ssl_certificate /tmp/cert.pem;
        ssl_certificate_key /tmp/key.pem;
        location / {
            content_by_lua_block {
                require "resty.core"
                ngx.say("openresty-ok")
            }
        }
    }
}
NGINX
nginx -p /tmp/ -c /tmp/nginx.conf -e stderr -t
nginx -p /tmp/ -c /tmp/nginx.conf -e stderr
trap 'nginx -p /tmp/ -c /tmp/nginx.conf -e stderr -s quit' EXIT
for protocol in 1.1 2; do
    received=$(curl -fsS "--http${protocol}" --noproxy '*' --tlsv1.3 --cacert cert.pem \
        --resolve localhost:8443:127.0.0.1 --connect-timeout 2 --max-time 6 \
        --retry 3 --retry-connrefused -o response -w '%{http_version} %{http_code}' https://localhost:8443/)
    test "$received" = "$protocol 200"
    test "$(cat response)" = openresty-ok
    printf 'PASS TLS 1.3 + HTTP/%s + Lua\n' "$protocol"
done
CONTAINER
