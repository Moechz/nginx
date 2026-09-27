#!/bin/sh
# ===========================================================================
# Nginx Web Server for TOS 7 - container entrypoint
# ===========================================================================
# The upstream image (nginx:1.29.8-alpine) is built to run as root and keeps
# its configuration in /etc/nginx (root-owned). TOS requires every container to
# run as a non-root user, so this wrapper
#
#   1. prepares writable runtime directories and a complete nginx.conf the
#      unprivileged user can actually use (pid file, temp paths, logs),
#   2. seeds a default server, a welcome page and a short README into the
#      bind-mounted application data directory the first time it starts,
#   3. starts nginx in the foreground.
#
# Everything the user can change lives in the bind mounts (/config, /www).
#
# MAINTAINERS: this file is embedded verbatim into docker-compose.yml by
# scripts/build.sh, which indents it and escapes every dollar sign (docker
# compose interpolates ${VAR} / $VAR in compose files - see D-007 in
# docs/DESIGN_DECISIONS.md). Edit THIS file, never the generated block.
# ===========================================================================
set -u

log() { printf '[nginx-app] %s\n' "$*"; }

CONF_DIR=/config
WWW_DIR=/www
RUN_DIR=/tmp/nginx

# --------------------------------------------------------------- runtime dirs
# pid file and the request-body / proxy temp paths must be writable by the
# unprivileged user, so they never live in the image's /etc/nginx or /var/cache.
mkdir -p "$RUN_DIR/client_temp" "$RUN_DIR/proxy_temp" "$RUN_DIR/fastcgi_temp" \
         "$RUN_DIR/uwsgi_temp" "$RUN_DIR/scgi_temp" 2>/dev/null || true

# ------------------------------------------------------------ writable mounts
# The bind-mount sources are created by Docker (owned by root) the first time
# the container starts. The TOS installer chowns them to the application user;
# if that has not happened, fall back to a container-local copy so that the
# application still starts instead of entering a restart loop.
if ! { mkdir -p "$CONF_DIR/conf.d" 2>/dev/null &&
       : > "$CONF_DIR/.write-test" 2>/dev/null; }; then
    log "WARNING: $CONF_DIR is not writable - using an ephemeral configuration in /tmp"
    log "WARNING: configuration changes will be lost when the container is recreated"
    CONF_DIR=/tmp/nginx-app/config
    mkdir -p "$CONF_DIR/conf.d"
fi
rm -f "$CONF_DIR/.write-test" 2>/dev/null || true

if ! { mkdir -p "$WWW_DIR" 2>/dev/null && : > "$WWW_DIR/.write-test" 2>/dev/null; }; then
    log "WARNING: $WWW_DIR is not writable - serving a fallback web root from /tmp"
    log "WARNING: website files will be lost when the container is recreated"
    WWW_DIR=/tmp/nginx-app/www
    mkdir -p "$WWW_DIR"
fi
rm -f "$WWW_DIR/.write-test" 2>/dev/null || true

# --------------------------------------------------------------- file seeding
# seed <target> <mode> <conf-dir> <www-dir>   (template on stdin)
# Writes the template only when the target does not exist yet, so a user's own
# file is never overwritten. @CONF_DIR@ / @WWW_DIR@ are replaced with the
# directories actually in use (they can differ when the fallback kicked in).
seed() {
    if [ -e "$1" ]; then
        cat > /dev/null
        return 0
    fi
    sed -e "s|@CONF_DIR@|$3|g" -e "s|@WWW_DIR@|$4|g" > "$1"
    chmod "$2" "$1" 2>/dev/null || true
    log "created $1"
}

seed "$CONF_DIR/nginx.conf" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_NGINX_CONF'
# ===========================================================================
# Nginx Web Server for TOS - main configuration
# ===========================================================================
# This file is generated on first start and is kept on your NAS. Edit it and
# restart the application to apply the changes. Everything the default
# configuration needs is included below; the interesting parts to extend are
# the two include lines at the bottom of the http block.
#
# Validate before restarting:   nginx -t -c /config/nginx.conf
# (run it inside the container: docker exec nginxdocker nginx -t -c /config/nginx.conf)
# ===========================================================================

worker_processes  auto;

