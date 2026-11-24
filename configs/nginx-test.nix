# configs/nginx.nix with vhosts shaped like neoprism's: a normal forceSSL
# vhost, a regex server_name one like crit-review (configs/crit-proxy.nix)
# and an addSSL one. Unknown names must get no certificate on 443 and a 404
# on 80; HTTPS-only vhosts send HSTS exactly once, also from locations with
# their own add_header and behind an app sending its own.
{ pkgs }:
let
  certs = pkgs.runCommand "nginx-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=known.test \
      -addext "subjectAltName=DNS:known.test,DNS:*.review.test,DNS:plain.test" \
      -keyout $out/key.pem -out $out/cert.pem
  '';
  tls = {
    sslCertificate = "${certs}/cert.pem";
    sslCertificateKey = "${certs}/key.pem";
  };
in
pkgs.testers.runNixOSTest {
  name = "nginx";
  nodes.machine = {
    imports = [
      ../modules/ports.nix
      ./nginx.nix
    ];
    environment.systemPackages = [ pkgs.openssl ];
    services.nginx.virtualHosts = {
      "known.test" = tls // {
        forceSSL = true;
        locations."/".return = "200 known";
        # a location with its own add_header drops the server's without
        # add_header_inherit merge
        locations."/own-header".extraConfig = ''
          add_header X-Own yes;
          return 200 own;
        '';
        locations."/app".proxyPass = "http://127.0.0.1:8081";
      };
      review = tls // {
        serverName = ''"~^[a-z0-9]{10}\.review\.test$"'';
        forceSSL = true;
        locations."/".return = "200 review";
      };
      "plain.test" = tls // {
        addSSL = true;
        locations."/".return = "200 plain";
      };
      # an app that sends its own HSTS
      app = {
        listen = [
          {
            addr = "127.0.0.1";
            port = 8081;
          }
        ];
        locations."/".extraConfig = ''
          add_header Strict-Transport-Security "max-age=60";
          return 200 app;
        '';
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("nginx.service")
    machine.wait_for_open_port(443)

    def curl(name, url, ip="127.0.0.1"):
        port = 443 if url.startswith("https") else 80
        return machine.succeed(
            f"curl -sk -D - -o /dev/null -w '%{{http_code}}' "
            f"--resolve {name}:{port}:{ip} {url}"
        )

    def hsts(headers):
        # lowercased: HTTP/2 sends lowercase header names anyway
        return [line.strip().lower() for line in headers.splitlines()
                if line.lower().startswith("strict-transport-security:")]

    with subtest("known name: 200 + HSTS, on v4 and v6"):
        for ip in ["127.0.0.1", "[::1]"]:
            out = curl("known.test", "https://known.test/", ip)
            assert out.endswith("200"), out
            assert hsts(out) == ["strict-transport-security: max-age=31536000"], out

    with subtest("location with its own add_header keeps HSTS"):
        out = curl("known.test", "https://known.test/own-header")
        assert "x-own: yes" in out.lower(), out
        assert hsts(out) == ["strict-transport-security: max-age=31536000"], out

    with subtest("app's own HSTS is not doubled"):
        out = curl("known.test", "https://known.test/app")
        assert out.endswith("200"), out
        assert hsts(out) == ["strict-transport-security: max-age=60"], out

    with subtest("regex name (crit-review): 200 + HSTS"):
        out = curl("abcdefghij.review.test", "https://abcdefghij.review.test/")
        assert out.endswith("200"), out
        assert len(hsts(out)) == 1, out

    with subtest("addSSL vhost: no HSTS"):
        out = curl("plain.test", "https://plain.test/")
        assert out.endswith("200") and hsts(out) == [], out
        assert curl("plain.test", "http://plain.test/").endswith("200")

    with subtest("unknown name over TLS: handshake refused, no certificate"):
        for ip in ["127.0.0.1", "[::1]"]:
            for name in ["unknown.test", "toolong123x.review.test"]:
                rc, out = machine.execute(
                    f"curl -sSk --resolve {name}:443:{ip} https://{name}/ 2>&1"
                )
                assert rc == 35, (rc, out)
                # ssl_reject_handshake answers with the unrecognized_name alert
                assert "unrecognized name" in out, out
        out = machine.succeed(
            "openssl s_client -connect 127.0.0.1:443 -servername unknown.test"
            " </dev/null 2>&1 || true"
        )
        assert "no peer certificate available" in out, out

    with subtest("unknown name over HTTP: 404"):
        assert curl("unknown.test", "http://unknown.test/").endswith("404")
        assert curl("known.test", "http://known.test/").endswith("301")
  '';
}
