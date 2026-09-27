# hermes-browser: launches the pinned Chromium headful with an explicit CDP
# debug port and a persistent, named user-data-dir, so a Hermes profile has a
# real browser to attach to via `browser.cdp_url` in its config.yaml.
# Chromium's own default-launch/profile-scan auto-discovery (browser-harness)
# does not see custom --user-data-dir locations, so this script (plus an
# explicit cdp_url on the Hermes side) replaces that discovery, not extends it.
{ writeShellScriptBin, chromium }:

writeShellScriptBin "hermes-browser" ''
  set -euo pipefail
  profile="''${1:-}"
  port="''${2:-}"
  if [ -z "$profile" ] || [ -z "$port" ]; then
    echo "usage: hermes-browser <profile> <port>" >&2
    exit 1
  fi
  data_dir="$HOME/.hermes/browser-profiles/$profile"
  mkdir -p "$data_dir"
  exec ${chromium}/bin/chromium \
    --remote-debugging-port="$port" \
    --user-data-dir="$data_dir" \
    --no-first-run \
    --no-default-browser-check \
    about:blank
''
