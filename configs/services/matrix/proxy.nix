{ config, ... }:
{
  services.nginx = {
    virtualHosts = {
      "lassul.us" = {
        locations."= /.well-known/matrix/server".extraConfig = ''
          add_header Content-Type application/json;
          return 200 '${
            builtins.toJSON {
              "m.server" = "matrix.lassul.us:443";
            }
          }';
        '';
        locations."= /.well-known/matrix/client".extraConfig = ''
          add_header Content-Type application/json;
          add_header Access-Control-Allow-Origin *;
          return 200 '${
            builtins.toJSON {
              "m.homeserver" = {
                "base_url" = "https://matrix.lassul.us";
              };
              "m.identity_server" = {
                "base_url" = "https://vector.im";
              };
            }
          }';
        '';
      };
      "matrix.lassul.us" = {
        forceSSL = true;
        enableACME = true;
        locations."/_matrix" = {
          proxyPass = "http://[::1]:${toString config.lass.servicePorts.matrix-synapse}";
          # Without this Synapse sees every client as ::1, because
          # `x_forwarded = true` falls back to the peer address when no
          # X-Forwarded-For arrives. rc_login.address then becomes a single
          # global bucket: one person mistyping a password five times locks
          # out login for everyone, bridges included.
          recommendedProxySettings = true;
        };
      };
    };
  };
}
