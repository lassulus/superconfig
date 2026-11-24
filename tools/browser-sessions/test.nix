# The backend on a VM with real sessions (Xorg, pulseaudio, openbox, neko,
# Firefox, browser-mcp) in two slots: a stopped session comes back with its
# tabs and session cookies, and its state moves to the other slot the way
# the gateway moves it between hosts (export, import, start), owned by the
# new slot's user. Driven over the backend API like the gateway does, and
# Firefox over MCP.
{ self, pkgs }:
let
  token = "0123456789abcdef0123456789abcdef";
  mcpToken = "MCPTOKENMCPTOKENMCPTOKEN";
  secrets = pkgs.writeText "secrets.json" (
    builtins.toJSON {
      control_password = "CONTROLPASSWORDCONTROL";
      view_password = "VIEWPASSWORDVIEWPASSWORD";
      mcp_token = mcpToken;
    }
  );
  # /set gives a session cookie, /show shows the cookies sent
  site = pkgs.writers.writePython3 "site" { } ''
    from http.server import BaseHTTPRequestHandler, HTTPServer


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            if self.path == "/set":
                self.send_header("Set-Cookie", "sess=hello; Path=/")
            self.end_headers()
            cookie = self.headers.get("Cookie", "")
            self.wfile.write(f"<p>cookie={cookie}</p>".encode())


    HTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "browser-sessions";
  node.specialArgs = { inherit self; };
  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ./module.nix ];
      # the backup module of the hosts
      options.lass.backup.state = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      config = {
        virtualisation.memorySize = 3072;
        services.browser-sessions = {
          enable = true;
          listen = "127.0.0.1:8950";
          tokenFile = "${pkgs.writeText "token" token}";
          publicAddress = "127.0.0.1";
          privateAddress = "127.0.0.1";
          slots = [
            {
              neko = 8951;
              mcp = 8953;
              webrtc = 8955;
            }
            {
              neko = 8952;
              mcp = 8954;
              webrtc = 8956;
            }
          ];
        };
        systemd.services.site = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = site;
        };
        environment.systemPackages = [ pkgs.curl ];
      };
    };

  testScript = ''
    import json
    import shlex
    from datetime import timedelta

    backend = "curl -sf -H 'Browser-Sessions-Token: ${token}' http://127.0.0.1:8950/slots"


    def mcp_command(slot, tool, args):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}})
        return (
            f"{backend}/{slot}/mcp -H 'Authorization: Bearer ${mcpToken}' -H 'Content-Type: application/json'"
            f" -H 'Accept: application/json, text/event-stream' --data-binary {shlex.quote(body)}"
        )


    def mcp(slot, tool, **args):
        result = json.loads(machine.succeed(mcp_command(slot, tool, args)))["result"]
        text = result["content"][0]["text"]
        assert not result.get("isError"), text
        return text


    def start(slot, fresh=False):
        query = "?fresh" if fresh else ""
        machine.succeed(f"{backend}/{slot}{query} -X PUT --data @${secrets}")
        machine.wait_until_succeeds(f"{backend}/{slot}", timeout=120)

        # the extension connects a bit later
        def tabs(_):
            status, out = machine.execute(mcp_command(slot, "list_tabs", {}))
            try:
                return status == 0 and not json.loads(out)["result"].get("isError")
            except (ValueError, KeyError):
                return False

        retry(tabs, timeout=timedelta(minutes=2))


    def show_tab(slot):
        tabs = json.loads(mcp(slot, "list_tabs"))
        return next((t["id"] for t in tabs if t["url"].endswith("/show")), None)


    def cookie_after_reload(slot):
        tab = show_tab(slot)
        assert tab is not None, f"no /show tab in slot {slot}: {mcp(slot, 'list_tabs')}"
        mcp(slot, "reload", tab_id=tab)
        return mcp(slot, "get_text", tab_id=tab)


    machine.wait_for_unit("browser-sessions.service")
    machine.wait_for_unit("site.service")
    machine.wait_for_open_port(8000)

    with subtest("a stopped session comes back with its tabs and session cookies"):
        start(0, fresh=True)
        mcp(0, "open_tab", url="http://127.0.0.1:8000/set", active=True)
        tab = json.loads(mcp(0, "list_tabs"))
        set_tab = next(t["id"] for t in tab if t["url"].endswith("/set"))
        mcp(0, "navigate", tab_id=set_tab, url="http://127.0.0.1:8000/show")
        assert "cookie=sess=hello" in mcp(0, "get_text", tab_id=set_tab)
        # Firefox writes its session store every 15 s
        machine.sleep(20)
        machine.succeed(f"{backend}/0/stop -X POST")
        machine.fail("systemctl is-active browser-session@0.service")
        machine.fail("test -e /var/lib/browser-sessions/slots/0.env")
        machine.succeed("test -d /var/lib/private/browser-session/0/profile")
        machine.fail(f"{backend}/0")
        start(0)
        text = cookie_after_reload(0)
        assert "cookie=sess=hello" in text, text

    with subtest("the state of a running session does not leave"):
        code = machine.succeed("curl -s -o /dev/null -w '%{http_code}' -H 'Browser-Sessions-Token: ${token}' http://127.0.0.1:8950/slots/0/state")
        assert code == "409", code

    with subtest("a move takes the state to another slot"):
        machine.sleep(20)
        machine.succeed(f"{backend}/0/stop -X POST")
        machine.succeed(f"{backend}/0/state -o /tmp/state.tar")
        machine.succeed("tar -tf /tmp/state.tar | grep '^./profile/' > /dev/null")
        machine.succeed(f"{backend}/1/state -X PUT --data-binary @/tmp/state.tar")
        start(1)
        # the files on disk belong to whom they belonged in the old slot
        # (the dynamic users' state is idmapped), so the session can use them
        owners = {
            slot: set(machine.succeed(f"find /var/lib/private/browser-session/{slot} -printf '%U:%G\\n'").split())
            for slot in (0, 1)
        }
        print(owners)
        assert len(owners[1]) == 1 and owners[0] == owners[1], owners
        text = cookie_after_reload(1)
        assert "cookie=sess=hello" in text, text
        machine.succeed(f"{backend}/0 -X DELETE")
        machine.fail("test -e /var/lib/private/browser-session/0")

    with subtest("a fresh start drops what was left in the slot"):
        machine.succeed(f"{backend}/1/stop -X POST")
        start(1, fresh=True)
        assert show_tab(1) is None, mcp(1, "list_tabs")
  '';
}
