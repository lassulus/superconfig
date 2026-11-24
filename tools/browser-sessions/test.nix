# The backend on a VM with real sessions (Xorg, pulseaudio, openbox, neko,
# Firefox, browser-mcp) in two slots: a stopped session comes back with its
# tabs and session cookies, and its state moves to the other slot the way
# the gateway moves it between hosts (export, import, start), owned by the
# new slot's user. Driven over the backend API like the gateway does, and
# Firefox over MCP. A proxy forwards the WebRTC ports to it like neoprism
# (services.browser-sessions-forward, the backend behind it on its own
# link standing in for retiolum), and a client with only IPv6 gets video
# through it. Then the gateway on the same VM: a session created with
# a proxy URL goes out only through it, names resolved there; changing the
# proxy restarts the running session, which then goes out directly, and
# through the proxy again once it gets it back.
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
  tokenFile = pkgs.writeText "token" token;
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
  # A SOCKS5 proxy that logs where it connects to and alone knows the name
  # site.test, so a page of it loads only through the proxy with the name
  # resolved there.
  socks = pkgs.writers.writePython3 "socks" { } ''
    import select
    import socket
    import socketserver
    import struct

    HOSTS = {"site.test": "127.0.0.1"}


    def read(conn, n):
        data = b""
        while len(data) < n:
            chunk = conn.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data


    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            c = self.request
            _, methods = read(c, 2)
            read(c, methods)
            c.sendall(b"\x05\x00")
            _, _, _, atyp = read(c, 4)
            if atyp == 3:
                host = read(c, read(c, 1)[0]).decode()
            elif atyp == 1:
                host = socket.inet_ntoa(read(c, 4))
            else:
                return
            (port,) = struct.unpack("!H", read(c, 2))
            print(f"CONNECT {host}:{port}", flush=True)
            up = socket.create_connection((HOSTS.get(host, host), port))
            c.sendall(b"\x05\x00\x00\x01" + bytes(6))
            while True:
                ready, _, _ = select.select([c, up], [], [])
                for s in ready:
                    data = s.recv(65536)
                    if not data:
                        return
                    (up if s is c else c).sendall(data)


    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
        daemon_threads = True


    Server(("127.0.0.1", 1080), Handler).serve_forever()
  '';
  # A neko viewer like the browser's: logs in through the backend API (the
  # proxy passes it on like the gateway), takes neko's offer with the
  # candidates it trickles, answers and waits for a video frame. Prints
  # the candidates neko offered and the address the checks succeeded with.
  viewer =
    pkgs.writers.writePython3 "viewer"
      {
        libraries = [
          pkgs.python3Packages.aiohttp
          pkgs.python3Packages.aiortc
        ];
        flakeIgnore = [ "E501" ];
      }
      ''
        import asyncio
        import json
        import sys

        import aiohttp
        from aiortc import RTCPeerConnection, RTCSessionDescription

        base, token, password = sys.argv[1:4]


        async def main():
            async with aiohttp.ClientSession(headers={"Browser-Sessions-Token": token}) as http:
                login = await http.post(f"{base}/neko/api/login", json={"username": "viewer", "password": password})
                login.raise_for_status()
                neko_token = (await login.json())["token"]
                async with http.ws_connect(f"{base}/neko/api/ws?token={neko_token}") as ws:
                    await ws.send_json({"event": "signal/request", "payload": {"video": {}, "audio": {}}})
                    # neko trickles its candidates after the offer
                    offer, candidates = None, []
                    while True:
                        try:
                            msg = await ws.receive_json(timeout=30 if offer is None else 3)
                        except asyncio.TimeoutError:
                            if offer is None:
                                raise
                            break
                        if msg["event"] == "signal/provide":
                            offer = msg["payload"]["sdp"]
                        elif msg["event"] == "signal/candidate":
                            candidates.append(msg["payload"]["candidate"])

                    lines = []
                    for line in offer.split("\r\n"):
                        lines.append(line)
                        if line.startswith("a=mid:"):
                            lines += [f"a={c}" for c in candidates] + ["a=end-of-candidates"]

                    pc = RTCPeerConnection()
                    video = asyncio.get_running_loop().create_future()

                    @pc.on("track")
                    def on_track(track):
                        if track.kind == "video" and not video.done():
                            video.set_result(track)

                    await pc.setRemoteDescription(RTCSessionDescription(sdp="\r\n".join(lines), type="offer"))
                    await pc.setLocalDescription(await pc.createAnswer())
                    await ws.send_json({"event": "signal/answer", "payload": {"sdp": pc.localDescription.sdp}})

                    # keep reading neko's messages (and answering its pings)
                    async def drain():
                        async for _ in ws:
                            pass

                    reader = asyncio.ensure_future(drain())
                    track = await asyncio.wait_for(video, 30)
                    f = await asyncio.wait_for(track.recv(), 60)
                    reader.cancel()
                    ice = pc.getTransceivers()[0].receiver.transport.transport
                    pair = next(iter(ice._connection._nominated.values()))
                    print(json.dumps({
                        "candidates": candidates,
                        "remote": pair.remote_candidate.host,
                        "local": pair.local_candidate.host,
                        "frame": [f.width, f.height],
                    }))
                    await pc.close()


        asyncio.run(main())
      '';
  webrtcPorts = [
    8955
    8956
  ];
  address =
    node: iface: family:
    (pkgs.lib.head node.networking.interfaces.${iface}.${family}.addresses).address;
  # the backup module of the hosts
  backupStub =
    { lib, ... }:
    {
      options.lass.backup.state = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf (lib.types.listOf lib.types.str));
        default = { };
      };
    };
