{ pkgs, ... }:
let

  xdg-open = pkgs.writers.writeBashBin "xdg-open" ''
    set -xe
    FILE="$1"
    PATH=/run/current-system/sw/bin
    mime=

    case "$FILE" in
      http://*|https://*)
        mime=text/html
        ;;
      mailto:*)
        mime=special/mailaddress
        ;;
      magnet:*)
        mime=application/x-bittorrent
        ;;
      irc:*)
        mime=x-scheme-handler/irc
        ;;
      "")
        echo "empty file" 1>&2
        exit 0
        ;;
      *)
        # it’s a file

        # strip possible protocol
        FILE=''${FILE#file://}
        mime=''$(file -E --brief --mime-type "$FILE") \
          || (echo "$mime" 1>&2; exit 1)
          # ^ echo the error message of file
        ;;
    esac

    case "$mime" in
      special/mailaddress)
        alacritty --execute vim "$FILE" ;;
      text/html)
        firefox "$FILE" ;;
      text/xml)
        firefox "$FILE" ;;
      text/*)
        alacritty --execute vim "$FILE" ;;
      image/*)
        nsxiv "$FILE" ;;
      application/pdf)
        zathura "$FILE" ;;
      inode/directory)
        alacritty --execute mc "$FILE" ;;
      inode/symlink)
        exec "$0" "$(realpath "$FILE")" ;;
      audio/*)
        mpv "$FILE" ;;
      video/*)
        mpv "$FILE" ;;
      *)
        echo $TERM >> /tmp/xdg.debug
        # open dmenu and ask for program to open with
        runner=$({ IFS=:; ls -H $PATH; } | sort | dmenu)
        exec $runner "$FILE";;
    esac
  '';
in
{
  environment.systemPackages = [ xdg-open ];
}
