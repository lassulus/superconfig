{ pkgs, ... }:
{
  # Mailbox password for slopulus@lassul.us. Generated once and shared:
  # neoprism (configs/mailserver.nix) consumes the hash, coaxmetal
  # (machines/coaxmetal/slopulus.nix) the plaintext, but only at generation time
  # via the hermes-env generator, so the plaintext is never deployed. Both
  # machines import this file so the shared generator definition stays identical.
  clan.core.vars.generators.hermes-mail = {
    share = true;
    files."password".deploy = false;
    files."password-hash" = { };
    runtimeInputs = with pkgs; [
      coreutils
      mkpasswd
      pwgen
    ];
    script = ''
      pwgen -s 32 1 | tr -d '\n' > "$out/password"
      mkpasswd -sm bcrypt < "$out/password" > "$out/password-hash"
    '';
  };
}
