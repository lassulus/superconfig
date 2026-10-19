{
  services.heisenbridge = {
    enable = true;
    homeserver = "http://[::1]:8008";
    address = "127.0.0.1";
    port = 9898;
    registrationUrl = "http://127.0.0.1:9898";
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
