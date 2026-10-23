#!/bin/bash

# Scan installed browsers and output a list of available backends.
# Output format: one line per browser, "BinaryName (/path/to/binary)"
# Both Chromium-family (--app) and Firefox-family (--new-window) are listed.

found=()

# ── Chromium-family ──────────────────────────────────────────────────────────
for candidate in chromium google-chrome-stable google-chrome brave vivaldi microsoft-edge-stable microsoft-edge helium; do
  path=$(command -v "$candidate" 2>/dev/null)
  if [[ -n $path ]]; then
    # Deduplicate (e.g. google-chrome and google-chrome-stable may resolve to same)
    already=false
    for existing in "${found[@]}"; do
      if [[ $existing == "$path" ]]; then
        already=true
        break
      fi
    done
    if [[ $already == false ]]; then
      found+=("$path")
    fi
  fi
done

# ── Firefox-family ───────────────────────────────────────────────────────────
for candidate in zen-browser zen firefox waterfox librewolf palemoon; do
  path=$(command -v "$candidate" 2>/dev/null)
  if [[ -n $path ]]; then
    already=false
    for existing in "${found[@]}"; do
      if [[ $existing == "$path" ]]; then
        already=true
        break
      fi
    done
    if [[ $already == false ]]; then
      found+=("$path")
    fi
  fi
done

# ── Output ───────────────────────────────────────────────────────────────────
for path in "${found[@]}"; do
  name=$(basename "$path")
  echo "$name ($path)"
done
