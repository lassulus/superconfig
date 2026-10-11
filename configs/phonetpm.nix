{
  pkgs,
  self,
  ...
}:
let
  phonetpm = self.packages.${pkgs.system}.phonetpm;
in
{
  # Phone-backed ssh-agent / age plugin (https://github.com/Lassulus/phonetpm).
  # The daemon serves %t/phonetpm/{agent,control}.sock; age-plugin-phone finds
  # the control socket on its own. configs/phonetpm-ssh.nix makes it the
  # SSH_AUTH_SOCK.
  environment.systemPackages = [ phonetpm ];

  systemd.user.services.phonetpm = {
    description = "phonetpm daemon (phone as ssh-agent / age backend)";
    wantedBy = [ "default.target" ];
    after = [ "network-online.target" ];
    # Skipped until `phonetpm pair <endpoint id>` has written the config;
    # `systemctl --user start phonetpm` afterwards.
    unitConfig.ConditionPathExists = "%E/phonetpm/config.toml";
    serviceConfig = {
      ExecStart = "${phonetpm}/bin/phonetpm daemon";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
