#!/bin/sh
set -eu

# Sources and hashes are fixed as one release set. A changed download stops the build.
fetch() {
    curl -fsSL --retry 3 "$1" -o "$2"
    printf '%s  %s\n' "$3" "$2" | sha256sum -c -
}

mkdir -p /src/openresty /src/geoip2
cd /src
fetch https://openresty.org/download/openresty-1.31.8.1.tar.gz openresty.tgz \
    b569c63b420f80a4ac8466f2deffe73ed93ab760026532e039c3658409a997f4
fetch https://codeload.github.com/leev/ngx_http_geoip2_module/tar.gz/445df24ef3781e488cee3dfe8a1e111997fc1dfe geoip2.tgz \
    5e2113ed09cdd710908df8c6d1630616eeacb9216ef8705a06c25733394ddf28
fetch https://github.com/nginx/nginx/compare/140aa942711868a8daeb95810bc9a81f272ada72...c2c44702c2fbc572e4cfb0a52331061d7fcaca16.diff nginx-1.31.9.diff \
    b558e870b82621bc6a4edc665a55bfa2ec0073b5884abcb14864a5802edf6ed7
tar -xzf openresty.tgz --strip-components=1 -C openresty
tar -xzf geoip2.tgz --strip-components=1 -C geoip2

# Apply every upstream source change, preserving OpenResty's version and ABI identifiers.
cd openresty/bundle/nginx-1.31.8
git apply --exclude=src/core/nginx.h --include='src/*' /src/nginx-1.31.9.diff
cd /src/openresty
./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx --group=nginx --with-compat --with-threads \
    --with-http_addition_module --with-http_auth_request_module --with-http_dav_module \
    --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module \
    --with-http_mp4_module --with-http_random_index_module --with-http_realip_module \
    --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module \
    --with-http_stub_status_module --with-http_sub_module --with-http_v2_module \
    --with-mail --with-mail_ssl_module --with-stream --with-stream_realip_module \
    --with-stream_ssl_module --with-stream_ssl_preread_module \
    --add-dynamic-module=/src/geoip2 --build=aegis-nginx-core-1.31.9
make -j2
make install DESTDIR=/stage
mkdir -p /out/etc/nginx /out/usr/sbin /out/usr/lib/nginx/modules
cp -a /stage/etc/nginx/luajit /stage/etc/nginx/lualib /out/etc/nginx/
cp -a /stage/usr/sbin/nginx /out/usr/sbin/
cp -a /stage/usr/lib/nginx/modules/ngx_http_geoip2_module.so /stage/usr/lib/nginx/modules/ngx_stream_geoip2_module.so /out/usr/lib/nginx/modules/
cp -a /stage/etc/nginx/bin /out/etc/nginx/
install -Dm644 /src/openresty/COPYRIGHT /out/usr/share/doc/aegis-openresty/COPYRIGHT
install -Dm644 /src/openresty/bundle/nginx-1.31.8/LICENSE /out/usr/share/doc/aegis-openresty/NGINX-LICENSE
install -Dm644 /src/geoip2/LICENSE /out/usr/share/doc/aegis-openresty/GeoIP2-LICENSE
