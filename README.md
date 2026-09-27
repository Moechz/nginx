# nginx-for-tos

> TerraMaster TOS 7 App Center — **Docker application** package for
> [Nginx](https://nginx.org/), built from the official
> [`nginx`](https://hub.docker.com/_/nginx) image on Docker Hub.

## What this is

A four-file TOS Docker application archive (`nginxdocker.tar.gz`) that installs a
ready-to-use Nginx web server / reverse proxy on TOS 7 through the App Center:

- `config.ini` — TOS application metadata (`application_type: docker`, id `nginxdocker`)
- `nginxdocker.lang` — 23-language superset (TOS requires 14)
- `nginxdocker.svg` — simplified Nginx mark (5 SVG elements, 350 bytes)
- `docker-compose.yml` — one service, image `nginx:1.29.8-alpine`

Open the app from its desktop icon (`http://<NAS-IP>:8081/`) and Nginx is serving
your files. Put your site in the application's `www` folder, add sites and
reverse proxies as small configuration files, and manage everything without
touching the NAS system.

## How it works

| | |
|---|---|
| Container image | `nginx:1.29.8-alpine` (Docker Hub official image, used unmodified) |
| Open | `http://<NAS-IP>:8081/` (container port 8080, non-privileged) |
| Runs as | non-root, uid/gid 1000 |
| Web root | `<volume>/DockerAppData/nginxdocker/www` → `/www` in the container |
| Configuration | `<volume>/DockerAppData/nginxdocker/config` → `/config` in the container |
| Logs | `docker logs nginxdocker` (access + error, stdout/stderr) |

`config/nginx.conf` is generated on first start and is never rewritten
afterwards, so it is yours to edit:

```nginx
http {
    ...
    include /config/conf.d/*.conf;      # whole sites / reverse proxies
}
```

`config/conf.d/default.conf` is the default site (port 8080, root `/www`); it
includes `config/locations.conf`, which is where path-based reverse proxies go:

```nginx
# /config/locations.conf
location /app/ {
    proxy_pass http://192.168.1.10:3000/;
    proxy_set_header Host $http_host;
}
```

Validate and apply:

```bash
docker exec nginxdocker nginx -t -c /config/nginx.conf   # check
# then restart the Nginx application from the TOS App Center
```

## Design highlights

- **Non-root, as TOS requires.** The official image is built to run as root and
  keeps its configuration in root-owned `/etc/nginx`. Because TOS forbids root
  containers, the package overrides the entrypoint with a wrapper that builds a
  complete `nginx.conf` the unprivileged user can use: its own pid file, its own
  request-body/proxy temp directories under `/tmp/nginx`, logs on stdout/stderr,
  and no write access outside the application data directory.
- **Your files are never overwritten.** Every generated file is written only when
  it does not exist yet. Restarting or updating the application keeps whatever
  you changed.
- **A broken configuration cannot take the application down.** Before starting,
  the wrapper runs `nginx -t`. If the configuration is invalid it logs the exact
  error and falls back to the built-in default, so the container stays healthy
  instead of entering a restart loop.
- **Honest health check.** It probes `http://127.0.0.1:8080/` and treats *any*
  HTTP response as healthy, so a site that returns 404 or 403 on `/` does not get
  reported as a failed application.
- **Fixed image tag, never `:latest`**, Docker Hub only, no `privileged`, no
  `network_mode: host`, no Docker socket, no `cap_add`.
- **Deterministic build**: GNU tar with uid/gid 0 and zeroed timestamps, gzip
  without a timestamp, plus a review-standards self-check that fails the build on
  any deviation.

## Runtime file manifest

The application writes exactly these files, all inside its own data directory,
and only when they do not exist yet (nothing else is created on the NAS; the
container-internal `/tmp` is discarded with the container):

| Path | Purpose | Created when | Growth bound | Lifecycle |
|---|---|---|---|---|
| `config/nginx.conf` | Main configuration | First start | static (~2.6 KB) | Never overwritten; user-owned |
| `config/conf.d/default.conf` | Default site (port 8080, root `/www`) | First start | static (~0.9 KB) | Never overwritten; user-owned |
| `config/locations.conf` | Extra `location { }` blocks for the default site | First start | user-controlled | Never overwritten; user-owned |
| `config/README.txt` | Short how-to for the NAS administrator | First start | static (~2 KB) | Never overwritten |
| `www/index.html` | Placeholder welcome page | First start | static (~3 KB) | Never overwritten; replace it |
| `/tmp/nginx/**` (in container) | pid file, request-body and proxy temp files | Every start | bounded by request size | Discarded with the container |
| `/tmp/nginx-app/**` (in container) | Fallback configuration, used **only** if the mounted data directory is not writable | Only in that failure case | static | Discarded with the container |

The paths on the NAS are
`<volume>/DockerAppData/nginxdocker/config/...` and
`<volume>/DockerAppData/nginxdocker/www/...`.

## Build

```bash
scripts/build.sh                  # -> out/nginxdocker.tar.gz + .sha256
scripts/build.sh 1.29.8-2         # packaging iteration bump
scripts/build.sh 1.29.8-1 aarch64 # another architecture (platform field follows)
```

Version format: `<upstream-image-version>-<packaging-iteration>`. The numeric part
must equal the version in the image tag, which the build asserts. The build
stages the four files, substitutes `@@VERSION@@` / `@@PLATFORM@@`, embeds
`src/entrypoint.sh` into the compose file (escaping every `$` as `$$`), removes
CRLF/BOM/AppleDouble, then runs a review-standards self-check: archive layout,
JSON validity, required fields, 23-language coverage and version consistency,
Docker-Hub-only images, fixed tag, reserved/recommended host ports, non-root
user, per-service healthcheck/TZ/restart, data path below the application data
root (never the `/Volume*` wildcard), comment-free sequence blocks, `x-app-meta`
position, no literal secrets, SVG size/element limits, and a byte-for-byte
comparison of the embedded entrypoint against its source.

## Local verification

```bash
./TOSAppSelfTestingTool -c out/nginxdocker.tar.gz    # official spec check
bash test/install-and-verify.sh out/nginxdocker.tar.gz   # full E2E (needs root)
```

> Docker applications cannot be side-loaded through the App Center's manual
> install page (it accepts `.deb` only); the official self-testing tool's `-i`
> mode or `docker compose` are the only ways to install one for testing.

## Store submission checklist

1. Public GitHub repo (code + README only).
2. Release **tag `v1.29.8-1`** (matches `config.ini` version), assets
   `nginxdocker.tar.gz` + `nginxdocker.tar.gz.sha256`.
   Docker asset naming: `<app_id>.tar.gz` — **no platform suffix**.
3. Developer platform → Add Application: ID `nginxdocker`, package type Docker,
   repository URL, architecture `x86_64`.
4. Version Management → Add Version `1.29.8-1` → automated validation → review.
5. Bumping the upstream image (e.g. to `1.30.0-alpine`) means changing the image
   tag, the version and the Release; the App Center does not upgrade Docker
   applications, users reinstall (data is kept).

## License / branding

Nginx is © F5, Inc. and is distributed under the BSD-2-Clause licence; the
container image is the official `nginx` image from Docker Hub and is used
unmodified. The icon in this repository is an independent, simplified rendering
of the Nginx mark. This packaging is an independent community submission by
Moechz and is not affiliated with F5, Inc. or TerraMaster.

## Limitations

- **One published port.** Only container port 8080 is reachable from the network
  (as host port 8081). `server` blocks that listen on other ports work inside the
  container but cannot be reached from outside; use `server_name` or path-based
  `location` blocks instead.
- **Configuration is edited as files.** Docker applications do not take part in
  the TNAS shared-folder mechanism, so the web root and the configuration live in
  the application data directory
  (`<volume>/DockerAppData/nginxdocker/`), managed over SSH/SFTP.
- **No automatic upgrades.** TOS does not support upgrading Docker applications;
  updating means uninstalling and reinstalling (the data directory is preserved
  unless you ask for it to be deleted).
