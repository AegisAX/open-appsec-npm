#!/usr/bin/env bash
# Validate the OpenResty modules in a local candidate image.
set -euo pipefail
if [[ $# != 1 || -z $1 || $1 == -* ]]; then
    echo "Usage: $0 LOCAL_IMAGE" >&2
    exit 2
fi

docker run --rm --pull never --network none --ipc private --user 0:0 \
    --entrypoint /bin/sh -i "$1" -eu -s <<'CONTAINER'
# Normal NPM initialization creates these paths. This test bypasses its entrypoint.
mkdir -p /tmp/aegis-modules/logs /var/log/nginx /var/cache/nginx
cat > /tmp/aegis-modules/nginx.conf <<'NGINX'
user root;
error_log stderr;
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
load_module /usr/lib/nginx/modules/ngx_stream_geoip2_module.so;
load_module /usr/lib/nginx/modules/libngx_module.so;
events {}
stream {}
http {
    cp_worker_processes auto;
    server {
        listen 127.0.0.1:8080;
        location / {
            waf_tag module-compile-test;
            content_by_lua_block { ngx.say("module-test") }
        }
    }
}
NGINX
LD_BIND_NOW=1 nginx -t -p /tmp/aegis-modules/ -c /tmp/aegis-modules/nginx.conf
CONTAINER
