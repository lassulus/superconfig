# attr -> { cmd, pname, version, name } for every flake package with an
# updateScript written for this flake. One getFlake call, so the source path
# and both package sets come from the same snapshot of the (possibly dirty)
# tree. Host entries win; x86_64-linux fills in linux-only packages.
{ flake, host }:
let
  f = builtins.getFlake flake;
  src = toString f.outPath + "/";

  # Only scripts written for this flake: nix-update with --flake, or a script
  # inside this flake. Packages wrapping nixpkgs or flake-input packages
  # otherwise inherit an updateScript meant for that checkout; those follow
  # flake.lock instead.
  isOurs = s: s == "--flake" || builtins.substring 0 (builtins.stringLength src) s == src;

  entry =
    n: p:
    let
      u = p.passthru.updateScript or null;
      c =
        if builtins.isList u then
          u
        else if builtins.isAttrs u && u ? command then
          (if builtins.isList u.command then u.command else [ u.command ])
        else
          [ u ];
      v = {
        cmd = map toString c;
        pname = p.pname or n;
        version = p.version or "";
        name = p.name or n;
      };
    in
    if u == null || !(builtins.any isOurs v.cmd) then null else builtins.deepSeq v v;

  # Per package tryEval: one package refusing to evaluate on this system must
  # not hide the rest.
  scripts =
    system:
    builtins.mapAttrs (
      n: p:
      let
        r = builtins.tryEval (entry n p);
      in
      if r.success then r.value else null
    ) (f.packages.${system} or { });

  merged = (if host == "x86_64-linux" then { } else scripts "x86_64-linux") // scripts host;
in
builtins.removeAttrs merged (builtins.filter (n: merged.${n} == null) (builtins.attrNames merged))
