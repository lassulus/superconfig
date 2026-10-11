{
  self,
  pkgs,
  lib,
  ...
}:
let
  port = 4243;
  stateDir = "/var/lib/kannix";
  bareRepo = "${stateDir}/repos/kannix.git";
  srcDir = "${stateDir}/checkout/kannix";

  configFile = pkgs.writeText "kannix.json" (
    builtins.toJSON {
      columns = [
        "backlog"
        "planning"
        "doing"
        "review"
        "done"
      ];
      server = {
        host = "127.0.0.1";
        inherit port;
      };
      repos_dir = "${stateDir}/repos";
      worktree_dir = "${stateDir}/worktrees";
    }
  );

  kannixScript = pkgs.writeShellScript "kannix-run" ''
    export KANNIX_CONFIG=${configFile}
    export KANNIX_STATE_DIR=${stateDir}
    export PATH=${
      lib.makeBinPath [
        pkgs.tmux
        pkgs.git
        pkgs.nix
        pkgs.inotify-tools
        pkgs.coreutils
      ]
    }:$PATH
    cd ${srcDir}

    while true; do
      nix run .# -- \
        --host 127.0.0.1 \
        --port ${toString port} &
      PID=$!

      inotifywait -r -e modify,create,delete,move \
        --exclude '(__pycache__|\.pyc|\.git/|result)' \
        ${srcDir}/src ${srcDir}/flake.nix ${srcDir}/flake.lock ${srcDir}/package.nix ${srcDir}/pyproject.toml

      echo "Change detected, restarting..."
      kill $PID 2>/dev/null
      wait $PID 2>/dev/null
      sleep 1
    done
  '';
in
{
  users.users.kannix = {
    isNormalUser = true;
    home = stateDir;
    createHome = true;
    group = "users";
    shell = pkgs.bashInteractive;
    linger = true;
    openssh.authorizedKeys.keys = [
      self.keys.ssh.barnacle.public
      self.keys.ssh.yubi_pgp.public
      self.keys.ssh.termux_massulus.public
      self.keys.ssh.yubi1.public
      self.keys.ssh.yubi2.public
      self.keys.ssh.solo2.public
      self.keys.ssh.xerxes.public
      self.keys.ssh.ignavia.public
      self.keys.ssh.phonetpm_massulus.public
      self.keys.ssh.massulus.public
    ];
    packages = [
      pkgs.tmux
      pkgs.git
      (pkgs.writeShellScriptBin "kannix-ctl" ''
        cd ${srcDir}
        exec "$(nix build .# --no-link --print-out-paths)/bin/kannix-ctl" "$@"
      '')
    ];
  };

  systemd.tmpfiles.rules = [
    "d ${stateDir}/repos 0755 kannix users -"
    "d ${stateDir}/worktrees 0755 kannix users -"
    "d ${stateDir}/checkout 0755 kannix users -"
  ];

  systemd.services.kannix-checkout = {
    description = "Create kannix worktree from bare repo";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!${srcDir}/.git";
    serviceConfig = {
      Type = "oneshot";
      User = "kannix";
      Group = "users";
      ExecStart = toString (
        pkgs.writeShellScript "kannix-checkout" ''
          ${pkgs.git}/bin/git --git-dir=${bareRepo} worktree add ${srcDir} main
        ''
      );
    };
  };

  systemd.user.services.kannix = {
    description = "Kannix kanban server";
    wantedBy = [ "default.target" ];
    after = [ "network.target" ];
    path = [
      pkgs.tmux
      pkgs.git
      pkgs.nix
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = toString kannixScript;
      Restart = "on-failure";
      RestartSec = 5;
      WorkingDirectory = srcDir;
    };
  };

  services.nginx.virtualHosts."kannix.lassul.us" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
  };
}
