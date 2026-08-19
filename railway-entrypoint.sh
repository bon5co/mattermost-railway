#!/bin/sh
# Railway entrypoint for Mattermost Team Edition.
#
# What it does, and why:
#   1. Repairs the ownership of Railway's volume mount, which is created uid 0
#      while the upstream image runs as uid 2000 ("mattermost"). Without this,
#      the server starts and passes its healthcheck while every file upload
#      fails with "unable to write to the local filesystem storage ...
#      permission denied".
#   2. Keeps plugins and the search index on the same volume, since Railway
#      allows one volume per service and the upstream image declares five.
#   3. Stores the server configuration in PostgreSQL instead of a file on the
#      container filesystem, so System Console changes survive a redeploy.
#   4. Seeds the system administrator BEFORE the server is reachable from the
#      internet. A stock Mattermost deploy has no user at all, and the first
#      anonymous POST to /api/v4/users is granted the "system_admin" role — so
#      whoever reaches the public URL first owns the instance.
#   5. Re-applies the administrator password on every boot, which makes a
#      redeploy a working password reset. Mattermost's own reset flow is an
#      emailed link and a fresh deploy has no SMTP configured.
set -eu

MM_USER=mattermost
MM_UID=2000
DATA_DIR="${MM_FILESETTINGS_DIRECTORY:-/mattermost/data}"
SEED_ADDR="127.0.0.1:8065"
LOCAL_SOCKET="/var/tmp/mattermost_local.socket"

log() { echo "[railway] $*"; }

# ---------------------------------------------------------------- validation
if [ -z "${MM_ADMIN_EMAIL:-}" ] || [ -z "${MM_ADMIN_PASSWORD:-}" ]; then
  log "FATAL: MM_ADMIN_EMAIL and MM_ADMIN_PASSWORD must both be set."
  log "Refusing to boot: without an administrator, the first stranger to open"
  log "the public URL becomes the system administrator of this instance."
  exit 1
fi
if [ -z "${MM_SQLSETTINGS_DATASOURCE:-}" ]; then
  log "FATAL: MM_SQLSETTINGS_DATASOURCE is empty (is the Postgres service up?)."
  exit 1
fi

# ------------------------------------------------------------------ storage
# Railway allows one volume per service and the upstream image declares five,
# so plugins and the search index are pointed at subdirectories of the data
# volume through configuration rather than symlinks. (A symlink is not usable
# here: the image declares VOLUME on those paths, and chown -R does not descend
# through a symlink given as its argument.)
for sub in plugins client-plugins bleve-indexes; do
  mkdir -p "$DATA_DIR/$sub"
done

if [ "$(id -u)" = "0" ]; then
  chown -R "$MM_UID:$MM_UID" "$DATA_DIR" /mattermost/config /mattermost/logs 2>/dev/null || true
  log "volume owner=$(stat -c %u:%g "$DATA_DIR")"
  # busybox su, not setpriv: BusyBox's setpriv has no --reuid, and su-exec is an
  # Alpine (musl) binary that cannot run in this glibc image.
  as_mattermost() { /bin/busybox su -s /bin/sh "$MM_USER" -c "$1"; }
else
  log "running as uid $(id -u); cannot repair volume ownership"
  as_mattermost() { /bin/sh -c "$1"; }
fi

# Configuration lives in the database, so a redeploy keeps System Console edits.
export MM_CONFIG="${MM_CONFIG:-$MM_SQLSETTINGS_DATASOURCE}"
export MM_BLEVESETTINGS_INDEXDIR="${MM_BLEVESETTINGS_INDEXDIR:-$DATA_DIR/bleve-indexes}"
export MM_PLUGINSETTINGS_DIRECTORY="$DATA_DIR/plugins"
export MM_PLUGINSETTINGS_CLIENTDIRECTORY="$DATA_DIR/client-plugins"
export MM_FILESETTINGS_DIRECTORY="$DATA_DIR"
export MM_SERVICESETTINGS_ENABLELOCALMODE=true
export MM_SERVICESETTINGS_LOCALMODESOCKETLOCATION="$LOCAL_SOCKET"

# ------------------------------------------------------------------- seeding
# The seeding server binds loopback only, so nothing is reachable from the
# Railway edge until the administrator exists.
log "starting seed server on $SEED_ADDR"
MM_SERVICESETTINGS_LISTENADDRESS="$SEED_ADDR" \
  as_mattermost "exec /mattermost/bin/mattermost" &
SEED_PID=$!

ready=0
i=0
while [ $i -lt 180 ]; do
  if [ -S "$LOCAL_SOCKET" ] && /mattermost/bin/mmctl --local system status >/dev/null 2>&1; then
    ready=1; break
  fi
  if ! kill -0 "$SEED_PID" 2>/dev/null; then
    log "FATAL: seed server exited before it became ready"
    wait "$SEED_PID" || true
    exit 1
  fi
  i=$((i + 1)); sleep 1
done
[ "$ready" = "1" ] || { log "FATAL: seed server never became ready"; exit 1; }

ADMIN_USERNAME="${MM_ADMIN_USERNAME:-admin}"
# Note: a plugin bot account ("calls") exists from the first boot onward, so
# "is the user table empty" is not a usable test for whether WE have seeded.
if /mattermost/bin/mmctl --local user search "$MM_ADMIN_EMAIL" >/dev/null 2>&1; then
  log "users already exist; re-applying the administrator password"
  /mattermost/bin/mmctl --local user change-password "$MM_ADMIN_EMAIL" \
    --password "$MM_ADMIN_PASSWORD" >/dev/null \
    || { log "FATAL: could not re-apply the password for $MM_ADMIN_EMAIL"; exit 1; }
  /mattermost/bin/mmctl --local roles system-admin "$MM_ADMIN_EMAIL" >/dev/null 2>&1 || true
else
  log "seeding the system administrator"
  /mattermost/bin/mmctl --local user create \
    --email "$MM_ADMIN_EMAIL" --username "$ADMIN_USERNAME" \
    --password "$MM_ADMIN_PASSWORD" --system-admin --email-verified \
    --disable-welcome-email >/dev/null
fi

log "stopping seed server"
kill "$SEED_PID" 2>/dev/null || true
wait "$SEED_PID" 2>/dev/null || true
rm -f "$LOCAL_SOCKET"

# --------------------------------------------------------------------- serve
PORT="${PORT:-8065}"
export MM_SERVICESETTINGS_LISTENADDRESS=":$PORT"
log "starting Mattermost on :$PORT"
if [ "$(id -u)" = "0" ]; then
  exec /bin/busybox su -s /bin/sh "$MM_USER" -c "exec /mattermost/bin/mattermost"
fi
exec /mattermost/bin/mattermost
