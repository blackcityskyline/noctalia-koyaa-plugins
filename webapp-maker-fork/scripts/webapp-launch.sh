#!/bin/bash

# Launch a URL as a web-app window.
#
# Usage: webapp-launch [--backend <binary>] <url> [browser flags...]
#
# Resolution order for browser:
#   1. --backend flag (if passed by .desktop)
#   2. browser_backend from noctalia settings.toml
#   3. Auto-detect from xdg-settings / known binaries
#
# Chromium-family: --app mode (no tabs, no URL bar)
# Firefox-family:  --new-window (new window in existing instance)

# ── Parse args ───────────────────────────────────────────────────────────────
backend=""
args=()
while (($#)); do
  case "$1" in
    --backend)
      backend=${2:?--backend needs a value}
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
set -- "${args[@]}"

url=${1:?usage: webapp-launch [--backend <bin>] <url> [browser flags...]}
shift

# ── Read browser_backend from noctalia settings.toml ─────────────────────────
if [[ -z $backend ]]; then
  NOCTALIA_SETTINGS="$HOME/.local/state/noctalia/settings.toml"
  if [[ -f $NOCTALIA_SETTINGS ]]; then
    # Find the plugin section and extract browser_backend
    backend=$(awk '
      /^\[plugin_settings\."koyaa-plugins\/webapp-maker-fork"\]/ { in_section=1; next }
      /^\[/ { in_section=0 }
      in_section && /^browser_backend/ {
        gsub(/^[[:space:]]*browser_backend[[:space:]]*=[[:space:]]*"?/, "")
        gsub(/"?[[:space:]]*$/, "")
        print
        exit
      }
    ' "$NOCTALIA_SETTINGS")
  fi
fi

# ── Resolve browser ──────────────────────────────────────────────────────────
exec_bin=""
is_chromium=false
is_firefox=false

if [[ -n $backend ]]; then
  exec_bin=$(command -v "$backend" 2>/dev/null)
  case ${backend,,} in
  chromium | google-chrome* | brave | vivaldi | microsoft-edge* | opera | helium*)
    is_chromium=true
    ;;
  firefox | zen* | waterfox | librewolf | palemoon)
    is_firefox=true
    ;;
  esac
fi

# Auto-detect if no backend or binary not found
if [[ -z $exec_bin ]]; then
  browser=$(xdg-settings get default-web-browser 2>/dev/null)

  case $browser in
  chromium* | chrome* | google-chrome* | brave* | microsoft-edge* | opera* | vivaldi* | helium*)
    is_chromium=true
    ;;
  esac
  case $browser in
  firefox* | zen* | waterfox* | librewolf* | palemoon*)
    is_firefox=true
    ;;
  esac
  if [[ $is_chromium == false && $is_firefox == false && $browser == userapp-* ]]; then
    case ${browser,,} in
    *chromium* | *chrome* | *brave* | *edge* | *opera* | *vivaldi* | *helium*)
      is_chromium=true
      ;;
    *firefox* | *zen* | *waterfox* | *librewolf* | *palemoon*)
      is_firefox=true
      ;;
    esac
  fi

  if [[ $is_chromium == true || $is_firefox == true ]]; then
    exec_bin=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' \
      "$HOME/.local/share/applications/$browser" "/usr/share/applications/$browser" 2>/dev/null | head -1)
  fi

  if [[ -z $exec_bin ]]; then
    for candidate in chromium google-chrome-stable google-chrome brave vivaldi microsoft-edge-stable helium; do
      if command -v "$candidate" >/dev/null; then
        exec_bin=$candidate
        is_chromium=true
        break
      fi
    done
  fi
  if [[ -z $exec_bin ]]; then
    for candidate in zen-browser zen firefox waterfox librewolf palemoon; do
      if command -v "$candidate" >/dev/null; then
        exec_bin=$candidate
        is_firefox=true
        break
      fi
    done
  fi
fi

if [[ -z $exec_bin ]]; then
  command -v notify-send >/dev/null && notify-send "Web app" "No supported browser found"
  exit 1
fi

# ── Launch ───────────────────────────────────────────────────────────────────
if [[ $is_chromium == true ]]; then
  exec setsid "$exec_bin" --app="$url" "$@"
elif [[ $is_firefox == true ]]; then
  exec setsid "$exec_bin" --new-window "$url" "$@"
else
  exec setsid "$exec_bin" --app="$url" "$@"
fi
