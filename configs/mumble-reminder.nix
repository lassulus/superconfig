{
  config,
  lib,
  pkgs,
  ...
}:
let
  write_to_irc =
    chan:
    pkgs.writers.writeDash "write_to_irc" ''
      ${pkgs.curl}/bin/curl -fsSv --unix-socket '${lib.removePrefix "unix:" config.krebs.reaktor2.mumble-reminder.API.listen}' http://z/ \
        -H content-type:application/json \
        -d "$(${pkgs.jq}/bin/jq -n \
          --arg text "$1" '{
            command:"PRIVMSG",
            params:["${chan}",$text]
          }'
        )"
    '';
  # mIRC strikethrough (0x1e) around a word; the meetup moved from Wednesday
  # to Thursday
  struck = word: "$(printf '\\036')${word}$(printf '\\036')";
  animals = ''
    Erdferkel
    Paviane
    Raupen
    Australischen Wildhunde
    Emus
    Flundern
    Gorillas
    Kolibris
    Schwarzfersenantilopen
    Quallen
    Kois
    Faulaffen
    Schraubenziegen
    Nachtigallen
    Okapis
    Stachelschweine
    Kurzschwanzkängurus
    Waschbären
    Kurzschwanzwiesel
    Buschochsen
    Kurzschwanzaffen
    Vicuñas
    Goldwaldsänger
    Nachtechsen
    Halbmond-Lanzenotter
  '';
  systemPlugin = {
    plugin = "system";
    config = {
      hooks.PRIVMSG = [
        {
          pattern = "^erinner mich$";
          activate = "match";
          command = {
            filename = pkgs.writers.writeDash "add_remind" ''
              echo "$_from" >> /var/lib/reaktor2-mumble-reminder/users
              sort /var/lib/reaktor2-mumble-reminder/users | uniq > /var/lib/reaktor2-mumble-reminder/users.tmp
              mv /var/lib/reaktor2-mumble-reminder/users.tmp /var/lib/reaktor2-mumble-reminder/users
              echo "Ich werde $_from in zukunft an das meetup erinnern"
            '';
          };
        }
        {
          pattern = "^nerv nicht$";
          activate = "match";
          command = {
            filename = pkgs.writers.writeDash "del_remind" ''
              ${pkgs.gnused}/bin/sed -i "/$_from/d" /var/lib/reaktor2-mumble-reminder/users
              echo "okok, Ich werde $_from nich mehr erinnern"
            '';
          };
        }
      ];
    };
  };

in
{
  krebs.reaktor2.mumble-reminder = {
    hostname = "irc.hackint.org";
    nick = "lassulus__";
    API.listen = "unix:/var/lib/reaktor2-mumble-reminder/reaktor_hackint.sock";
    plugins = [
      {
        plugin = "register";
        config = {
          channels = [
            "#krebs"
            "#nixos"
          ];
        };
      }
      systemPlugin
    ];
    port = "6697";
  };
  systemd.services.mumble-reminder-nixos = {
    description = "weekly reminder for nixos mumble";
    startAt = "Thu *-*-* 18:00:00 Europe/Berlin";
    serviceConfig = {
      ExecStart = pkgs.writers.writeDash "mumble_reminder" ''
        animals='
          ${animals}
        '
        ${write_to_irc "#nixos"} "Es ist ${struck "Mittwoch"} Donnerstag meine $(echo "$animals" | grep -v '^$' | shuf -n1 )!"
        ${write_to_irc "#nixos"} "kommt auf https://jitsi.lassul.us/space"
      '';
    };
  };
  systemd.services.mumble-reminder-krebs = {
    description = "weekly reminder for nixos mumble";
    startAt = "Thu *-*-* 18:00:00 Europe/Berlin";
    serviceConfig = {
      ExecStart = pkgs.writers.writeDash "mumble_reminder" ''
        animals='
          ${animals}
        '
        ${write_to_irc "#krebs"} "Es ist ${struck "Mittwoch"} Donnerstag meine $(echo "$animals" | grep -v '^$' | shuf -n1 )!"
        ${write_to_irc "#krebs"} "$(cat /var/lib/reaktor2-mumble-reminder/users | ${pkgs.findutils}/bin/xargs echo) : jitsi?"
        ${write_to_irc "#krebs"} "https://jitsi.lassul.us/space"
      '';
    };
  };
}
