# Shared browser sessions (tools/browser-sessions): sandboxed Firefox
# sessions on the backends, watched and controlled from any browser through
# neko and used by agents over MCP. The proxy holds the public name and
# address and forwards everything to the backends over retiolum, since they
# may sit behind routers that drop incoming connections. Imported by
# host.nix (on each backend) and proxy.nix.
{
  domain = "browser.lassul.us";
  proxy = "neoprism";
  # Session hosts by hostname: up to `slots` parallel sessions. The gateway
  # listens on firstPort; then follow blocks of `slots` ports each: neko,
  # MCP and WebRTC (UDP, forwarded by the proxy).
  backends.atlas = {
    slots = 8;
    firstPort = 8950;
  };
}
