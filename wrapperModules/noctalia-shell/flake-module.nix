{ ... }:
{
  flake.wrapperModules.noctalia-shell =
    {
      config,
      lib,
      ...
    }:
    let
      pkgs = config.pkgs;
      jsonFormat = pkgs.formats.json { };

      sway-focus-workspace = pkgs.writeShellScript "sway-focus-workspace" ''
        # Bring a workspace to the currently focused output
        ws="$1"
        current_output=$(${pkgs.sway}/bin/swaymsg -t get_workspaces \
          | ${pkgs.jq}/bin/jq -r '.[] | select(.focused) | .output')
        ${pkgs.sway}/bin/swaymsg "workspace $ws, move workspace to output $current_output"
      '';

      noctalia-shell = pkgs.callPackage ./noctalia-shell.nix { inherit (config) noctalia-qs; };

      # Patch noctalia-shell for sway:
      # - Use workspace name instead of number (activate() sends
      #   "workspace number <num>" which fails for named workspaces)
      # - Show all workspaces on all screens (globalWorkspaces)
      # - Bring workspace to current screen on click instead of jumping
      # - Periodically resync the workspace model: the upstream QuickShell
      #   i3 plugin never removes renamed workspaces (a "rename" event is
      #   looked up by the NEW name, misses the old model object, and only
      #   logs "Workspace <name> doesn't exist"). A renamed workspace thus
      #   lingers as a stale pill until a full refresh; clicking that ghost
      #   pill then re-creates the old name as a real workspace.
      swayPatched = noctalia-shell.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
              substituteInPlace $out/share/noctalia-shell/Services/Compositor/SwayService.qml \
                --replace-fail 'workspace.handle.activate();' \
                  'Quickshell.execDetached(["${sway-focus-workspace}", workspace.name]);' \
                --replace-fail 'property bool initialized: false' \
                  'property bool globalWorkspaces: true
          property bool initialized: false

          // Drop stale workspace model entries (see patch note above).
          Timer {
            interval: 30000
            repeat: true
            running: initialized
            onTriggered: I3.refreshWorkspaces()
          }'
        '';
      });

      declSettingsFile = jsonFormat.generate "noctalia-declarative-settings.json" config.settings;
    in
    {
      _class = "wrapper";

      options = {
        settings = lib.mkOption {
          type = jsonFormat.type;
          default = { };
          example = lib.literalExpression ''
            {
              hooks.enabled = true;
              hooks.darkModeChange = "switch-theme $1";
            }
          '';
          description = ''
            Declarative noctalia settings. Deep-merged into the on-disk
            `settings.json` on every start (declarative wins). Keys not
            mentioned here remain user-mutable and survive across
            invocations — only the fields you set are pinned.
          '';
        };

        settingsPath = lib.mkOption {
          type = lib.types.str;
          default = ".config/noctalia/settings.json";
          description = ''
            Path to the noctalia settings file, relative to `$HOME`.
          '';
        };

        settingsPatches = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = lib.literalExpression ''
            [
              # Force the Workspace bar widget to show workspace names.
              ".bar.widgets.center |= map(if .id == \"Workspace\" then .labelMode = \"name\" else . end)"
            ]
          '';
          description = ''
            jq update expressions applied to `settings.json` on every start,
            after the deep-merge of `settings`. Use these to pin individual
            fields inside arrays (where deep-merge would replace the whole
            array) without touching sibling entries.

            Each string is passed as the filter to a separate `jq` invocation.
            Patches run in order; if any patch fails the file is left
            untouched.
          '';
        };

        noctalia-qs = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ../../pkgs/noctalia-qs/package.nix { };
          defaultText = lib.literalExpression "pkgs.callPackage ../../pkgs/noctalia-qs/package.nix { }";
          description = ''
            The quickshell fork the default package runs on. Ignored if you
            override `package`.
          '';
        };

        swayWorkspaceFix = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Patch noctalia-shell so its workspace bar works on sway with
            named/global workspaces and click-to-current-output. Applied
            to the default package only; ignored if you override `package`.
          '';
        };
      };

      config.package = lib.mkDefault (if config.swayWorkspaceFix then swayPatched else noctalia-shell);

      config.extraPackages = [
        pkgs.jq
        pkgs.coreutils
      ];

      # On every start: merge declarative settings into the user's
      # writable settings.json. User-edited keys outside the declarative
      # set are preserved; declarative keys are overwritten each run.
      config.preHook = ''
        NOCTALIA_SETTINGS="$HOME/${config.settingsPath}"
        mkdir -p "$(dirname "$NOCTALIA_SETTINGS")"
        if [ ! -f "$NOCTALIA_SETTINGS" ]; then
          echo '{}' > "$NOCTALIA_SETTINGS"
        fi
        NOCTALIA_TMP=$(mktemp "$NOCTALIA_SETTINGS.XXXXXX")
        noctalia_merge_ok=1
        if ! ${pkgs.jq}/bin/jq --slurpfile decl ${declSettingsFile} \
            '. * $decl[0]' "$NOCTALIA_SETTINGS" > "$NOCTALIA_TMP"; then
          noctalia_merge_ok=0
        fi
        ${lib.concatMapStringsSep "\n" (patch: ''
          if [ "$noctalia_merge_ok" = 1 ]; then
            NOCTALIA_TMP2=$(mktemp "$NOCTALIA_SETTINGS.XXXXXX")
            if ${pkgs.jq}/bin/jq ${lib.escapeShellArg patch} "$NOCTALIA_TMP" > "$NOCTALIA_TMP2"; then
              mv "$NOCTALIA_TMP2" "$NOCTALIA_TMP"
            else
              rm -f "$NOCTALIA_TMP2"
              noctalia_merge_ok=0
            fi
          fi
        '') config.settingsPatches}
        if [ "$noctalia_merge_ok" = 1 ]; then
          mv "$NOCTALIA_TMP" "$NOCTALIA_SETTINGS"
        else
          rm -f "$NOCTALIA_TMP"
          echo "noctalia declarative settings merge failed; leaving settings.json untouched" >&2
        fi
      '';

      config.meta.maintainers = [
        {
          name = "lassulus";
          github = "lassulus";
          githubId = 621375;
        }
      ];
      config.meta.platforms = lib.platforms.linux;
    };
}
