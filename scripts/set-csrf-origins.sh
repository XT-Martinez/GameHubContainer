#!/bin/bash
# Sync Sunshine's csrf_allowed_origins with SUNSHINE_CSRF_ORIGINS.
#
# Sunshine's web UI rejects POSTs whose Origin is not listed, so opening the UI
# through a LAN address fails (for example while setting the first password).
# run.sh passes the host's addresses as a comma-separated list of https://
# origins (matched by prefix, any port). Run before sunshine starts; with the
# variable unset or empty the config is left alone, so it can be edited by hand.

CONF="${HOME}/.config/sunshine/sunshine.conf"
ORIGINS="${SUNSHINE_CSRF_ORIGINS:-}"

[ -n "$ORIGINS" ] && [ -f "$CONF" ] || exit 0

sed -i '/^csrf_allowed_origins[[:space:]]*=/d' "$CONF"
printf 'csrf_allowed_origins = %s\n' "$ORIGINS" >> "$CONF"
