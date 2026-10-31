{
  self,
  config,
  pkgs,
  ...
}:
{
  lass.ports = {
    "8008" = "matrix-synapse";
    ${toString config.services.postgresql.settings.port} = "postgresql";
  };

  services.matrix-synapse = {
    enable = true;
    settings = {
      server_name = "lassul.us";
      # Bot accounts (Hermes, bridges) burst many events per turn — thinking
      # panes, reactions, redactions, chunked replies — and hit the default
      # caps (rc_message 1/s burst 10), causing "M_LIMIT_EXCEEDED / Too Many
      # Requests" dropped sends. Raise message + redaction rate limits.
      rc_message = {
        per_second = 100;
        burst_count = 1000;
      };
      rc_admin_redaction = {
        per_second = 100;
        burst_count = 1000;
      };
      # Bridge portal rooms have many ghost users (signal_*, whatsapp_*, ...)
      # join at once, exhausting the per-room join limiter (default 1/s burst
      # 10) and causing "M_LIMIT_EXCEEDED / Too Many Requests / 429" for the
      # human trying to join. Raise join + invite limits to match.
      rc_joins = {
        local = {
          per_second = 100;
          burst_count = 1000;
        };
        remote = {
          per_second = 100;
          burst_count = 1000;
        };
      };
      rc_joins_per_room = {
        per_second = 100;
        burst_count = 1000;
      };
      rc_invites = {
        per_room = {
          per_second = 100;
          burst_count = 1000;
        };
        per_user = {
          per_second = 100;
          burst_count = 1000;
        };
      };
      database = {
        args.user = "matrix-synapse";
        args.database = "matrix-synapse";
        name = "psycopg2";
      };
      turn_uris = [
        "turn:turn.matrix.org?transport=udp"
        "turn:turn.matrix.org?transport=tcp"
      ];
      listeners = [
        {
          port = config.lass.servicePorts.matrix-synapse;
          bind_addresses = [
            "::1"
            self.inputs.kartei.hosts.${config.networking.hostName}.nets.retiolum.ip6.addr
          ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [ "client" ];
              compress = true;
            }
            {
              names = [ "federation" ];
              compress = false;
            }
          ];
        }
      ];
    };
    extraConfigFiles = [
      "/var/lib/matrix-synapse/registration_shared_secret.yaml"
    ];
  };
  systemd.services.matrix-synapse.serviceConfig.ExecStartPre = [
    "+${pkgs.writeScript "copy_registration_shared_secret" ''
      #!/bin/sh
      cp ${
        config.clan.core.vars.generators.matrix-synapse.files."synapse-registration_shared_secret".path
      } /var/lib/matrix-synapse/registration_shared_secret.yaml
      chown matrix-synapse:matrix-synapse /var/lib/matrix-synapse/registration_shared_secret.yaml
      chmod 600 /var/lib/matrix-synapse/registration_shared_secret.yaml
    ''}"
  ];

  clan.core.vars.generators.matrix-synapse = {
    files."synapse-registration_shared_secret" = { };
    runtimeInputs = with pkgs; [
      coreutils
      pwgen
    ];
    script = ''
      echo "registration_shared_secret: $(pwgen -s 32 1)" > "$out"/synapse-registration_shared_secret
    '';
  };

  # TODO add other VPNs here as well
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [
    config.lass.servicePorts.matrix-synapse
  ];

  services.postgresql.enable = true;
  services.postgresql = {
    ensureDatabases = [ "matrix-synapse" ];
    ensureUsers = [
      {
        name = "matrix-synapse";
        ensureDBOwnership = true;
      }
    ];
  };

  lass.backup.state.matrix-synapse = {
    folders = [ "/var/lib/matrix-synapse/media_store/local_content" ];
    # 14GB, compresses well
    preBackup = ''
      mkdir -p /var/backup/postgresql
      ${pkgs.sudo}/bin/sudo -u postgres ${config.services.postgresql.package}/bin/pg_dump \
        matrix-synapse | ${pkgs.gzip}/bin/gzip > /var/backup/postgresql/matrix-synapse.sql.gz
    '';
  };
}
