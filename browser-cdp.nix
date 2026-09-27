# hermes-ensure-browser-debug — idempotent preflight so Hermes's browser
# tools (browser_exec via Browser Use/browser-harness, and the built-in
# browser_* tools) work with zero manual steps on a machine that has never
# opened a browser.
#
# Root cause (verified against the pinned browser-harness v0.1.9 source,
# browser_harness/daemon.py + admin.py): its "is a browser running" check and
# its launch fallback only recognize a browser holding one of a few standard
# profile dirs (~/.config/{google-chrome,chromium,microsoft-edge}). A
# Chromium started on any other --user-data-dir is invisible to it, and
# plain open-source Chromium has no "Allow remote debugging?" toggle for it
# to fall back to either — so on a fresh NixOS profile this can never
# succeed on its own.
#
# Rather than patch that pinned dependency, this sidesteps it: Hermes itself
# already ships a first-class, higher-precedence override for exactly this —
# BROWSER_CDP_URL env / browser.cdp_url in config.yaml (see
# tools/browser_tool.py:_get_cdp_override and
# tools/browser_use_cli.py:_resolve_backend_cdp in hermes-agent's own
# source, both of which translate it into BU_CDP_URL for browser-harness).
# This script's only job is to make a Chromium from THIS flake actually
# listening there before Hermes execs, so that override is always live.
#
# Prints the resolved http://127.0.0.1:<port> CDP URL on success (the
# --run hook in default.nix exports it as BROWSER_CDP_URL); prints nothing
# and always exits 0 otherwise (no display, a squatted port, a slow-starting
# browser, …) so a failure here degrades to today's behavior instead of
# breaking `hermes` outright.
{ writeShellScriptBin, chromium, util-linux, curl }:

writeShellScriptBin "hermes-ensure-browser-debug" ''
  set -uo pipefail

  # An override already in effect anywhere — this process's own env, a live
  # `/browser connect`, or Browser Use's own BU_CDP_* vars — is authoritative;
  # never second-guess it.
  if [ -n "''${BROWSER_CDP_URL:-}" ] || [ -n "''${BU_CDP_URL:-}" ] || [ -n "''${BU_CDP_WS:-}" ]; then
    exit 0
  fi

  hermes_home="''${HERMES_HOME:-$HOME/.hermes}"

  # A persistent browser.cdp_url in config.yaml is just as authoritative as
  # the live env override above — back off rather than shadow the user's
  # own choice with ours.
  config_file="$hermes_home/config.yaml"
  if [ -f "$config_file" ] \
     && grep -qE '^[[:space:]]*cdp_url[[:space:]]*:[[:space:]]*[^[:space:]#]' "$config_file" 2>/dev/null; then
    exit 0
  fi

  # A "profile" is whatever sets HERMES_HOME (nixos/dashboard.nix gives the
  # dashboard and gateway services their own; a multi-profile CLI setup sets
  # it per invocation), so the default dir already varies per profile; these
  # two are the explicit escape hatch for a profile that wants its own
  # port/dir independent of HERMES_HOME too. Two profiles that share a host
  # AND the default port share one debug browser (matching what Hermes's own
  # `/browser connect` already does for any two callers on the same port) —
  # override HERMES_BROWSER_DEBUG_PORT too for real isolation between them.
  port="''${HERMES_BROWSER_DEBUG_PORT:-9222}"
  data_dir="''${HERMES_BROWSER_DEBUG_DIR:-$hermes_home/chrome-debug}"

  # A real HTTP GET, not just a TCP connect — matching how Hermes's own
  # is_browser_debug_ready()/discover_local_cdp_url() (hermes_cli/browser_connect.py)
  # decide a debug Chromium is ready. Verified against the pinned Chromium
  # (149.0.7827.200): it does NOT reliably write a DevToolsActivePort file
  # under these flags, so that would-be-tidier per-directory liveness check
  # was tried first and dropped; a hand-rolled bash /dev/tcp HTTP client was
  # tried next and also proved unreliable (connects, but the response body
  # comes back empty even against a confirmed-live Chromium) — curl is the
  # one that actually works, so this uses it rather than re-rolling HTTP.
  cdp_ready() {
    ${curl}/bin/curl -fsS --max-time 2 "http://127.0.0.1:$port/json/version" 2>/dev/null \
      | grep -q webSocketDebuggerUrl
  }

  if ! cdp_ready; then
    mkdir -p "$data_dir"
    ${util-linux}/bin/setsid ${chromium}/bin/chromium \
      --remote-debugging-port="$port" \
      --user-data-dir="$data_dir" \
      --no-first-run \
      --no-default-browser-check \
      about:blank \
      >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    for _ in {1..20}; do
      cdp_ready && break
      sleep 0.5
    done
  fi

  cdp_ready && printf 'http://127.0.0.1:%s\n' "$port"
  exit 0
''
