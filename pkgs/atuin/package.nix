{ atuin, stdenv }:
# atuin 18.23.0's e2e_capture test reads nix-darwin's /etc/bashrc in the
# unsandboxed darwin build, which resets PATH so the atuin under test is not
# used and the test times out. Fixed upstream by NixOS/nixpkgs#574509; drop
# this package once our nixpkgs pin includes it. Linux keeps the unmodified,
# cached nixpkgs derivation.
if stdenv.hostPlatform.isDarwin then
  atuin.overrideAttrs (old: {
    checkFlags = (old.checkFlags or [ ]) ++ [ "--skip=filtered_commands_leave_no_captured_output" ];
  })
else
  atuin
