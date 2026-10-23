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
# Chromium-family only: --app mode (no tabs, no URL bar)

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

# PATH in .desktop environments often misses ~/.local/bin.
localBin() {
  [[ -x "$HOME/.local/bin/$1" ]] && { printf '%s\n' "$HOME/.local/bin/$1"; return 0; }
  return 1
}
tryBin() {
  command -v "$1" 2>/dev/null || localBin "$1"
}

if [[ -n $backend ]]; then
  # Settings-friendly names normalize to the real binary (helium-browser -> helium).
  exec_bin=$(tryBin "$backend")
  if [[ -z $exec_bin ]]; then
    exec_bin=$(tryBin "${backend%-browser}")
  fi
  if [[ -z $exec_bin ]]; then
    exec_bin=$(tryBin "${backend%-browser-bin}")
  fi
  if [[ -z $exec_bin ]]; then
    exec_bin=$(tryBin "${backend%-bin}")
  fi
  # Short name for -browser packages (helium -> helium-browser).
  if [[ -z $exec_bin ]]; then
    exec_bin=$(tryBin "${backend}-browser")
  fi
fi

# Auto-detect if no backend or binary not found
if [[ -z $exec_bin ]]; then
  browser=$(xdg-settings get default-web-browser 2>/dev/null)

  case $browser in
  chromium* | chrome* | google-chrome* | brave* | microsoft-edge* | opera* | vivaldi* | helium*)
    exec_bin=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' \
      "$HOME/.local/share/applications/$browser" "/usr/share/applications/$browser" 2>/dev/null | head -1)
    exec_bin=${exec_bin//\"/}
    ;;
  userapp-*)
    case ${browser,,} in
    *chromium* | *chrome* | *brave* | *edge* | *opera* | *vivaldi* | *helium*)
      exec_bin=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' \
        "$HOME/.local/share/applications/$browser" "/usr/share/applications/$browser" 2>/dev/null | head -1)
      exec_bin=${exec_bin//\"/}
      ;;
    esac
    ;;
  esac

  if [[ -z $exec_bin ]]; then
    for candidate in chromium google-chrome-stable google-chrome brave vivaldi microsoft-edge-stable helium; do
      if tryBin "$candidate" >/dev/null; then
        exec_bin=$candidate
        break
      fi
    done
  fi
fi

if [[ -z $exec_bin ]]; then
  command -v notify-send >/dev/null && notify-send "Web app" "No supported browser found (Chromium-family only)"
  exit 1
fi

# ── Launch ───────────────────────────────────────────────────────────────────
exec setsid "$exec_bin" --app="$url" "$@"
