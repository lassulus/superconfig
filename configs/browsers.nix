{ pkgs, self, ... }:
{
  environment.systemPackages = [
    self.packages.${pkgs.system}.firefox
    self.packages.${pkgs.system}.workspace-browser
    # MCP server bridging to the Browser MCP extension of our firefox
    self.packages.${pkgs.system}.browser-mcp
  ];
  environment.variables.BROWSER = "/run/current-system/sw/bin/firefox";
}