# logs go to the container log (docker logs nginxdocker / Container Manager)
error_log  /dev/stderr  warn;
pid        /tmp/nginx/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /dev/stdout  main;

    sendfile            on;
    keepalive_timeout   65;
    server_tokens       off;

    # Uploads through this server (and through any reverse proxy defined below).
    # Raise or lower as needed.
    client_max_body_size 100m;

    # writable locations for request bodies and proxied responses
    client_body_temp_path  /tmp/nginx/client_temp;
    proxy_temp_path        /tmp/nginx/proxy_temp;
    fastcgi_temp_path      /tmp/nginx/fastcgi_temp;
    uwsgi_temp_path        /tmp/nginx/uwsgi_temp;
    scgi_temp_path         /tmp/nginx/scgi_temp;

    # -----------------------------------------------------------------------
    # Whole sites / virtual hosts, and reverse proxies on this port.
    # Every *.conf file in this directory is loaded here (http context),
    # so a file may contain one or more complete "server { ... }" blocks.
    # ("location { ... }" blocks for the default site belong in
    # @CONF_DIR@/locations.conf, which the default site includes itself.)
    # -----------------------------------------------------------------------
    include @CONF_DIR@/conf.d/*.conf;
}
TPL_NGINX_CONF

seed "$CONF_DIR/locations.conf" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_LOCATIONS'
# ===========================================================================
# Extra location blocks for the default site (port 8080).
# ===========================================================================
# Everything in this file is included inside the default server block, so the
# entries below are "location" directives, not complete server blocks.
#
# Example: publish a service that runs elsewhere on your LAN under /app/
#
#   location /app/ {
#       proxy_pass         http://192.168.1.10:3000/;
#       absolute_redirect  off;
#       proxy_set_header   Host              $http_host;
#       proxy_set_header   X-Real-IP         $remote_addr;
#       proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
#       proxy_set_header   X-Forwarded-Proto $scheme;
#       proxy_set_header   Upgrade           $http_upgrade;
#       proxy_set_header   Connection        "upgrade";
#       proxy_read_timeout 3600s;
#   }
#
# Example: browse and download the files you put in the web root
#
#   location /files/ {
#       alias      @WWW_DIR@/files/;
#       autoindex  on;
#   }
#
# After editing, run "docker exec nginxdocker nginx -t -c /config/nginx.conf"
# and restart the application.
TPL_LOCATIONS

if ! ls "$CONF_DIR"/conf.d/*.conf >/dev/null 2>&1; then
    seed "$CONF_DIR/conf.d/default.conf" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_DEFAULT'
# ===========================================================================
# Default site - listens on port 8080, which is the port published by TOS
# (it is reachable as http://<NAS-IP>:8081/ from your local network).
# ===========================================================================
server {
    listen       8080 default_server;
    server_name  _;

    root   @WWW_DIR@;
    index  index.html index.htm;

    charset  utf-8;

    location / {
        try_files $uri $uri/ =404;
    }

    # Health endpoint used by the TOS application health check.
    # Keep it if you rewrite this file, otherwise the application may be
    # reported as not running.
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    # location blocks added by the user (see /config/locations.conf)
    include @CONF_DIR@/locations.conf;
}
TPL_DEFAULT
fi

seed "$CONF_DIR/README.txt" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_README'
Nginx Web Server for TOS - application data
===========================================

Everything in this directory is kept on your NAS (it is the "config" volume of
the Nginx application) and survives restarts, re-installs and upgrades of the
application.

  nginx.conf      Main configuration. Generated on first start.
  conf.d/         One file per site / reverse proxy. Every *.conf is loaded
                  (http context), so a file may contain complete
                  "server { ... }" blocks.
  locations.conf  Extra "location { ... }" blocks for the default site.
  README.txt      This file.

The web root (the files that are served) is the "www" directory next to this
one, i.e. <volume>/DockerAppData/nginxdocker/www.

How to use it
-------------
1. Put your website into the www directory (index.html is created for you on
   first start).
2. To publish something that runs elsewhere on your LAN, add a file such as
   conf.d/proxy.conf containing a complete server block, or add a location
   block to locations.conf. Examples are included in locations.conf.
3. Check the configuration and restart the application:

       docker exec nginxdocker nginx -t -c /config/nginx.conf

   (or use Container Manager), then restart the Nginx application from the
   TOS App Center.

Logs
----
Access and error logs are written to the container log:

       docker logs nginxdocker

They are not stored as files, so they cannot fill up your NAS. See README.md
of the package for the complete list of files this application creates.

Ports
-----
Only one port is published: the TOS application opens
http://<NAS-IP>:8081/ and the container listens on port 8080. Server blocks
that listen on other ports are not reachable from outside the container.

Non-root
--------
The container runs as a non-root user (uid 1000); it can only write inside its
own data directory. Do not point "root" at system directories such as /etc.
TPL_README

if [ ! -e "$WWW_DIR/index.html" ]; then
    seed "$WWW_DIR/index.html" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_INDEX'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Nginx Web Server</title>
<style>
  :root { color-scheme: light dark; }
  body { font-family: system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,"Noto Sans CJK SC",sans-serif;
         max-width: 46rem; margin: 0 auto; padding: 3rem 1.25rem 4rem; line-height: 1.7; }
  h1 { font-size: 1.6rem; margin-bottom: .2rem; }
  h2 { font-size: 1.1rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; font-size: .92em; }
  code { background: rgba(127,127,127,.15); padding: .1em .35em; border-radius: .3em; }
  pre { background: rgba(127,127,127,.12); padding: .8rem 1rem; border-radius: .5rem; overflow-x: auto; }
  .ok { color: #0a7d33; font-weight: 600; }
  footer { margin-top: 3rem; font-size: .85rem; opacity: .7; }
</style>
</head>
<body>
<h1>Nginx Web Server</h1>
<p class="ok">The web server is running on your NAS.</p>

<p>This is the placeholder page created on first start. Replace
<code>index.html</code> in the <code>www</code> directory of the application
data (<code>&lt;volume&gt;/DockerAppData/nginxdocker/www</code>) and reload the
application to publish your own site.</p>

<h2>Add a website or a reverse proxy</h2>
<p>The configuration lives in the <code>config</code> directory next to
<code>www</code>:</p>
<pre>config/nginx.conf      main configuration (generated on first start)
config/conf.d/         one file per site / complete "server { }" block
config/locations.conf  extra "location { }" blocks for this port
config/README.txt      how-to and examples</pre>
<p>Every <code>config/conf.d/*.conf</code> file is loaded, so a reverse proxy
is one small file, for example:</p>
<pre>server {
    listen 8080;
    location /app/ {
        proxy_pass http://192.168.1.10:3000/;
        proxy_set_header Host $http_host;
    }
}</pre>

<h2>Check and apply</h2>
<pre>docker exec nginxdocker nginx -t -c /config/nginx.conf    # validate
# then restart the Nginx application from the TOS App Center</pre>
<p>Access and error logs: <code>docker logs nginxdocker</code> (or the TOS
Container Manager).</p>

<hr>
<p><b>中文：</b>Nginx 已在你的 NAS 上运行。上面的绿色提示说明服务正常。
把 <code>index.html</code> 换成自己的网页即可发布网站（位置：应用数据目录
<code>DockerAppData/nginxdocker/www</code>）。反代/站点配置放在同级的
<code>config</code> 目录：<code>conf.d/</code> 里每个 <code>*.conf</code>
文件都会被加载（可写完整的 <code>server { }</code> 块），
<code>locations.conf</code> 用于给默认站点补 <code>location { }</code>。
改完先执行 <code>docker exec nginxdocker nginx -t -c /config/nginx.conf</code> 检查，然后在应用中心
重启本应用。访问日志与错误日志用 <code>docker logs nginxdocker</code> 查看。</p>

<footer>Nginx 1.29.8 (Docker Hub official image, unmodified) &middot; packaged for
TOS 7 by Moechz. Nginx is a trademark of F5, Inc.</footer>
</body>
</html>
TPL_INDEX
fi

# ------------------------------------------------------------------- validate
# Never start with a broken configuration: nginx would exit immediately and the
# container would restart in a loop, which TOS reports as a faulty application.
if nginx -t -c "$CONF_DIR/nginx.conf" > /tmp/nginx-check.log 2>&1; then
    cat /tmp/nginx-check.log
else
    log "ERROR: the configuration in $CONF_DIR is not valid:"
    sed 's/^/  /' /tmp/nginx-check.log
    if [ "$CONF_DIR" = "/config" ]; then
        log "ERROR: falling back to the built-in default configuration"
        log "ERROR: fix the files above and restart the application"
        CONF_DIR=/tmp/nginx-app/fallback
        mkdir -p "$CONF_DIR/conf.d"
        seed "$CONF_DIR/nginx.conf" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_NGINX_CONF'
worker_processes  auto;
error_log  /dev/stderr  warn;
pid        /tmp/nginx/nginx.pid;
events { worker_connections 1024; }
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log   /dev/stdout;
    client_body_temp_path /tmp/nginx/client_temp;
    proxy_temp_path       /tmp/nginx/proxy_temp;
    fastcgi_temp_path     /tmp/nginx/fastcgi_temp;
    uwsgi_temp_path       /tmp/nginx/uwsgi_temp;
    scgi_temp_path        /tmp/nginx/scgi_temp;
    include @CONF_DIR@/conf.d/*.conf;
}
TPL_NGINX_CONF
        seed "$CONF_DIR/conf.d/default.conf" 0644 "$CONF_DIR" "$WWW_DIR" <<'TPL_DEFAULT_FALLBACK'
server {
    listen      8080 default_server;
    server_name _;
    root        @WWW_DIR@;
    index       index.html;
    location / { }
    location = /healthz { access_log off; return 200 "ok\n"; }
}
TPL_DEFAULT_FALLBACK
        nginx -t -c "$CONF_DIR/nginx.conf" > /tmp/nginx-check.log 2>&1 || {
            log "ERROR: the built-in configuration is invalid as well - giving up"
            cat /tmp/nginx-check.log
            exit 1
        }
    else
        exit 1
    fi
fi

log "starting nginx with $CONF_DIR/nginx.conf, web root $WWW_DIR"
exec nginx -c "$CONF_DIR/nginx.conf" -g "daemon off;"
