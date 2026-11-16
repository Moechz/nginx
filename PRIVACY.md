# Privacy Policy — Nginx Web Server for TerraMaster TOS (`nginxdocker`)

**Last updated:** 17 November 2026
**Data controller / contact:** Moechz — moechz@163.com

This policy covers the TOS application `nginxdocker` (the “app”) and its packaging.

## 1. Summary

- The app runs **entirely on your NAS**. The developer does not receive, collect or have
  access to your data.
- No telemetry, no analytics, no account and no cloud service operated by the developer.
- The app contacts only the services **you configure**, plus an optional update check and
  the Docker image registry.

## 2. What data is processed

| Container path | Stored on the NAS at |
|---|---|
| `/config` | `/Volume1/DockerAppData/nginxdocker/config` |
| `/www` | `/Volume1/DockerAppData/nginxdocker/www` |

This is the application data (configuration, database, caches, logs) plus any files you
create with the app. It stays in the application data folder
(`/Volume1/DockerAppData/nginxdocker/`) or in the media paths you choose; nothing is uploaded to
the developer.

## 3. Retention period

- **Application data:** kept until **you** delete it. There is no automatic expiry and no
  upload. Uninstalling the app keeps the data unless you tick “delete data”.
- **Logs:** rotated or size-limited by the application itself.
- **Cache:** rebuilt on demand; safe to delete at any time.
- **Website/server logs (moechz.com):** short-lived operational logs, not used for profiling.

## 4. Your rights and the deletion channel

| Right | How |
|---|---|
| Access / export | Copy the folder `/Volume1/DockerAppData/nginxdocker/` — it is the complete state. |
| Correct | Change the values in the app's own web UI. |
| Delete | Uninstall the app with “delete data”, or stop the container and remove `/Volume1/DockerAppData/nginxdocker/`. |
| Assistance | Email **moechz@163.com** with the subject “Nginx Web Server data request”; a reply follows within 30 days. |

The developer holds no copy of your data, so deletion is normally completed by removing the
folder on your own NAS; the email channel exists for questions and for requests about the
website or the publishing records.

## 5. Security measures

- The container runs as **uid 1000**, never root; no `privileged`, no `cap_add`, no host
  network, no Docker socket.
- Only the application's own port is published.
- The image tag is **pinned**; the package is rebuilt when upstream ships security fixes.
- Data stays inside the application data folder, owned by the app user.
- If you expose the UI outside the LAN, put it behind a TLS reverse proxy and keep the app
  updated.

## 6. Third-party sharing and API disclosure

The developer shares nothing. The app contacts only the endpoints below, and only when you
configure or enable them.

| Service | Endpoint | Data sent | Destination / region |
|---|---|---|---|
| Services you configure in the app | the endpoint you enter | only the data that feature needs | normally your own LAN or the provider you chose |
| Update check (if enabled) | the upstream project's release feed (e.g. GitHub) | current version string | GitHub, US |
| Image pull | `registry-1.docker.io` or your registry mirror | anonymous pull | Docker Hub, US / your mirror |

No data is sold or shared with advertisers. There is no third-party analytics SDK.

## 7. Children

The app is a self-hosted utility and is not directed at children.

## 8. Changes

Material changes are published in this file and reflected in the “Last updated” date.

## 9. Contact

Moechz — **moechz@163.com** — <https://www.moechz.com/privacy.html>
