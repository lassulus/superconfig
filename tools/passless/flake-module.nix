{ self, inputs, ... }:
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      identity = import ../pass/identity.nix { inherit self pkgs system; };

      # age for a TPM identity: age-plugin-tpm takes the PIN from
      # AGE_TPM_PIN, else asks age, which needs a terminal the daemon lacks.
      # So every decrypt asks via rofi and hands the PIN to this one call.
      age-tpm-pin = pkgs.writeShellScriptBin "age" ''
        for arg in "$@"; do
          if [[ "$arg" == -d || "$arg" == --decrypt ]]; then
            AGE_TPM_PIN="$(${
              lib.getExe self.packages.${system}.pinentry-rofi-age
            } "passless passkey")" || exit 1
            export AGE_TPM_PIN
            break
          fi
        done
        exec ${lib.getExe pkgs.age} "$@"
      '';
    in
    {
      # passless (virtual FIDO2 key) storing passkeys in the passage store
      # next to the site's other entries (www/<rp id>/passkey.age). Decrypts
      # with this machine's identity from age-detect (never the bulk key), so
      # every passkey use is approved on the TPM/phone/YubiKey. Defaults are
      # env vars, so they win over ~/.config/passless/config.toml; override
      # them via env or flags.
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        passless = inputs.wrappers.lib.wrapPackage {
          inherit pkgs;
          package = self.packages.${system}.passless-unwrapped;
          runtimeInputs = identity.runtimeInputs ++ [ pkgs.age ];
          wrapper =
            {
              exePath,
              envString,
              preHook,
              ...
            }:
            ''
              ${envString}
              ${preHook}

              export PASSLESS_BACKEND_TYPE="''${PASSLESS_BACKEND_TYPE:-passage}"
              export PASSLESS_PASSAGE_PATH="''${PASSLESS_PASSAGE_PATH:-www}"
              # the PIN is asked per decrypt, never kept in the daemon's env
              unset AGE_TPM_PIN

              ${identity.detectIdentity}

              # Only the daemon decrypts; config/client subcommands and
              # --help/--version need no identity.
              needs_decrypt=true
              for arg in "$@"; do
                case "$arg" in
                  config|client|help|-h|--help|-V|--version)
                    needs_decrypt=false
                    ;;
                esac
              done

              if [[ "$needs_decrypt" == true ]]; then
                # identity file in the runtime dir: systemd-tmpfiles ages out
                # /tmp files after 10 days, the daemon may run longer
                TMPDIR="''${XDG_RUNTIME_DIR:-''${TMPDIR:-/tmp}}" detect_identity
                if [[ "''${KEY_TYPE:-}" == tpm ]]; then
                  export PASSLESS_PASSAGE_AGE_BINARY="''${PASSLESS_PASSAGE_AGE_BINARY:-${lib.getExe age-tpm-pin}}"
                fi
              fi

              # no exec: the EXIT trap of detect_identity removes the identity
              # file, which must live as long as the daemon
              ${exePath} "$@"
            '';
        };
      };
    };
}
