# Port allocation: every service claims its listening port once with
# `lass.ports."<port>" = "<service>"` and reads it back from
# `config.lass.servicePorts.<service>`. Two services claiming the same port
# (or one service two ports) fail evaluation with "conflicting definition
# values", naming both files, instead of a "bind: address already in use" at
# runtime.
{ config, lib, ... }:
{
  options.lass = {
    ports = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        "8790" = "hermes-voice";
      };
      description = "Allocated ports: port number -> the service listening on it.";
    };
    servicePorts = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = { };
      description = "Reverse map of lass.ports: service -> port. Set it via lass.ports.";
    };
  };

  config = {
    lass.servicePorts = lib.mkMerge (
      lib.mapAttrsToList (port: service: { ${service} = lib.toInt port; }) config.lass.ports
    );
    # attrsOf is lazy: force every entry, so a conflict fails every build and
    # not only one that happens to read the contested port. A conflict throws
    # inside the deepSeq with the "conflicting definition values" error, so
    # the assertion itself never fails.
    assertions = [
      {
        assertion = builtins.deepSeq config.lass.servicePorts true;
        message = "lass.ports: conflicting port allocation";
      }
    ];
  };
}
