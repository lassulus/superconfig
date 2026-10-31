{
  self,
  config,
  pkgs,
  ...
}:

{
  imports = [
    ../../configs
    ../../configs/mouse.nix
    ../../configs/retiolum.nix
    ../../configs/desktops/qtile/nixos.nix
    ../../configs/pipewire.nix
    ../../configs/browsers.nix
    ../../configs/pass.nix
    ../../configs/steam.nix
    ../../configs/mail.nix
    ../../configs/syncthing.nix
    ../../configs/ableton.nix
    ../../configs/rtl-sdr.nix
    ../../configs/printing
    ../../configs/network-manager.nix
    ../../configs/networkd.nix
    ../../configs/autotether.nix
    ../../configs/autoupdate.nix
    {
      lass.ports.${toString config.services.nginx.defaultHTTPListenPort} = "nginx-http";
      services.nginx = {
        enable = true;
        virtualHosts.default = {
          default = true;
          serverAliases = [
            "localhost"
            "${config.networking.hostName}"
            "${config.networking.hostName}.r"
          ];
          locations."~ ^/~(.+?)(/.*)?\$".extraConfig = ''
            alias /home/$1/public_html$2;
          '';
        };
      };
    }
    {
      lass.ports.${toString config.services.redis.servers."".port} = "redis";
      services.redis.servers."".enable = true;
    }
    {
      environment.systemPackages = [
        self.packages.${pkgs.system}.bank
      ];
    }
    {
      services.tor = {
        enable = true;
        client.enable = true;
      };
    }
  ];

  environment.systemPackages = with pkgs; [
    android-tools
    dnsutils
    woeusb
  ];

  #TODO: fix this shit
  ##fprint stuff
  ##sudo fprintd-enroll $USER to save fingerprints
  #services.fprintd.enable = true;
  #security.pam.services.sudo.fprintAuth = true;

  users.extraGroups = {
    loot = {
      members = [
        config.users.extraUsers.mainUser.name
        "firefox"
        "chromium"
        "google"
        "virtual"
      ];
    };
  };

  nixpkgs.config.android_sdk.accept_license = true;

  # It may leak your data, but look how FAST it is!1!!
  # https://make-linux-fast-again.com/
  boot.kernelParams = [
    "noibrs"
    "noibpb"
    "nopti"
    "nospectre_v2"
    "nospectre_v1"
    "l1tf=off"
    "nospec_store_bypass_disable"
    "no_stf_barrier"
    "mds=off"
    "mitigations=off"
  ];

  boot.binfmt.emulatedSystems = [
    "aarch64-linux"
  ];

  nix.settings.trusted-users = [
    "root"
    "lass"
  ];

  services.nscd.enableNsncd = true;

}
