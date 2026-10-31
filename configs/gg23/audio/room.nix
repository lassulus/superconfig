# Room speaker for the acheron audio hub (./hub.nix): plays what the hub
# sends via ROC on the default output.
{
  self,
  config,
  lib,
  ...
}:
let
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  acheron = kartei.own.acheron.ip4;
in
{
  lass.ports = {
    "10001" = "roc-source";
    "10002" = "roc-repair";
    "10003" = "roc-control";
  };

  services.pipewire.extraConfig.pipewire."10-audio-room"."context.modules" = [
    {
      name = "libpipewire-module-roc-source";
      args = {
        "local.ip" = "0.0.0.0";
        "local.source.port" = config.lass.servicePorts.roc-source;
        "local.repair.port" = config.lass.servicePorts.roc-repair;
        "local.control.port" = config.lass.servicePorts.roc-control;
        "fec.code" = "disable";
        "sess.latency.msec" = 30;
        "source.name" = "roc-hub";
        "source.props" = {
          "node.description" = "Audio hub (acheron)";
          # keep the graph quantum small while the hub plays here
          "node.latency" = "256/48000";
        };
      };
    }
  ];

  # system-wide pipewire is only socket-activated; a room has no local client
  # after boot, so start it or the ROC source above never listens
  systemd.services.pipewire.wantedBy = [ "multi-user.target" ];

  # the hub sends over retiolum (see ./hub.nix), accept only acheron
  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${acheron} udp dport ${toString config.lass.servicePorts.roc-source}-${toString config.lass.servicePorts.roc-control} accept
  '';
}
