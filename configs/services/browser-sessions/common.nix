# Shared browser sessions (tools/browser-sessions): sandboxed Firefox
# sessions on the backends, watched and controlled from any browser through
# neko and used by agents over MCP. The proxy holds the public name and
# address and runs the gateway: the page, the login, the sessions with their
# tokens. It drives the backends and forwards the links to them over
# retiolum, since they may sit behind routers that drop incoming
# connections. Imported by host.nix (on each backend) and proxy.nix.
{
  domain = "browser.lassul.us";
  proxy = "neoprism";
  # the gateway on the proxy, behind nginx
  gatewayPort = 8949;
  # Session hosts by hostname: up to `slots` parallel sessions. The backend
  # listens on firstPort for the gateway; then follow blocks of `slots`
  # ports each: neko, MCP and WebRTC (UDP, forwarded by the proxy, so these
  # must differ between backends).
  backends.atlas = {
    slots = 8;
    firstPort = 8950;
  };
  backends.styx = {
    slots = 2;
    firstPort = 8975;
  };
}
