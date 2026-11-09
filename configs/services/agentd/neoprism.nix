# neoprism's agentd (base in default.nix), the local backend of the web UI
# (web.nix); Hermes drives it over retiolum (http://neoprism.r:8790).
{
  imports = [ ./default.nix ];

  lass.ports."8790" = "agentd";
}
