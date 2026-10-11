{
  config,
  lib,
  pkgs,
  ...
}:
let
  sock = "\${XDG_RUNTIME_DIR}/phonetpm/agent.sock";
in
{
  # Use the phonetpm daemon (configs/phonetpm.nix) as the ssh-agent: every
  # signature asks for a fingerprint on the phone. Only a default: hosts that
  # also import configs/tpm2.nix keep the TPM agent as SSH_AUTH_SOCK.
  imports = [ ./phonetpm.nix ];

  environment.sessionVariables.SSH_AUTH_SOCK = lib.mkDefault sock;

  # systemd-launched programs don't source /etc/set-environment; publish the
  # socket to the user manager like configs/tpm2.nix does, unless another
  # agent owns SSH_AUTH_SOCK.
  systemd.user.services.phonetpm.serviceConfig.ExecStartPost = lib.mkIf (
    config.environment.sessionVariables.SSH_AUTH_SOCK == sock
  ) "${pkgs.systemd}/bin/systemctl --user set-environment SSH_AUTH_SOCK=%t/phonetpm/agent.sock";

  # gnome-keyring pulls in gcr-ssh-agent, which also sets SSH_AUTH_SOCK in the
  # user manager and would shadow phonetpm.
  services.gnome.gcr-ssh-agent.enable = false;
}
