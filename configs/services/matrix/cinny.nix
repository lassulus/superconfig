{ pkgs, ... }:
let
  # Cinny has no thread overview UI. Carry smokku's "threads-ui" drawer
  # (PR cinnyapp/cinny#2787, closed only due to Cinny's PR freeze during their
  # SDK rewrite) as a patch on top of the packaged release. Regenerate against
  # the new tag on each cinny bump; the patch touches ~16 files, conflicts have
  # historically been limited to RoomViewHeader.tsx.
  cinny-threads = pkgs.cinny.override {
    cinny-unwrapped = pkgs.cinny-unwrapped.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        ./cinny-threads-ui.patch
        # Independent of the threads patch. After a reload the sync only loads
        # the last 8 events per room; if the read receipt is older and only
        # membership/ACL events or reactions followed it, roomHaveUnread can't
        # find the receipt and marks the room unread. Ask the server whether a
        # message follows the receipt instead.
        ./cinny-unread-beyond-timeline.patch
        # With threadSupport, reactions/edits to events that aren't loaded live
        # in no timeline, so a room whose last 8 events are such relations
        # starts with an empty live timeline and opened at the oldest events of
        # the first back pagination. Show the latest events instead.
        ./cinny-empty-live-timeline.patch
      ];
      # Quack (https://www.youtube.com/watch?v=Fw3RB7xnb80) instead of the
      # stock chime; vite content-hashes it into assets/ at build time.
      postPatch = (old.postPatch or "") + ''
        cp ${./notification.ogg} public/sound/notification.ogg
      '';
    });
    conf = {
      defaultHomeserver = 0;
      homeserverList = [ "lassul.us" ];
      allowCustomHomeservers = true;
    };
  };
in
{
  services.nginx.virtualHosts."matrix.lassul.us" = {
    root = cinny-threads;
    locations = {
      "/".tryFiles = "$uri /index.html";
      # Store files have mtime=1970; without an explicit Cache-Control a browser
      # may heuristically cache the entry HTML for a long time and not pick up a
      # new build on reload. Force revalidation of index.html (cheap via etag),
      # and let the content-hashed assets cache hard.
      "= /index.html".extraConfig = ''
        add_header Cache-Control "no-cache";
      '';
      "/assets/".extraConfig = ''
        add_header Cache-Control "public, max-age=31536000, immutable";
      '';
    };
  };
}
