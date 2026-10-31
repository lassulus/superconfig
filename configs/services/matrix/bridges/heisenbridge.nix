{ config, ... }:
{
  lass.ports."9898" = "heisenbridge";
  services.heisenbridge = {
    enable = true;
    homeserver = "http://[::1]:${toString config.lass.servicePorts.matrix-synapse}";
    address = "127.0.0.1";
    port = config.lass.servicePorts.heisenbridge;
    registrationUrl = "http://127.0.0.1:${toString config.lass.servicePorts.heisenbridge}";
    owner = "@lassulus:lassul.us";
    namespaces = {
      users = [
        {
          regex = "@irc_.*:lassul\\.us";
          exclusive = true;
        }
      ];
    };
  };

  # heisenbridge module chgrps the registration file to matrix-synapse, but
  # does NOT add it to synapse's app_service_config_files. Wire that up.
  services.matrix-synapse.settings.app_service_config_files = [
    "/var/lib/heisenbridge/registration.yml"
  ];

  lass.backup.state.heisenbridge.folders = [ "/var/lib/heisenbridge" ];
}
