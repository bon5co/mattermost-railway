# mattermost-railway

Railway wrapper image for [Mattermost](https://mattermost.com) Team Edition 11.10.0.

Upstream's image is fine as it stands; everything here exists because of how
Railway runs it.

* **The administrator is seeded before the public port is open.** A stock
  Mattermost deploy contains no user, and the first anonymous `POST
  /api/v4/users` is granted the `system_admin` role — so on a public URL the
  instance belongs to whoever arrives first. The entrypoint starts the server
  bound to `127.0.0.1`, creates the administrator through `mmctl --local`, stops
  it, and only then binds the port Railway routes to.
* **The password is re-applied on every boot**, which makes a redeploy a working
  password reset. Mattermost's own reset flow is an emailed link, and a fresh
  deploy has no SMTP configured.
* **Railway's volume is mounted uid 0** while the image runs as uid 2000. Left
  alone, the server starts, answers its healthcheck, and fails every file upload
  with a permission error. The entrypoint repairs the ownership and drops back
  to uid 2000.
* **Plugins and the search index are pointed at the data volume**, because
  Railway allows one volume per service and the upstream image declares five.
* **Configuration is stored in PostgreSQL** (`MM_CONFIG`), so System Console
  changes survive a redeploy.

The image adds a static BusyBox because the upstream image ships no shell at
all — only the server binary and `mmctl`.

## Environment

| Variable | Required | Meaning |
| --- | --- | --- |
| `MM_ADMIN_EMAIL` | yes | Email of the administrator to seed. The container refuses to boot without it. |
| `MM_ADMIN_PASSWORD` | yes | Password for that account, re-applied on every boot. |
| `MM_ADMIN_USERNAME` | no | Defaults to `admin`. |
| `MM_SQLSETTINGS_DATASOURCE` | yes | PostgreSQL connection string. |
| `PORT` | no | Injected by Railway; defaults to 8065. |

Published as `ghcr.io/bon5co/mattermost-railway:11.10.0`.
