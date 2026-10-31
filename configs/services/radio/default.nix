{
  self,
  config,
  pkgs,
  lib,
  ...
}:

let
  name = "radio";

  music_dir = "/var/music";

  skip_track = pkgs.writers.writeBashBin "skip_track" ''
    set -eu

    # TODO come up with new rating, without moving files
    # current_track=$(${pkgs.curl}/bin/curl -fSs http://localhost:8002/current | ${pkgs.jq}/bin/jq -r .filename)
    # track_infos=$(${print_current}/bin/print_current)
    # skip_count=$(${pkgs.attr}/bin/getfattr -n user.skip_count --only-values "$current_track" || echo 0)
    # if [[ "$current_track" =~ .*/the_playlist/music/.* ]] && [ "$skip_count" -le 2 ]; then
    #   skip_count=$((skip_count+1))
    #   ${pkgs.attr}/bin/setfattr -n user.skip_count -v "$skip_count" "$current_track"
    #   echo skipping: "$track_infos" skip_count: "$skip_count"
    # else
    #   mkdir -p "$music_dir"/the_playlist/.graveyard/
    #   mv "$current_track" "$music_dir"/the_playlist/.graveyard/
    #   echo killing: "$track_infos"
    # fi
    ${pkgs.curl}/bin/curl -fSs -X POST http://localhost:${toString config.lass.servicePorts.radio}/skip |
      ${pkgs.jq}/bin/jq -r '.filename'
  '';

  good_track = pkgs.writers.writeBashBin "good_track" ''
    set -eu

    current_track=$(${pkgs.curl}/bin/curl -fSs http://localhost:${toString config.lass.servicePorts.radio}/current | ${pkgs.jq}/bin/jq -r .filename)
    track_infos=$(${print_current}/bin/print_current)
    # TODO come up with new rating, without moving files
    # if [[ "$current_track" =~ .*/the_playlist/music/.* ]]; then
    #   ${pkgs.attr}/bin/setfattr -n user.skip_count -v 0 "$current_track"
    # else
    #   mv "$current_track" "$music_dir"/the_playlist/music/ || :
    # fi
    echo good: "$track_infos"
  '';

  print_current = pkgs.writers.writeDashBin "print_current" ''
    file=$(${pkgs.curl}/bin/curl -fSs http://localhost:${toString config.lass.servicePorts.radio}/current |
      ${pkgs.jq}/bin/jq -r '.filename' |
      ${pkgs.gnused}/bin/sed 's,^${music_dir},,'
    )
    link=$(${pkgs.curl}/bin/curl http://localhost:${toString config.lass.servicePorts.radio}/current |
      ${pkgs.jq}/bin/jq -r '.filename' |
      ${pkgs.gnused}/bin/sed 's@.*\(.\{11\}\)\.ogg@https://youtu.be/\1@'
    )
    echo "$file": "$link"
  '';

  # nginx location running a track script through fcgiwrap
  trackAction = script: ''
    limit_except POST { deny all; }
    include ${config.services.nginx.package}/conf/fastcgi_params;
    fastcgi_param SCRIPT_FILENAME ${pkgs.writers.writeDash "${script.name}-cgi" ''
      printf 'Content-Type: text/plain; charset=UTF-8\r\n\r\n'
      ${script}/bin/${script.name}
    ''};
    fastcgi_pass unix:${config.services.fcgiwrap.instances.radio.socket.address};
  '';

in
{
  imports = [
    ./news.nix
    ./weather.nix
  ];

  lass.ports = {
    ${toString config.services.nginx.defaultHTTPListenPort} = "nginx-http";
    ${toString config.services.icecast.listen.port} = "icecast";
    # liquidsoap's harbor, radio.liq reads RADIO_PORT
    "8002" = "radio";
  };

  users.users = {
    "${name}" = rec {
      inherit name;
      isSystemUser = true;
      createHome = true;
      group = name;
      description = "radio manager";
      home = "/home/${name}";
      useDefaultShell = true;
      openssh.authorizedKeys.keys = [
        self.keys.ssh.barnacle.public
        self.keys.ssh.yubi_pgp.public
        self.keys.ssh.termux_massulus.public
        self.keys.ssh.yubi1.public
        self.keys.ssh.yubi2.public
        self.keys.ssh.solo2.public
      ];
      packages = [
        good_track
        skip_track
        print_current
      ];
    };
  };

  users.groups = {
    "radio" = { };
  };

  systemd.services.radio_watcher = {
    wantedBy = [ "multi-user.target" ];
    after = [ "radio.service" ];
    serviceConfig = {
      ExecStart = pkgs.writers.writeDash "radio_watcher" ''
        set -efux
        while :; do
          ${pkgs.curl}/bin/curl -Ss http://localhost:${toString config.lass.servicePorts.icecast}/radio.ogg -o /dev/null
          ${pkgs.systemd}/bin/systemctl restart radio
          sleep 60
        done
      '';
      Restart = "on-failure";
    };
  };

  services.liquidsoap.streams.radio = ./radio.liq;
  systemd.services.radio = {
    environment = {
      RADIO_PORT = toString config.lass.servicePorts.radio;
      HOOK_TRACK_CHANGE = pkgs.writers.writeDash "on_change" ''
        set -xefu
        LIMIT=100000 #how many tracks to keep in the history
        HISTORY_FILE=/var/lib/radio/recent

        listeners=$(${pkgs.curl}/bin/curl -fSs http://localhost:${toString config.lass.servicePorts.icecast}/status-json.xsl |
          ${pkgs.jq}/bin/jq '[.icestats.source[].listeners] | add' || echo 0)
        echo "$(${pkgs.coreutils}/bin/date -Is)" "$filename" | ${pkgs.coreutils}/bin/tee -a "$HISTORY_FILE"
        echo "$(${pkgs.coreutils}/bin/tail -$LIMIT "$HISTORY_FILE")" > "$HISTORY_FILE"
      '';
      MUSIC = "${music_dir}/the_playlist";
      ICECAST_HOST = "localhost";
    };
    path = [
      pkgs.bubblewrap
    ];
    serviceConfig.User = lib.mkForce "radio";
  };

  nixpkgs.config.packageOverrides = opkgs: {
    liquidsoap = opkgs.liquidsoap.override {
      runtimePackages = with opkgs; [
        bubblewrap
        curl
        ffmpeg
      ];
    };
    icecast = opkgs.icecast.overrideAttrs (old: rec {
      version = "2.5-beta3";

      src = pkgs.fetchurl {
        url = "http://downloads.xiph.org/releases/icecast/icecast-${version}.tar.gz";
        sha256 = "sha256-4FDokoA9zBDYj8RAO/kuTHaZ6jZYBLSJZiX/IYFaCW8=";
      };

      NIX_CFLAGS_COMPILE = "-Wno-error=implicit-function-declaration";

      buildInputs = old.buildInputs ++ [ pkgs.pkg-config ];
    });
  };
  services.icecast = {
    enable = true;
    hostname = "radio.lassul.us";
    admin.password = "hackme";
    extraConf = ''
      <authentication>
        <source-password>hackme</source-password>
        <admin-user>admin</admin-user>
        <admin-password>hackme</admin-password>
      </authentication>
      <logging>
        <accesslog>-</accesslog>
        <errorlog>-</errorlog>
        <loglevel>3</loglevel>
      </logging>
      <mount type="normal">
        <mount-name>/radio.badge</mount-name>
        <queue-size>2048000</queue-size>
        <burst-size>128000</burst-size>
      </mount>
    '';
  };
  # the 2.5 beta has segfaulted before; the module sets no Restart=
  systemd.services.icecast.serviceConfig.Restart = "on-failure";

  networking.firewall.interfaces.retiolum.allowedTCPPorts = [
    config.lass.servicePorts.radio
  ];

  # POST /skip and /good, run as radio by fcgiwrap
  services.fcgiwrap.instances.radio = {
    process.user = name;
    process.group = name;
    socket.user = config.services.nginx.user;
    socket.group = config.services.nginx.group;
  };

  networking.firewall.allowedTCPPorts = [
    config.lass.servicePorts.nginx-http
    config.lass.servicePorts.icecast
  ];
  services.nginx = {
    enable = true;
    virtualHosts."radio.r" = {
      locations."/".extraConfig = ''
        # https://github.com/aswild/icecast-notes#core-nginx-config
        proxy_pass http://localhost:${toString config.lass.servicePorts.icecast};
        # Disable request size limit, very important for uploading large files
        client_max_body_size 0;

        # Enable support `Transfer-Encoding: chunked`
        chunked_transfer_encoding on;

        # Disable request and response buffering, minimize latency to/from Icecast
        proxy_buffering off;
        proxy_request_buffering off;

        # Icecast needs HTTP/1.1, not 1.0 or 2
        proxy_http_version 1.1;

        # Forward all original request headers
        proxy_pass_request_headers on;

        # Set some standard reverse proxy headers. Icecast server currently ignores these,
        # but may support them in a future version so that access logs are more useful.
        proxy_set_header  Host              $host;
        proxy_set_header  X-Real-IP         $remote_addr;
        proxy_set_header  X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header  X-Forwarded-Proto $scheme;

        # get source ip for weather reports
        proxy_set_header user-agent "$http_user_agent; client-ip=$remote_addr";
      '';
      locations."= /recent".extraConfig = ''
        default_type "text/plain";
        alias /var/lib/radio/recent;
      '';
      locations."= /current".extraConfig = ''
        proxy_pass http://localhost:${toString config.lass.servicePorts.radio};
      '';
      locations."= /skip".extraConfig = trackAction skip_track;
      locations."= /good".extraConfig = trackAction good_track;
      locations."= /radio.sh".alias = pkgs.writeScript "radio.sh" ''
        #!/bin/sh
        trap 'exit 0' EXIT
        while sleep 1; do
          mpv \
            --cache-secs=0 --demuxer-readahead-secs=0 --untimed --cache-pause=no \
            'http://radio.lassul.us/radio.ogg'
        done
      '';
      locations."= /controls".extraConfig = ''
        default_type "text/html";
        alias ${./controls.html};
      '';
      extraConfig = ''
        add_header 'Access-Control-Allow-Origin' '*';
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
      '';
    };
  };
  services.syncthing.settings.folders."/home/lass/tmp/the_playlist" = {
    path = lib.mkForce "/var/music/the_playlist";
    devices = [
      "mors"
      "radio"
    ];
  };
  # lass and radio manage the playlist. The default ACL hands rw on new
  # files and rwx on new directories to both (files are created without x,
  # so the mask drops it); existing content keeps the ACLs it already has.
  # No X: tmpfiles applies it to existing files with an r-- mask.
  systemd.tmpfiles.settings."10-the-playlist" = {
    "/var/music/the_playlist" = {
      d = { };
      "a+".argument = "u:lass:rwx,u:radio:rwx";
      "A+".argument = "d:u:lass:rwx,d:u:radio:rwx";
    };
    # traverse down to the playlist
    "/var/music"."a+".argument = "u:lass:x";
    "/var"."a+".argument = "u:lass:x";
  };
}
