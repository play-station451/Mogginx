FROM node:16-alpine as builder

# build wombat
RUN apk add git python3 make gcc musl-dev libc-dev g++
COPY . /opt/womginx

WORKDIR /opt/womginx
# for whatever reason, heroku doesn't copy the .git folder and the .gitmodules file, so we're
# approaching this assuming they will never exist
RUN rm -rf .git && git init
WORKDIR /opt/womginx/public
RUN rm -rf wombat && git submodule add https://github.com/webrecorder/wombat
WORKDIR /opt/womginx/public/wombat
# wombat's latest version (as of January 4th, 2022; commit 72db794) breaks websocket functionality.
# Locking the version here temporarily until I can find a solution
RUN git checkout 78813ad

RUN npm install --legacy-peer-deps && npm run build-prod

# delete everything but the dist folder to save us an additional 50MB+
RUN mv dist .. && rm -rf * .git && mv ../dist/ .

# modify nginx.conf
WORKDIR /opt/womginx
RUN ./docker-sed.sh

# Build nginx with substitutions module
FROM alpine:3.16 as nginx-builder

# Install build dependencies
RUN apk add --no-cache \
    gcc \
    libc-dev \
    make \
    openssl-dev \
    pcre2-dev \
    pcre-dev \
    zlib-dev \
    linux-headers \
    curl \
    gnupg \
    libxslt-dev \
    gd-dev \
    geoip-dev \
    git \
    perl-dev \
    musl-dev \
    libatomic_ops-dev

# Download nginx source
ENV NGINX_VERSION=1.22.1
RUN wget http://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz && \
    tar -xzvf nginx-${NGINX_VERSION}.tar.gz

# Clone the substitutions filter module
RUN git clone https://github.com/yaoweibin/ngx_http_substitutions_filter_module.git

# Configure and build nginx with all specified modules plus substitutions
WORKDIR /nginx-${NGINX_VERSION}
RUN ./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/run/nginx.pid \
    --lock-path=/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --with-perl_modules_path=/usr/lib/perl5/vendor_perl \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-cc-opt='-Os -fstack-clash-protection -Wformat -Werror=format-security -fno-plt -g' \
    --with-ld-opt='-Wl,--as-needed,-O1,--sort-common -Wl,-z,pack-relative-relocs' \
    --add-module=/ngx_http_substitutions_filter_module && \
    make && \
    make install

# Create expected directory structure
RUN mkdir -p /usr/lib/nginx/modules /etc/nginx/conf.d

# Final stage
FROM alpine:3.16

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    pcre \
    pcre2 \
    zlib \
    openssl \
    gd \
    geoip \
    libxslt \
    perl \
    ca-certificates \
    libatomic_ops \
    libgcc \
    libstdc++

# Copy nginx from builder
COPY --from=nginx-builder /etc/nginx /etc/nginx
COPY --from=nginx-builder /usr/sbin/nginx /usr/sbin/nginx

# Create expected directory structure
RUN mkdir -p /usr/lib/nginx/modules /etc/nginx/conf.d

# Create nginx user and directories
RUN addgroup -g 101 -S nginx && \
    adduser -S -D -H -u 101 -h /var/cache/nginx -s /sbin/nologin -G nginx -g nginx nginx && \
    mkdir -p /var/cache/nginx/client_temp \
             /var/cache/nginx/proxy_temp \
             /var/cache/nginx/fastcgi_temp \
             /var/cache/nginx/uwsgi_temp \
             /var/cache/nginx/scgi_temp \
             /var/log/nginx \
             /run && \
    chown -R nginx:nginx /var/cache/nginx /var/log/nginx /run && \
    chmod -R 755 /var/cache/nginx

# Copy womginx files
COPY --from=builder /opt/womginx /opt/womginx

# Fix the docker-entrypoint.sh script to handle missing files gracefully
RUN sed -i 's/rm /rm -f /g' /opt/womginx/docker-entrypoint.sh && \
    chmod +x /opt/womginx/docker-entrypoint.sh

# Remove any load_module directive for subs_filter since it's compiled statically
RUN sed -i '/load_module.*ngx_http_subs_filter_module/d' /opt/womginx/nginx.conf && \
    cp /opt/womginx/nginx.conf /etc/nginx/nginx.conf

# Test nginx configuration

# default environment variables
ENV PORT=80

EXPOSE 80
# Run the entrypoint script
CMD ["/opt/womginx/docker-entrypoint.sh"]
