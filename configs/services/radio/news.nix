{
  self,
  config,
  pkgs,
  ...
}:
let
  news = "/home/radio-news/news";

  # GET / lists the news, POST / adds a JSON object { from, to, text, priority }
  newsCgi = pkgs.writers.writeDash "radio-news-cgi" ''
    case "$REQUEST_METHOD $DOCUMENT_URI" in
      "GET /")
        printf 'Content-Type: application/json\r\n\r\n'
        cat ${news} 2>/dev/null | ${pkgs.jq}/bin/jq -sc .
        ;;
      "POST /")
        if entries=$(${pkgs.jq}/bin/jq -c '{ from, to, text, priority: (.priority // 0) }'); then
          printf '%s\n' "$entries" >> ${news}
          printf 'Status: 200 OK\r\n\r\n'
        else
          printf 'Status: 400 Bad Request\r\n\r\n'
        fi
        ;;
      *)
        printf 'Status: 404 Not Found\r\n\r\n'
        ;;
    esac
  '';

  send_to_radio = pkgs.writers.writeDashBin "send_to_radio" ''
    ${pkgs.vorbis-tools}/bin/oggenc - |
      ${self.packages.${pkgs.stdenv.hostPlatform.system}.cyberlocker-tools}/bin/cput news.ogg
    ${pkgs.curl}/bin/curl -fSs -X POST http://localhost:${toString config.lass.servicePorts.radio}/newsshow
  '';

  gc_news = pkgs.writers.writeDashBin "gc_news" ''
    set -xefu
    export TZ=UTC #workaround for jq parsing wrong timestamp
    ${pkgs.coreutils}/bin/cat $HOME/news | ${pkgs.jq}/bin/jq -cs 'map(select((.to|fromdateiso8601) > now)) | .[]' > $HOME/bla-news.tmp
    ${pkgs.coreutils}/bin/mv $HOME/bla-news.tmp $HOME/news
  '';

  get_current_news = pkgs.writers.writeDashBin "get_current_news" ''
    set -xefu
    export TZ=UTC #workaround for jq parsing wrong timestamp
    ${pkgs.coreutils}/bin/cat $HOME/news | ${pkgs.jq}/bin/jq -rs '
      sort_by(.priority) |
      map(select(
        ((.to | fromdateiso8601) > now) and
        (.from|fromdateiso8601) < now) |
        .text
      ) | .[]'
  '';

  newsshow =
    pkgs.writers.writeDashBin "newsshow" # sh
      ''
        cat << EOF
        hello crabpeople!
        $(${pkgs.ddate}/bin/ddate +'Today is %{%A, the %e of %B%}, %Y. %N%nCelebrate %H')
        It is $(date --utc +%H) o clock U.T.C.
        todays news:
        $(get_current_news)
        $(gc_news)
        EOF
      '';
in
{
  systemd.services.newsshow = {
    path = [
      newsshow
      send_to_radio
      gc_news
      get_current_news
      pkgs.retry
    ];
    script = ''
      set -efu
      retry -t 5 -d 10 -- newsshow |
        retry -t 5 -d 10 -- /run/current-system/sw/bin/tts |
        retry -t 5 -d 10 -- send_to_radio
    '';
    startAt = "*:00:00";
    serviceConfig = {
      User = "radio-news";
    };
  };

  services.nginx.virtualHosts."radio-news.r" = {
    locations."/".extraConfig = ''
      add_header 'Access-Control-Allow-Origin' '*';
      add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
      include ${config.services.nginx.package}/conf/fastcgi_params;
      fastcgi_param SCRIPT_FILENAME ${newsCgi};
      fastcgi_pass unix:${config.services.fcgiwrap.instances.radio-news.socket.address};
    '';
  };
  imports = [
    ./tts.nix
  ];
  services.fcgiwrap.instances.radio-news = {
    process.user = "radio-news";
    process.group = "radio-news";
    socket.user = config.services.nginx.user;
    socket.group = config.services.nginx.group;
  };
  users.users.radio-news = {
    isSystemUser = true;
    group = "radio-news";
    home = "/home/radio-news";
    createHome = true;
  };
  users.groups.radio-news = { };

  # debug
  environment.systemPackages = [
    send_to_radio
    newsshow
    get_current_news
    gc_news
  ];
}
