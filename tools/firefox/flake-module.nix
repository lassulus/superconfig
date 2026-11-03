{ self, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      system,
      ...
    }:
    let
      tridactylrc = ./tridactylrc;

      workspaceTabsExtension = self.packages.${system}.workspace-tabs-extension;

      firefoxBase = pkgs.wrapFirefox pkgs.firefox-devedition-unwrapped {
        nativeMessagingHosts = [
          pkgs.tridactyl-native
          self.packages.${system}.workspace-tabs-native-host
          self.packages.${system}.browser-mcp
        ];
        extraPolicies = {
          Extensions.Install = [
            "${workspaceTabsExtension}/workspace-tabs@workspace-manager.xpi"
            "${self.packages.${system}.browser-mcp-extension}/browser-mcp@lassul.us.xpi"
          ];
        };
        extraPrefsFiles = [
          (pkgs.writeText "workspace-tabs-prefs.js" ''
            lockPref("xpinstall.signatures.required", false);
            lockPref("browser.startup.page", 0);
            lockPref("browser.sessionstore.resume_from_crash", false);
            // WebGPU is still off by default on Linux (needed e.g. for nfsu2.xyz)
            defaultPref("dom.webgpu.enabled", true);
          '')
        ];
      };

      # Wrapper that sets up tridactylrc symlink before starting Firefox
      firefox = pkgs.writeShellScriptBin "firefox" ''
        # Tridactyl config setup
        config_dir="$HOME/.config/tridactyl"
        config_file="$config_dir/tridactylrc"
        repo_config="$HOME/src/superconfig/tools/firefox/tridactylrc"
        store_config="${tridactylrc}"

        mkdir -p "$config_dir"

        # Prefer repo version if it exists, otherwise use store version
        if [[ -f "$repo_config" ]]; then
          target="$repo_config"
        else
          target="$store_config"
        fi

        # Update symlink if needed
        if [[ ! -L "$config_file" ]] || [[ "$(readlink "$config_file")" != "$target" ]]; then
          ln -sf "$target" "$config_file"
        fi

        exec ${lib.getExe firefoxBase} "$@"
      '';
    in
    {
      packages.firefox = firefox;
    };
}