in
pkgs.testers.runNixOSTest {
  name = "browser-sessions";
  node.specialArgs = { inherit self; };
  nodes.machine =
    { pkgs, nodes, ... }:
    {
      imports = [
        ./module.nix
        backupStub
      ];
      config = {
        virtualisation.memorySize = 3072;
        # eth1, the link to the proxy
        virtualisation.vlans = [ 2 ];
        services.browser-sessions = {
          enable = true;
          listen = "0.0.0.0:8950";
          tokenFile = "${tokenFile}";
          publicAddresses = [
            (address nodes.proxy "eth1" "ipv4")
            (address nodes.proxy "eth1" "ipv6")
          ];
          privateAddresses = [
            (address nodes.machine "eth1" "ipv4")
            (address nodes.machine "eth1" "ipv6")
          ];
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
        # the owner cookie is made by the test script with the gateway's
        # cookie key; the issuer is never asked
        services.browser-sessions-gateway = {
          enable = true;
          url = "http://127.0.0.1:8949";
          listen = "127.0.0.1:8949";
          tokenFile = "${tokenFile}";
          oidc = {
            issuer = "http://127.0.0.1:1";
            clientIdFile = "${pkgs.writeText "client-id" "browser-sessions"}";
          };
          backends.machine = {
            url = "http://127.0.0.1:8950";
            slots = 2;
          };
        };
        networking.firewall.interfaces.eth1 = {
          allowedTCPPorts = [ 8950 ] ++ webrtcPorts;
          allowedUDPPorts = webrtcPorts;
        };
        systemd.services.site = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = site;
        };
        systemd.services.socks = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = socks;
        };
        environment.systemPackages = [ pkgs.curl ];
      };
    };

  # eth1 the public side, eth2 the link to the backend; the nftables
  # firewall filters forwarded packets like neoprism's
  nodes.proxy =
    { pkgs, nodes, ... }:
    {
      imports = [
        ./module.nix
        backupStub
      ];
      virtualisation.vlans = [
        1
        2
      ];
      networking.nftables.enable = true;
      networking.firewall.filterForward = true;
      networking.firewall.allowedTCPPorts = [ 8950 ];
      services.browser-sessions-forward = {
        enable = true;
        interface = "eth2";
        backends.machine = {
          addresses = [
            (address nodes.machine "eth1" "ipv4")
            (address nodes.machine "eth1" "ipv6")
          ];
          ports = webrtcPorts;
        };
      };
      # stands in for the gateway behind nginx: the backend API for the viewer
      systemd.services.signaling = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP6-LISTEN:8950,fork,reuseaddr TCP4:${
          address nodes.machine "eth1" "ipv4"
        }:8950";
      };
    };

  nodes.client =
    { lib, ... }:
    {
      virtualisation.vlans = [ 1 ];
      # an IPv6-only network
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
    };

  testScript =
    { nodes, ... }:
    let
      public4 = address nodes.proxy "eth1" "ipv4";
      public6 = address nodes.proxy "eth1" "ipv6";
      backend4 = address nodes.machine "eth1" "ipv4";
      backend6 = address nodes.machine "eth1" "ipv6";
    in
    ''
      import base64
      import hashlib
      import hmac
      import json
      import shlex
      from datetime import timedelta

      backend = "curl -sf -H 'Browser-Sessions-Token: ${token}' http://127.0.0.1:8950/slots"


      def mcp_command(slot, tool, args):
          """slot is a slot of the backend, or a session's MCP link at the gateway."""
          body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": args}})
          target = f"{backend}/{slot}/mcp -H 'Authorization: Bearer ${mcpToken}'" if isinstance(slot, int) else f"curl -sf {slot}"
          return (
              f"{target} -H 'Content-Type: application/json'"
              f" -H 'Accept: application/json, text/event-stream' --data-binary {shlex.quote(body)}"
          )


      def mcp(slot, tool, **args):
          result = json.loads(machine.succeed(mcp_command(slot, tool, args)))["result"]
          text = result["content"][0]["text"]
          assert not result.get("isError"), text
          return text


      def wait_for_tabs(slot):
          """Waits until the extension in the session answers."""

          def tabs(_):
              status, out = machine.execute(mcp_command(slot, "list_tabs", {}))
              try:
                  return status == 0 and not json.loads(out)["result"].get("isError")
              except (ValueError, KeyError):
                  return False

          retry(tabs, timeout=timedelta(minutes=2))


      def start(slot, fresh=False):
          query = "?fresh" if fresh else ""
          machine.succeed(f"{backend}/{slot}{query} -X PUT --data @${secrets}")
          machine.wait_until_succeeds(f"{backend}/{slot}", timeout=120)
          # the extension connects a bit later
          wait_for_tabs(slot)


      def show_tab(slot):
          tabs = json.loads(mcp(slot, "list_tabs"))
          return next((t["id"] for t in tabs if t["url"].endswith("/show")), None)


      def cookie_after_reload(slot):
          tab = show_tab(slot)
          assert tab is not None, f"no /show tab in slot {slot}: {mcp(slot, 'list_tabs')}"
          mcp(slot, "reload", tab_id=tab)
          return mcp(slot, "get_text", tab_id=tab)


      start_all()
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

      with subtest("a client with only IPv6 gets video through the proxy"):
          # neko's UDP mux listens on the backend's address of each family, nowhere else
          sockets = machine.succeed("ss -Hlun 'sport = :8955'")
          print(sockets)
          assert sorted(line.split()[3] for line in sockets.splitlines()) == sorted(["${backend4}:8955", "[${backend6}]:8955"]), sockets
          proxy.wait_for_unit("nftables.service")
          print(proxy.succeed("nft list table inet browser-sessions"))
          proxy.wait_for_unit("signaling.service")
          client.wait_until_succeeds("ping -c1 ${public6}")
          result = json.loads(client.succeed("${viewer} http://[${public6}]:8950/slots/0 ${token} VIEWPASSWORDVIEWPASSWORD"))
          print(result)
          # neko offers the proxy's addresses of both families, over UDP and TCP
          offered = sorted((c.split()[2].lower(), c.split()[4]) for c in result["candidates"])
          assert offered == sorted((t, a) for t in ["udp", "tcp"] for a in ["${public4}", "${public6}"]), result["candidates"]
          assert result["remote"] == "${public6}", result
          assert result["frame"][0] > 0, result

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

      gateway = "http://127.0.0.1:8949"
      socks_url = "socks5h://127.0.0.1:1080"


      def b64(b):
          return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


      def owner_cookie():
          """The gateway's owner cookie for lass, signed with its key."""
          key = machine.succeed("cat /var/lib/browser-sessions/cookie-key").encode()
          payload = b64(json.dumps({"sub": "lass", "exp": 4102444800}).encode())
          sig = b64(hmac.new(key, payload.encode(), hashlib.sha256).digest())
          return f"browser_sessions={payload}.{sig}"


      def post(path, **form):
          """Posts a form to the gateway as the owner: status and body."""
          data = " ".join(f"--data-urlencode {shlex.quote(k + '=' + v)}" for k, v in form.items())
          cookie = shlex.quote("Cookie: " + owner_cookie())
          out = machine.succeed(f"curl -s -w '\\n%{{http_code}}' -H 'Accept: application/json' -H {cookie} {data} {gateway}{path}")
          body, _, status = out.rpartition("\n")
          return int(status), body


      def connects():
          """How often the proxy connected to site.test, once the journal has
          what came so far."""
          machine.sleep(2)
          return int(machine.succeed("journalctl -u socks.service -o cat | grep -c '^CONNECT site.test:' || true"))


      def connects_more(than):
          """Waits until the proxy connected to site.test more often."""
          machine.wait_until_succeeds(
              f"[ $(journalctl -u socks.service -o cat | grep -c '^CONNECT site.test:') -gt {than} ]", timeout=15
          )


      loaded = 0


      def loads(slot, url):
          """Opens url in a new tab and returns whether its page came, with a
          query of its own, so it never comes from the cache."""
          global loaded
          loaded += 1
          tab = json.loads(mcp(slot, "open_tab", url=f"{url}?{loaded}", active=True))["tab"]["id"]
          status, out = machine.execute(mcp_command(slot, "get_text", {"tab_id": tab}))
          print(out)
          return status == 0 and "cookie=" in out


      # how pages' WebRTC sees the host: the candidates of an offer
      candidates_js = """
          const pc = new RTCPeerConnection({iceServers: []});
          pc.createDataChannel("x");
          await pc.setLocalDescription(await pc.createOffer());
          await new Promise((r) => setTimeout(r, 3000));
          return pc.localDescription.sdp.split("\\r\\n").filter((l) => l.startsWith("a=candidate"));
      """


      def candidates(slot):
          tab = next(t["id"] for t in json.loads(mcp(slot, "list_tabs")) if t["url"].startswith("http://127.0.0.1:8000/"))
          return json.loads(mcp(slot, "evaluate", tab_id=tab, code=candidates_js))


      def invocation():
          return machine.succeed("systemctl show -p InvocationID --value browser-session@0.service").strip()


      with subtest("the gateway creates a session with a proxy URL and refuses bad ones"):
          # the gateway's sessions get the slots
          machine.succeed(f"{backend}/1 -X DELETE")
          machine.wait_for_unit("browser-sessions-gateway.service")
          machine.wait_for_open_port(8949)
          machine.wait_for_open_port(1080)
          for bad, why in [
              ("ftp://127.0.0.1:1080", "want http://"),
              ("socks5h://me:pw@127.0.0.1:1080", "proxy logins are not supported"),
              ("127.0.0.1:1080", "not a URL"),
          ]:
              status, body = post("/sessions", proxy=bad)
              assert status == 400 and "bad proxy URL" in body and why in body, (bad, status, body)
          machine.fail("systemctl is-active browser-session@0.service")
          status, body = post("/sessions", proxy=socks_url)
          assert status == 201, (status, body)
          session = json.loads(body)
          gw = session["mcp"]
          wait_for_tabs(gw)
          machine.succeed("grep -x BROWSER_SESSION_PROXY_TYPE=socks5 /var/lib/browser-sessions/slots/0.env")

      with subtest("a session with a proxy goes out through it, names resolved there"):
          assert loads(gw, "http://site.test:8000/show")
          connects_more(0)
          # localhost never goes through a proxy; there pages can run WebRTC
          tab = json.loads(mcp(gw, "open_tab", url="http://127.0.0.1:8000/set", active=True))["tab"]["id"]
          mcp(gw, "navigate", tab_id=tab, url="http://127.0.0.1:8000/show")
          found = candidates(gw)
          print("WebRTC candidates with the proxy:", found)
          assert found == [], found

      with subtest("changing the proxy of a running session restarts it; without one it goes out directly"):
          # Firefox writes its session store every 15 s
          machine.sleep(30)
          before = invocation()
          status, body = post(f"/sessions/{session['id']}/proxy", proxy="")
          assert status == 204, (status, body)
          wait_for_tabs(gw)
          assert invocation() != before, "not restarted"
          machine.fail("grep PROXY /var/lib/browser-sessions/slots/0.env")
          tabs = json.loads(mcp(gw, "list_tabs"))
          tab = next((t["id"] for t in tabs if t["url"] == "http://127.0.0.1:8000/show"), None)
          assert tab is not None, tabs
          mcp(gw, "reload", tab_id=tab)
          text = mcp(gw, "get_text", tab_id=tab)
          assert "cookie=sess=hello" in text, text
          count = connects()
          assert not loads(gw, "http://site.test:8000/show")
          assert connects() == count
          found = candidates(gw)
          print("WebRTC candidates without a proxy:", found)
          assert found != [], "the check sees no candidates at all"

      with subtest("given the proxy again, it restarts and goes out through it"):
          before = invocation()
          status, body = post(f"/sessions/{session['id']}/proxy", proxy=socks_url)
          assert status == 204, (status, body)
          wait_for_tabs(gw)
          assert invocation() != before, "not restarted"
          machine.succeed("grep -x BROWSER_SESSION_PROXY_TYPE=socks5 /var/lib/browser-sessions/slots/0.env")
          count = connects()
          assert loads(gw, "http://site.test:8000/show")
          connects_more(count)
          assert candidates(gw) == []
    '';
}
