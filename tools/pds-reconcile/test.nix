# pds-reconcile against Tranquil (the package of pds.lassul.us) with a stub
# Zitadel (user search) and a stub PLC directory.
{ self, pkgs }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  stubs = pkgs.writeScript "stubs" ''
    #!${pkgs.python3}/bin/python3
    import json, sys, threading, urllib.parse
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    # email -> Zitadel user
    USERS = {
        "alice@example.org": {"id": "111", "userName": "alice@example.org",
                       "state": "USER_STATE_ACTIVE",
                       "human": {"email": {"email": "alice@example.org",
                                           "isEmailVerified": True}}},
        # created by zitadel-invite, invite pending
        "carol@example.org": {"id": "333", "userName": "carol@example.org",
                       "state": "USER_STATE_INITIAL",
                       "human": {"email": {"email": "carol@example.org"}}},
        # registered herself, address unverified
        "mallory@example.org": {"id": "666", "userName": "mallory@example.org",
                         "state": "USER_STATE_ACTIVE",
                         "human": {"email": {"email": "mallory@example.org"}}},
        "dave@example.org": {"id": "444", "userName": "dave@example.org",
                      "state": "USER_STATE_ACTIVE",
                      "human": {"email": {"email": "dave@example.org",
                                          "isEmailVerified": True}}},
    }
    OPS = {}


    class Handler(BaseHTTPRequestHandler):
        def reply(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            return json.loads(self.rfile.read(int(self.headers["Content-Length"])))


    class Zitadel(Handler):
        def do_GET(self):
            self.reply({})

        def do_POST(self):
            assert self.headers["Authorization"] == "Bearer zitadel-pat"
            assert self.path == "/management/v1/users/_search", self.path
            email = self.body()["queries"][0]["emailQuery"]["emailAddress"]
            user = USERS.get(email.lower())
            self.reply({"result": [user] if user else []})


    class Plc(Handler):
        def do_POST(self):
            OPS[urllib.parse.unquote(self.path[1:])] = self.body()
            self.reply({})

        def do_GET(self):
            did = urllib.parse.unquote(self.path[1:])
            op = OPS.get(did)
            if op is None:
                self.send_error(404)
                return
            self.reply({
                "@context": ["https://www.w3.org/ns/did/v1"],
                "id": did,
                "alsoKnownAs": op["alsoKnownAs"],
                "verificationMethod": [{
                    "id": did + "#atproto",
                    "type": "Multikey",
                    "controller": did,
                    "publicKeyMultibase":
                        op["verificationMethods"]["atproto"][len("did:key:"):],
                }],
                "service": [{
                    "id": "#atproto_pds",
                    "type": "AtprotoPersonalDataServer",
                    "serviceEndpoint":
                        op["services"]["atproto_pds"]["endpoint"],
                }],
            })


    for port, handler in [(8080, Zitadel), (2582, Plc)]:
        server = ThreadingHTTPServer(("127.0.0.1", port), handler)
        threading.Thread(target=server.serve_forever).start()
  '';
in
pkgs.testers.runNixOSTest {
  name = "pds-reconcile";
  nodes.machine =
    { config, ... }:
    let
      cfg = config.services.tranquil-pds;
    in
    {
      virtualisation.memorySize = 2048;
      environment.systemPackages = [ pkgs.curl ];
      services.tranquil-pds = {
        enable = true;
        package = self.packages.${system}.tranquil-pds;
        database.createLocally = true;
        settings = {
          server = {
            hostname = "pds.test";
            invite_code_required = false;
            disable_rate_limiting = true;
            enable_caddy_on_demand_tls = false;
          };
          plc.directory_url = "http://127.0.0.1:2582";
          secrets = {
            jwt_secret = "test-jwt-secret-must-be-32-chars-long";
            dpop_secret = "test-dpop-secret-must-be-32-chars-long";
            master_key = "test-master-key-must-be-32-chars-long";
            allow_insecure = true;
          };
        };
      };
      systemd.services.tranquil-pds = {
        requires = [ "stubs.service" ];
        after = [ "stubs.service" ];
      };
      systemd.services.stubs.serviceConfig.ExecStart = stubs;
      environment.etc."zitadel-pat".text = "zitadel-pat";
      # as in configs/services/git/pds.nix, with the config in /run
      systemd.services.pds-reconcile = {
        requires = [ "tranquil-pds.service" ];
        after = [ "tranquil-pds.service" ];
        path = [ config.services.postgresql.package ];
        environment.PYTHONUNBUFFERED = "1";
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          LoadCredential = "zitadel-token:/etc/zitadel-pat";
          ExecStart = "${lib.getExe self.packages.${system}.pds-reconcile} /run/pds-reconcile.json";
          StateDirectory = "pds-reconcile";
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
      };
    };

  testScript = ''
    import json

    KEY1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKoO181Z9NikLcZcNma4swobqS4xq2QEwAlSZXOWe5Jl carol@laptop"
    KEY2 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHG7tqRaCycEEMvsF0SuIAosplU7ZZT8i+iecMkxzZIx carol@phone"


    def configure(accounts):
        config = {
            "zitadel": {
                "url": "http://127.0.0.1:8080",
                "domain": "id.test",
                "tokenFile": "/run/credentials/pds-reconcile.service/zitadel-token",
            },
            "pds": {
                "url": "http://127.0.0.1:3000",
                "hostname": "pds.test",
                "database": "postgresql:///tranquil-pds?host=/run/postgresql",
            },
            "stateFile": "/var/lib/pds-reconcile/keys.json",
            "accounts": accounts,
        }
        machine.succeed(f"echo {json.dumps(json.dumps(config))} > /run/pds-reconcile.json")


    def reconcile(ok=True):
        cmd = "systemctl start pds-reconcile"
        (machine.succeed if ok else machine.fail)(cmd)
        machine.succeed("journalctl --sync")
        out = machine.succeed(
            "journalctl -u pds-reconcile -o cat --no-pager"
            " --cursor-file=/tmp/journal-cursor"
        )
        print(out)
        return out


    def sql(query):
        return machine.succeed(
            f"sudo -u tranquil-pds psql -X -At -d tranquil-pds -c \"{query}\""
        ).strip()


    def keys(handle):
        res = json.loads(machine.succeed(
            "curl -sf 'http://127.0.0.1:3000/xrpc/com.atproto.repo.listRecords"
            f"?repo={handle}.pds.test&collection=org.tangled.key.sshKey'"
        ))
        return {r["value"]["publicKey"] for r in res["records"]}


    machine.wait_for_unit("tranquil-pds.service")
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:3000/xrpc/_health")

    configure({
        "alice@example.org": {"handle": "alice", "sshKeys": []},
        "carol@example.org": {"handle": "carol", "sshKeys": [KEY1]},
        "dave@example.org": {"handle": None, "sshKeys": []},
    })
    out = reconcile()
    assert "account alice@example.org: created alice.pds.test" in out
    assert "account carol@example.org: created carol.pds.test" in out
    assert "account dave@example.org: none yet" in out

    with subtest("accounts linked to the Zitadel users, addresses verified"):
        links = sql(
            "SELECT u.handle, u.email, e.provider, e.provider_user_id,"
            " e.provider_email_verified, u.email_verified"
            " FROM users u JOIN external_identities e ON e.did = u.did"
            " ORDER BY u.handle"
        )
        print(links)
        assert links.splitlines() == [
            "alice.pds.test|alice@example.org|oidc|111|t|t",
            "carol.pds.test|carol@example.org|oidc|333|t|t",
        ], links
        assert sql("SELECT count(*) FROM sso_pending_registration") == "0"
        assert sql("SELECT count(*) FROM app_passwords") == "0"

    with subtest("ssh key record"):
        assert keys("carol") == {KEY1}
        assert keys("alice") == set()

    with subtest("second run changes nothing"):
        rev = sql("SELECT repo_rev FROM repos ORDER BY user_id")
        out = reconcile()
        assert "created" not in out and "key" not in out, out
        assert sql("SELECT repo_rev FROM repos ORDER BY user_id") == rev

    with subtest("key replaced"):
        configure({
            "alice@example.org": {"handle": "alice", "sshKeys": []},
            "carol@example.org": {"handle": "carol", "sshKeys": [KEY2]},
        })
        out = reconcile()
        assert "removed key" in out and "added key" in out, out
        assert keys("carol") == {KEY2}
        assert sql("SELECT count(*) FROM app_passwords") == "0"

    with subtest("unverified address: no account"):
        configure({"mallory@example.org": {"handle": "mallory", "sshKeys": []}})
        out = reconcile()
        assert "account mallory@example.org: 0 Zitadel users" in out, out
        assert sql("SELECT count(*) FROM users") == "2"

    with subtest("no takeover of an unlinked account by handle"):
        configure({"dave@example.org": {"handle": "alice", "sshKeys": []}})
        out = reconcile(ok=False)
        assert "account alice.pds.test has this handle" in out, out
        assert sql("SELECT count(*) FROM users") == "2"
  '';
}
