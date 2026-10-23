#!/bin/bash
# Remove Steam's saved SDL mapping that swaps Cross/Circle for Sunshine's
# virtual DualSense (GUID 050000004c050000e60c000011810000).
# Steam keeps this mapping in config.vdf and saves it back at times, which
# makes the Steam UI treat Cross as Square and Circle as Cross; the controller
# test and games read the DualSense directly and are unaffected.
# Steam rewrites config.vdf on exit, so only edit it while Steam isn't running.
f="${HOME:-/home/gamer}/.local/share/Steam/config/config.vdf"
[ -f "$f" ] || exit 0
# Look for the Steam client itself: the /usr/local/bin/steam wrapper that runs
# this script is also a process named "steam".
pgrep -u "$(id -u)" -f '/ubuntu12_32/steam( |$)' >/dev/null && exit 0
grep -q '^050000004c050000e60c000011810000,PS5 Controller,a:b1,b:b2,' "$f" || exit 0
# A middle line of the SDL_GamepadBind value: drop it. The last line also
# carries the closing quote: keep that by ending the previous line with it.
awk '
  /^050000004c050000e60c000011810000,PS5 Controller,a:b1,b:b2,/ {
    if ($0 ~ /"$/) { prev = prev "\""; }
    next
  }
  { if (NR > 1 && have) print prev; prev = $0; have = 1 }
  END { if (have) print prev }
' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
