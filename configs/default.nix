{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  selfPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
  # mosh-server takes a free UDP port from this range
  moshPorts = {
    from = 60000;
    to = 61000;
  };
in
{

  imports = [
    # Import modules
    ../modules

    # Import individual configurations
    ./security-fixes
    ./gc.nix
    ./mc.nix
    ./zsh.nix
    ./htop.nix
    ./tor-ssh.nix
    ./networkd.nix
    ./pinned-registry.nix
    ./nix.nix
    ./monitoring/agent.nix

    ./kartei.nix
    {
      # nix-index
      imports = [
        self.inputs.nix-index-database.nixosModules.nix-index
      ];
      programs.nix-index-database.comma.enable = true;
    }
    {
      # We need to mount these vars before the users phase, since that is the moment where the hashsed password are put into /etc/shadown
      users.extraUsers.mainUser.hashedPasswordFile =
        config.clan.core.vars.generators.password.files.passwordHash.path;
      users.extraUsers.root.hashedPasswordFile =
        config.clan.core.vars.generators.password.files.passwordHash.path;
      boot.initrd.systemd.emergencyAccess = true;
      clan.core.vars.generators.password = {
        prompts.password = {
          description = "Password for the main user";
          type = "hidden";
        };
        files.password.deploy = false;
        files.passwordHash.neededFor = "users";
        runtimeInputs = with pkgs; [
          coreutils
          mkpasswd
        ];
        script = ''
          cp $prompts/password $out/password
          cat $out/password | mkpasswd -s -m sha-512 > $out/passwordHash
        '';
      };
    }
    {
      services.openssh.enable = true;
      lass.ports = lib.genAttrs (map toString config.services.openssh.ports) (port: "sshd-${port}");
      services.openssh.settings.PasswordAuthentication = false;
      services.openssh.hostKeys = [
        {
          path = config.clan.core.vars.generators.ssh.files."ssh.id_ed25519".path;
          type = "ed25519";
        }
      ];
      clan.core.vars.generators.ssh = {
        files."ssh.id_ed25519" = { };
        files."ssh.id_ed25519.pub".secret = false;
        runtimeInputs = with pkgs; [
          coreutils
          openssh
        ];
        script = ''
          ssh-keygen -t ed25519 -N "" -f $out/ssh.id_ed25519
        '';
      };
    }
    {
      users.extraUsers = {
        root = {
          openssh.authorizedKeys.keys = [
            self.keys.ssh.barnacle.public
            self.keys.ssh.yubi_pgp.public
            self.keys.ssh.termux_massulus.public
            self.keys.ssh.yubi1.public
            self.keys.ssh.yubi2.public
            self.keys.ssh.solo2.public
            self.keys.ssh.ignavia.public
            self.keys.ssh.phonetpm_massulus.public
          ];
        };
        mainUser = {
          name = "lass";
          uid = 1337;
          home = "/home/lass";
          group = "users";
          createHome = true;
          useDefaultShell = true;
          isNormalUser = true;
          linger = true;
          extraGroups = [
            "audio"
            "video"
            "fuse"
            "wheel"
            "tor"
            "dialout"
          ];
          openssh.authorizedKeys.keys = [
            self.keys.ssh.barnacle.public
            self.keys.ssh.yubi_pgp.public
            self.keys.ssh.termux_massulus.public
            self.keys.ssh.yubi1.public
            self.keys.ssh.yubi2.public
            self.keys.ssh.solo2.public
            self.keys.ssh.ignavia.public
            self.keys.ssh.phonetpm_massulus.public
          ];
        };
      };
    }
    (
      let
        ca-bundle = "/etc/ssl/certs/ca-bundle.crt";
      in
      {
        environment.variables = {
          CURL_CA_BUNDLE = ca-bundle;
          GIT_SSL_CAINFO = ca-bundle;
          SSL_CERT_FILE = ca-bundle;
        };
      }
    )
    (
      # binary cache on neoprism, CI pushes there (configs/nix-cache.nix). The key
      # only exists once `clan vars generate neoprism` has run; until then
      # the cache is left out.
      let
        pub = self + "/vars/per-machine/neoprism/nix-cache-signing/key.pub/value";
      in
      lib.mkIf (builtins.pathExists pub) {
        nix.settings.extra-substituters = [ "https://cache.lassul.us" ];
        nix.settings.extra-trusted-public-keys = [ (lib.removeSuffix "\n" (builtins.readFile pub)) ];
      }
    )
    {
      #for sshuttle
      environment.systemPackages = [
        pkgs.python3Packages.python
      ];
    }
  ];

  networking.hostName = config.clan.core.settings.machine.name;

  users.mutableUsers = false;

  # multiple-definition-problem when defining environment.variables.EDITOR
  environment.extraInit = ''
    EDITOR=vim
  '';

  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    self.packages.${pkgs.system}.nvim
    self.packages.${pkgs.system}.tmux
    self.packages.${pkgs.system}.s

    git
    git-absorb
    gnumake
    jq
    nix-output-monitor
    comma

    #style
    rxvt-unicode-unwrapped.terminfo
    alacritty.terminfo

    #monitoring tools
    htop
    iotop

    #network
    iptables
    iftop
    tcpdump
    mosh
    self.packages.${pkgs.system}.sshify

    #stuff for dl
    aria2

    #neat utils
    file
    xkcdpass
    selfPkgs.kpaste
    selfPkgs.cyberlocker-tools
    pciutils
    pop
    selfPkgs.untilport
    (pkgs.writers.writeDashBin "urgent" ''
      printf '\a'
    '')
    usbutils

    #unpack stuff
    libarchive

    (pkgs.writers.writeDashBin "sshn" ''
      ${pkgs.openssh}/bin/ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$@"
    '')
  ];

  environment.shellAliases = {
    ll = "ls -l";
    la = "ls -la";
    ls = "ls --color";
    ip = "ip -color=auto";
    grep = "grep --color=auto";
    nosleep = "systemd-inhibit --what=handle-lid-switch sleep infinity";
  };

  programs.bash = {
    completion.enable = true;
    interactiveShellInit = ''
      HISTCONTROL='erasedups:ignorespace'
      HISTSIZE=65536
      HISTFILESIZE=$HISTSIZE

      shopt -s checkhash
      shopt -s histappend histreedit histverify
      shopt -s no_empty_cmd_completion
      complete -d cd
      LS_COLORS=$LS_COLORS:'di=1;31:' ; export LS_COLORS
    '';
    promptInit = ''
      if test $UID = 0; then
        PS1='\[\033[1;31m\]\w\[\033[0m\] '
        PROMPT_COMMAND='echo -ne "\033]0;$$ $USER@$PWD\007"'
      elif test $UID = 1337; then
        PS1='\[\033[1;32m\]\w\[\033[0m\] '
        PROMPT_COMMAND='echo -ne "\033]0;$$ $PWD\007"'
      else
        PS1='\[\033[1;33m\]\u@\w\[\033[0m\] '
        PROMPT_COMMAND='echo -ne "\033]0;$$ $USER@$PWD\007"'
      fi
      if test -n "$SSH_CLIENT"; then
        PS1='\[\033[35m\]\h'" $PS1"
        PROMPT_COMMAND='echo -ne "\033]0;$$ $HOSTNAME $USER@$PWD\007"'
      fi
    '';
  };

  services.journald.settings.Journal = {
    SystemMaxUse = "1G";
    RuntimeMaxUse = "128M";
    Storage = "persistent";
  };

  # nftables based NixOS firewall. Input and forward drop by default, as
  # krebs.iptables did; no reverse path filter either, the routers,
  # container hosts and NAT64 boxes route asymmetrically.
  networking.nftables = {
    enable = true;
    # Defaults to true on machines older than 23.11, which would also wipe
    # the tables libvirt, podman and jool keep on every reload.
    flushRuleset = false;
    # krebs.iptables loaded its rules through iptables-nft into these
    # tables; nothing removes them when it goes away. Drop once every
    # machine has switched to nftables.
    extraDeletions = ''
      table ip filter
      delete table ip filter
      table ip6 filter
      delete table ip6 filter
      table ip nat
      delete table ip nat
      table ip6 nat
      delete table ip6 nat
    '';
  };
  networking.firewall = {
    filterForward = lib.mkDefault true;
    checkReversePath = false;
    # all of ICMP, not just echo-request, like krebs.iptables
    extraInputRules = ''
      meta l4proto icmp accept
    '';
  };

  networking.firewall.allowedTCPPorts = [ 22 ]; # ssh
  lass.ports =
    lib.genAttrs (map toString (lib.range moshPorts.from moshPorts.to)) (port: "mosh-${port}")
    # multicast DNS, clan-core's recommended defaults open it in the firewall
    // lib.optionalAttrs config.services.resolved.enable { "5353" = "resolved-mdns"; };
  networking.firewall.allowedUDPPortRanges = [ moshPorts ];
  networking.extraHosts = ''
    10.42.0.1 acheron.gg23
    10.42.0.3 styx.gg23
  '';

  # use 24:00 time format, the default got sneakily changed around 20.03
  i18n.defaultLocale = lib.mkDefault "C.UTF-8";
  time.timeZone = lib.mkDefault "Europe/Berlin";

  # disable doc usually
  documentation.nixos.enable = lib.mkDefault false;
}
