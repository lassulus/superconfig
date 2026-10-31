{
  config,
  pkgs,
  ...
}:
{
  lass.ports = {
    "3200" = "docuseal";
    ${toString config.services.docuseal.redis.port} = "redis-docuseal";
  };
  services.docuseal = {
    enable = true;
    host = "127.0.0.1";
    port = config.lass.servicePorts.docuseal;
    extraConfig = {
      SMTP_ADDRESS = "localhost";
      SMTP_PORT = toString config.lass.servicePorts.postfix-smtp;
      SMTP_DOMAIN = "lassul.us";
      SMTP_ENABLE_STARTTLS = "false";
    };
  };

  clan.core.vars.generators.docuseal = {
    files.secret-key-base = { };
    runtimeInputs = [ pkgs.openssl ];
    script = ''
      openssl rand -hex 64 | tr -d '\n' > $out/secret-key-base
    '';
  };

  services.docuseal.secretKeyBaseFile = "/run/credentials/docuseal.service/secret-key-base";

  systemd.services.docuseal.serviceConfig = {
    LoadCredential = "secret-key-base:${config.clan.core.vars.generators.docuseal.files.secret-key-base.path}";
    # relax syscall filter — Rails/Ruby needs more syscalls than the default allows
    SystemCallFilter = pkgs.lib.mkForce [ ];
    SystemCallArchitectures = pkgs.lib.mkForce "";
  };

  services.nginx.virtualHosts."docuseal.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString config.services.docuseal.port}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };
}
