# Changelog

All notable user-visible changes to the Nginx TOS application package.

## 1.29.8-1 — 2026-09-27

### Added
- First release. Nginx 1.29.8 (official `nginx:1.29.8-alpine` image from Docker
  Hub, unmodified) packaged as a TOS 7 Docker application, published on port
  8081 and running as a non-root user (uid 1000).
- On first start the application creates a default site, a commented main
  configuration (`config/nginx.conf`), a ready-to-use example file for path-based
  reverse proxies (`config/locations.conf`), a short how-to on the NAS
  (`config/README.txt`) and a placeholder welcome page (`www/index.html`). None
  of these files is ever overwritten afterwards.
- Persistent data is kept in `<volume>/DockerAppData/nginxdocker/`:
  `config/` for configuration, `www/` for the served files.
- Configuration errors are reported in the container log and the application
  falls back to its built-in default site instead of failing to start.
- 23-language application description (`nginxdocker.lang`), covering both
  official 14-language lists.
