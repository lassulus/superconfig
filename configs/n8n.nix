{
  pkgs,
  ...
}:
{
  services.n8n = {
    enable = true;
    openFirewall = true;
    environment.N8N_SECURE_COOKIE = "false";
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ 5678 ];
  networking.firewall.interfaces.wiregrill.allowedTCPPorts = [ 5678 ];

  # DynamicUser state (config holds the credentials' encryption key); the
  # SQLite database is dumped consistently instead of copied.
  lass.backup.state.n8n = {
    folders = [ "/var/lib/private/n8n" ];
    exclude = [ "/var/lib/private/n8n/.n8n/database.sqlite*" ];
    preBackup = ''
      ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" /var/lib/private/n8n/.n8n/database.sqlite ".backup /var/backup/n8n.sqlite"
    '';
    # WAL-mode SQLite readers need to write the -shm file
    readWritePaths = [ "/var/lib/private/n8n/.n8n" ];
  };
}
