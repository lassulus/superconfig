{
  imports = [
    ../../configs
    ../../configs/retiolum.nix
    ../../configs/ssh-redirect.nix
    ../../configs/autoupdate.nix
    ../../configs/sigexec/executor.nix
    ./ipfs.nix
    ./ipfs-endpoint.nix
  ];

  # The sigexec dashboard on neoprism reaches this executor over public TLS
  # (set up before starkstrom had a kartei card; starkstrom.r would work now):
  # nginx strips /sigexec/ so the executor verifies the same paths the
  # statements were signed over (/jobs etc).
  services.nginx.virtualHosts."starkstrom.lassul.us".locations."/sigexec/" = {
    proxyPass = "http://127.0.0.1:7601/";
    extraConfig = ''
      # Long-lived chunked job streams: unbuffered, generous timeouts (logs on
      # a pending job blocks until approval).
      proxy_buffering off;
      proxy_read_timeout 1d;
      proxy_send_timeout 1d;
    '';
  };

  system.stateVersion = "25.11";
}
