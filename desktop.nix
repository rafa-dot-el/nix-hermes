# desktop.nix — the three desktop-facing packages built from hermesFull's
# packaged Electron app (hermesFull.passthru.hermesDesktop):
#
#   hermes-desktop-x11      hermesDesktop wrapped with --ozone-platform=x11
#   hermes-desktop-wayland  hermesDesktop wrapped with --ozone-platform=wayland
#   hermes-desktop          launcher: picks x11/wayland at runtime by session
{ pkgs, hermesDesktop }:

let
  mkVariant = platform:
    pkgs.writeShellScriptBin "hermes-desktop" ''
      exec ${hermesDesktop}/bin/hermes-desktop --ozone-platform=${platform} "$@"
    '';

  hermes-desktop-x11 = mkVariant "x11";
  hermes-desktop-wayland = mkVariant "wayland";

  # WAYLAND_DISPLAY is set by the compositor whenever a Wayland session is
  # available (including XWayland fallback cases); XDG_SESSION_TYPE is the
  # authoritative session-manager-reported type. Check both since either can
  # be unset depending on how the session was started.
  hermes-desktop = pkgs.writeShellScriptBin "hermes-desktop" ''
    if [ -n "''${WAYLAND_DISPLAY:-}" ] || [ "''${XDG_SESSION_TYPE:-}" = "wayland" ]; then
      exec ${hermes-desktop-wayland}/bin/hermes-desktop "$@"
    else
      exec ${hermes-desktop-x11}/bin/hermes-desktop "$@"
    fi
  '';
in
{
  inherit hermes-desktop-x11 hermes-desktop-wayland hermes-desktop;
}
