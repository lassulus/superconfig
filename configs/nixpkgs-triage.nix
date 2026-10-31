{ config, self, ... }:
let
  domain = "review.lassul.us";
  port = 8476;
in
{
  lass.ports.${toString port} = "nixpkgs-triage";

  # read-only dashboard of open nixpkgs PRs (github.com/Lassulus/nixpkgs-triage)
  imports = [ self.inputs.nixpkgs-triage.nixosModules.default ];

  services.nixpkgs-triage = {
    enable = true;
    inherit port;
    environmentFile = config.clan.core.vars.generators.nixpkgs-triage.files.env.path;
  };

  clan.core.vars.generators.nixpkgs-triage = {
    files.env = { };
    prompts.token = {
      description = "GitHub token for syncing open nixpkgs PRs (read-only access to public repos is enough)";
      type = "hidden";
      persist = false;
    };
    script = ''
      printf 'GITHUB_TOKEN=%s\n' "$(tr -d '\n' < "$prompts/token")" > "$out/env"
    '';
  };

  services.nginx.virtualHosts.${domain} = {
    enableACME = true;
    forceSSL = true;
    locations."/".proxyPass = "http://127.0.0.1:${toString port}";
  };
}
