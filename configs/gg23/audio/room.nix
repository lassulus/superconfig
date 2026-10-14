# Room speaker for the acheron audio hub (./hub.nix): plays what the hub
# sends via ROC on the default output.
{ self, lib, ... }:
let
  kartei = import (self.inputs.kartei + "/modules/retiolum/hosts.nix") { inherit lib; };
  acheron = kartei.own.acheron.ip4;
in
{
  services.pipewire.extraConfig.pipewire."10-audio-room"."context.modules" = [
    {
      name = "libpipewire-module-roc-source";
      args = {
        "local.ip" = "0.0.0.0";
        "local.source.port" = 10001;
        "local.repair.port" = 10002;
        "local.control.port" = 10003;
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

  # the hub sends over retiolum (see ./hub.nix), accept only acheron
  networking.firewall.extraInputRules = ''
    iifname "retiolum" ip saddr ${acheron} udp dport 10001-10003 accept
  '';
}
