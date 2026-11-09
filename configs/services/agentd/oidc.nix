# Logins from agentd-web (web.nix): it forwards the user's id.lassul.us token,
# whose audience is the web app's client id. Zitadel generates that id on its
# own host, so a shared var carries it to every agentd host.
{ config, ... }:
{
  services.agentd = {
    auth.oidc = {
      issuer = "https://id.lassul.us";
      audienceFile = config.clan.core.vars.generators.agentd-oidc.files.client-id.path;
    };
    # lass's Zitadel user id: Zitadel access tokens have no email claim.
    users = [ "395780385822936760" ];
  };

  clan.core.vars.generators.agentd-oidc = {
    share = true;
    files.client-id = { };
    prompts.client-id.description = "Client id of the Zitadel app agentd/web (CLIENT_ID in /var/lib/zitadel-apps/agentd-web.env on the Zitadel host)";
    script = ''
      cp "$prompts"/client-id "$out"/client-id
    '';
  };
}
