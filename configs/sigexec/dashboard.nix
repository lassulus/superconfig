# sigexec dashboard: one page + executor registry + reverse proxy (no key
# material, no job data). nginx terminates TLS and forwards to it; the
# executors themselves live in ./executor.nix on each machine.
#   browser: https://sigexec.lassul.us          (register passkeys at /register)
#   CLI:     sigexec run -x https://sigexec.lassul.us/x/neoprism -- uptime
#     (statements sign the path relative to the base URL, so the executor
#      verifies /jobs after the proxy strips /x/neoprism)
let
  domain = "sigexec.lassul.us";
  dashboardPort = 7501;
  # Must match configs/sigexec/executor.nix.
  executorPort = 7601;
in
{ self, ... }:
{
  imports = [ self.inputs.sigexec.nixosModules.dashboard ];

  services.sigexec-dashboard = {
    enable = true;
    rpId = domain;
    port = dashboardPort;
    executors = {
      # this host's own executor (neoprism also imports ./executor.nix)
      neoprism = "http://127.0.0.1:${toString executorPort}";
      # reached over retiolum (executor port is open on that interface only)
      coaxmetal = "http://coaxmetal.r:${toString executorPort}";
      icarus = "http://icarus.r:${toString executorPort}";
      shodan = "http://shodan.r:${toString executorPort}";
      # over public TLS (set up before starkstrom had a kartei card); its own
      # nginx terminates TLS and strips the /sigexec prefix
      # (machines/starkstrom/config.nix).
      starkstrom = "https://starkstrom.lassul.us/sigexec";
    };
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString dashboardPort}";
      extraConfig = ''
        # Job streams are long-lived chunked responses: unbuffered so output
        # arrives live, and a generous read timeout because `logs` on a
        # pending job legitimately blocks until someone approves it.
        proxy_buffering off;
        proxy_read_timeout 1d;
        proxy_send_timeout 1d;
      '';
    };
  };
}
