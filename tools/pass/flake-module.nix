{ self, inputs, ... }:
{
  perSystem =
    {
      pkgs,
      system,
      ...
    }:
    {
      packages.pass = inputs.wrappers.lib.wrapPackage {
        pkgs = pkgs;
        package = pkgs.passage;
        runtimeInputs = [
          pkgs.age-plugin-fido2-hmac
          pkgs.age-plugin-yubikey
          pkgs.age-plugin-tpm
          self.packages.${system}.age-plugin-gpg
          self.packages.${system}.pass-otp
          self.packages.${system}.age-detect
          # age-plugin-phone: encrypts to the phonetpm recipient, decrypts via the daemon
          self.packages.${system}.phonetpm
        ]
        ++ (pkgs.lib.optionals pkgs.stdenv.isLinux [
          self.packages.${system}.pinentry-rofi-age
        ])
        ++ (pkgs.lib.optionals pkgs.stdenv.isDarwin [
          pkgs.age-plugin-se
        ])
        ++ (pkgs.lib.optionals (!pkgs.stdenv.isDarwin) [
          # Dummy age-plugin-se for Linux (encryption only, no Secure Enclave hardware)
          (pkgs.writeShellScriptBin "age-plugin-se" ''
            exec env PYTHONUNBUFFERED=1 ${
              pkgs.python3.withPackages (ps: [ ps.cryptography ])
            }/bin/python3 ${./age-plugin-se-dummy.py} "$@"
          '')
        ]);
        aliases = [ "pass" ];
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

                        # Determine if the command needs decryption
                        needs_decrypt=true
                        case "''${1:-}" in
                          ls|find|git|insert|generate|rm|mv|cp|help|version|init)
                            needs_decrypt=false
                            ;;
                        esac

            ${
              if pkgs.stdenv.isLinux then
                ''
                  maybe_set_tpm_pin() {
                    local target="''${1:-<stdin>}"
                    if [[ "''${KEY_TYPE:-}" != "tpm" ]]; then
                      return 0
                    fi
                    if [[ -n "''${AGE_TPM_PIN:-}" ]]; then
                      return 0
                    fi
                    AGE_TPM_PIN="$(${self.packages.${system}.pinentry-rofi-age}/bin/pinentry-rofi-age "$target")"
                    export AGE_TPM_PIN
                  }
                ''
              else
                ''
                  # No TPM on Darwin, define no-op
                  maybe_set_tpm_pin() { :; }
                ''
            }

                        setup_identities() {
                          # Always detect available age keys first
                          export AGE_DETECT_KEYS_DIR="${
                            builtins.path {
                              path = self + "/keys";
                              name = "keys";
                            }
                          }"
                          eval "$(age-detect)"

                          # Set up identity file if detected
                          if [[ -n "''${IDENTITY_FILE:-}" ]]; then
                            export PASSAGE_IDENTITIES_FILE="$IDENTITY_FILE"
                            trap 'rm -f "$IDENTITY_FILE"' EXIT
                          fi

                          # Try to decrypt and cache the bulk key using the detected identity
                          if [[ -n "''${PASS_BULK_KEY_FILE:-}" ]]; then
                            if [[ ! -f "$PASS_BULK_KEY_FILE" ]] || [[ ! -s "$PASS_BULK_KEY_FILE" ]]; then
                              mkdir -p "$(dirname "$PASS_BULK_KEY_FILE")"
                              maybe_set_tpm_pin "bulk-operations/age-key"
                              ${exePath} show bulk-operations/age-key > "$PASS_BULK_KEY_FILE" 2>/dev/null || true
                            fi
                            # Switch to bulk key for subsequent operations if available
                            if [[ -f "$PASS_BULK_KEY_FILE" ]] && [[ -s "$PASS_BULK_KEY_FILE" ]]; then
                              export PASSAGE_IDENTITIES_FILE="$PASS_BULK_KEY_FILE"
                              # Bulk key is a plain age key, no TPM PIN needed for decryption
                              export KEY_TYPE=bulk
                            fi
                          fi
                        }

                        if [[ "$needs_decrypt" == true ]]; then
                          setup_identities
                        fi

            ${
              if pkgs.stdenv.isLinux then
                ''
                  decrypt_target=""
                  if [[ "''${1:-}" == "show" ]]; then
                    decrypt_target="''${2:-}"
                  elif [[ -n "''${1:-}" ]] && [[ "''${1:-}" != -* ]] && [[ "''${1:-}" != "otp" ]]; then
                    # Skip passage subcommands that don't need decryption
                    case "''${1:-}" in
                      ls|find|git|insert|generate|rm|mv|cp|help|version|init)
                        ;;
                      edit|grep|reencrypt)
                        # These commands do decrypt, prompt with command as target
                        decrypt_target="''${2:-''${1:-}}"
                        ;;
                      *)
                        # Bare pass-name (implicit show)
                        decrypt_target="''${1:-}"
                        ;;
                    esac
                  fi

                  if [[ -n "$decrypt_target" ]]; then
                    maybe_set_tpm_pin "$decrypt_target"
                  fi
                ''
              else
                ""
            }

                        # Handle OTP commands by delegating to pass-otp
                        if [[ "''${1:-}" == "otp" ]]; then
                          shift
                          # Extract pass name and options
                          clip_arg=""
                          pass_name=""
                          for arg in "$@"; do
                            case "$arg" in
                              "--clip"|"-c")
                                clip_arg="--clip"
                                ;;
                              *)
                                pass_name="$arg"
                                ;;
                            esac
                          done

                          if [[ -z "$pass_name" ]]; then
                            echo "Usage: pass otp [--clip,-c] pass-name"
                            exit 1
                          fi

                          # Show pass and pipe to OTP (identities already set up by age-detect)
                          maybe_set_tpm_pin "$pass_name"
                          ${exePath} show "$pass_name" | pass-otp $clip_arg
                        else
                          # Pass all other commands directly to passage (identities already set up)
                          ${exePath} "$@"
                        fi
          '';
      };
    };
}
