# Shared facts of the monitoring stack, imported (not as a module) by
# agent.nix, server.nix, alerts.nix and checks.nix.
{
  # Every machine writes metrics and logs to all of these (via <name>.r).
  servers = [
    "styx"
    "coaxmetal"
  ];

  # Machines expected to be up all the time. Only these get HostDown alerts
  # and ICMP checks, so laptops can come and go silently.
  alwaysOn = [
    "neoprism"
    "styx"
    "coaxmetal"
    "acheron"
    "orange"
    "radio"
    "icarus"
    "shodan"
    "starkstrom"
  ];

  ports = {
    victoriametrics = 8428;
    victorialogs = 9428;
    vmalert = 8880;
    vmalert-logs = 8881; # localhost only
    alertmanager = 9093;
    alertmanager-cluster = 9094;
    matrix-receiver = 9095; # localhost only
    gatus = 8080;
    grafana = 3000;
  };
}
