{
  config,
  lib,
  pkgs,
  ...
}:

let
  uploadPage = pkgs.writeText "paste-upload.html" ''
    <!doctype html>
    <title>p.krebsco.de</title>
    <form action="/form" method="post" enctype="multipart/form-data">
      <input type="file" name="file" required>
      <button>upload</button>
    </form>
    <p>or with curl:</p>
    <pre>
    curl --data-binary @file https://p.krebsco.de
    some-command | curl --data-binary @- https://p.krebsco.de
    </pre>
  '';

  pasteCgi = pkgs.writers.writePython3 "paste-cgi" { } (
    lib.replaceStrings
      [ "@file@" "@exiv2@" ]
      [ (lib.getExe pkgs.file) (lib.getExe' pkgs.exiv2 "exiv2") ]
      (builtins.readFile ./paste.py)
  );

  # item directories of the former htgen handlers, kept for their contents
  # and the backup paths
  items = {
    paste = "/var/lib/htgen-paste/items";
    imgur = "/var/lib/htgen-imgur/items";
    cyberlocker = "/var/lib/htgen-cyberlocker/items";
  };

  # systemd chowns them to paste if they still belong to the htgen users
  stateDirectories = {
    StateDirectory = map (dir: lib.removePrefix "/var/lib/" (dirOf dir)) (lib.attrValues items);
    StateDirectoryMode = "0700";
  };

  cgi = app: itemsDir: ''
    include ${config.services.nginx.package}/conf/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME ${pasteCgi};
    fastcgi_param PASTE_APP ${app};
    fastcgi_param PASTE_ITEMS ${itemsDir};
    fastcgi_pass unix:${config.services.fcgiwrap.instances.paste.socket.address};
  '';
in
{
  # back up the state dirs of all items
  lass.backup.state.paste.folders = map dirOf (lib.attrValues items);

  services.nginx.virtualHosts.cyberlocker = {
    serverAliases = [ "c.r" ];
    locations."/".extraConfig = ''
      client_max_body_size 4G;
      ${cgi "cyberlocker" items.cyberlocker}
    '';
    extraConfig = ''
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS';
    '';
  };
  services.nginx.virtualHosts.paste = {
    serverAliases = [ "p.r" ];
    locations."/".extraConfig = ''
      client_max_body_size 4G;
      ${cgi "paste" items.paste}
    '';
    locations."/image".extraConfig = ''
      client_max_body_size 40M;
      ${cgi "imgur" items.imgur}
    '';
    extraConfig = ''
      add_header 'Access-Control-Allow-Origin' '*';
      add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
    '';
  };
  services.nginx.virtualHosts."c.krebsco.de" = {
    enableACME = true;
    addSSL = true;
    serverAliases = [ "c.krebsco.de" ];
    locations."/".extraConfig = ''
      if ($request_method != GET) {
        return 403;
      }
      ${cgi "cyberlocker" items.cyberlocker}
    '';
    extraConfig = ''
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS' always;
    '';
  };
  services.nginx.virtualHosts."p.krebsco.de" = {
    enableACME = true;
    addSSL = true;
    serverAliases = [ "p.krebsco.de" ];
    locations."/".extraConfig = ''
      if ($request_method = 'OPTIONS') {
        return 204;
      }
      if ($request_method ~ ^(GET|HEAD)$) {
        rewrite ^/$ /_upload last;
      }
      client_max_body_size 4G;
      ${cgi "paste" items.paste}
    '';
    locations."= /_upload".extraConfig = ''
      internal;
      default_type text/html;
      alias ${uploadPage};
    '';
    locations."/form".extraConfig = ''
      client_max_body_size 4G;
      ${cgi "form" items.paste}
    '';
    locations."/image".extraConfig = ''
      ${cgi "imgur" items.imgur}
    '';
    extraConfig = ''
      add_header Access-Control-Allow-Headers Authorization always;
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Methods 'GET, POST, OPTIONS' always;
    '';
  };

  services.fcgiwrap.instances.paste = {
    # requests at a time; uploads and downloads hold a process each
    process.prefork = 8;
    process.user = "paste";
    process.group = "paste";
    socket.user = config.services.nginx.user;
    socket.group = config.services.nginx.group;
  };
  systemd.services.fcgiwrap-paste.serviceConfig = stateDirectories;
  users.users.paste = {
    isSystemUser = true;
    group = "paste";
  };
  users.groups.paste = { };

  systemd.services.paste-gc = {
    startAt = "daily";
    serviceConfig = stateDirectories // {
      ExecStart = ''
        ${pkgs.findutils}/bin/find ${items.paste} -type f -mtime '+30' -exec rm {} \;
      '';
      User = "paste";
    };
  };

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ config.lass.servicePorts.nginx-http ];
}
