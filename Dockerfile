# syntax=docker/dockerfile:1
FROM alpine:3.22 AS tools
RUN apk add --no-cache busybox-static

FROM mattermost/mattermost-team-edition:11.10.0

# The upstream image ships no shell at all (only the server binary and mmctl),
# so the boot logic below needs one. BusyBox also supplies "su", which is how
# the server drops back to uid 2000 after the entrypoint has repaired the
# ownership of Railway's root-owned volume mount.
COPY --from=tools /bin/busybox.static /bin/busybox
COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh

USER root
RUN ["/bin/busybox", "sh", "-c", "\
  /bin/busybox --install -s /bin && \
  chmod +x /usr/local/bin/railway-entrypoint.sh && \
  test -x /mattermost/bin/mmctl"]

ENTRYPOINT ["/bin/sh", "/usr/local/bin/railway-entrypoint.sh"]
