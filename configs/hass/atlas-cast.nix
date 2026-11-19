# Home Assistant side of machines/atlas/cast.nix: switch.atlas_cast starts
# and stops the livestream of atlas' screen to https://cast.lassul.us,
# through atlas-cast-control on atlas over retiolum. Its bearer token (the
# shared atlas-cast-control var) is in the container's environment and read
# with !env_var, so it stays out of the Nix store; that tag is why this
# package is written as YAML (JSON with the tag spliced in) instead of the
# plain JSON of ../gg23/tv-hass.nix.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # lass.ports of machines/atlas/cast.nix; not read from atlas' config, that
  # would evaluate it
  atlas = "http://${self.inputs.kartei.hosts.atlas.nets.retiolum.ip4.addr}:8086";
  state = "binary_sensor.atlas_cast_running";
  auth = "@ATLAS_CAST_AUTHORIZATION@";
  headers.Authorization = auth;

  # start or stop, a notification when atlas does not answer or fails, then
  # the switch's state right away instead of with the next poll
  action = command: [
    {
      action = "rest_command.atlas_cast";
      data = { inherit command; };
      response_variable = "result";
      continue_on_error = true;
    }
    {
      "if" = [
        {
          condition = "template";
          value_template = "{{ result is not defined or result.status != 200 }}";
        }
      ];
      "then" = [
        {
          action = "persistent_notification.create";
          data = {
            title = "atlas cast: can't ${command}";
            message = "{{ result.content if result is defined else 'atlas-cast-control on atlas is not reachable' }}";
          };
        }
      ];
    }
    {
      action = "homeassistant.update_entity";
      target.entity_id = state;
    }
  ];

  package = {
    rest_command.atlas_cast = {
      url = "${atlas}/cast/{{ command }}";
      method = "post";
      inherit headers;
      timeout = 60;
    };
    # GET /cast: on while the stream runs or is retried, off when stopped
    rest = [
      {
        resource = "${atlas}/cast";
        inherit headers;
        scan_interval = 10;
        binary_sensor = [
          {
            name = "atlas cast running";
            unique_id = "atlas_cast_running";
            # atlas-cast-control answers with a trailing newline
            value_template = "{{ value | trim == 'on' }}";
          }
        ];
      }
    ];
    template = [
      {
        switch = [
          {
            name = "atlas cast";
            unique_id = "atlas_cast";
            icon = "mdi:broadcast";
            state = "{{ is_state('${state}', 'on') }}";
            availability = "{{ has_value('${state}') }}";
            turn_on = action "start";
            turn_off = action "stop";
          }
        ];
      }
    ];
  };

  yaml = pkgs.writeText "atlas_cast.yaml" (
    lib.replaceStrings [ ''"${auth}"'' ] [ " !env_var ATLAS_CAST_AUTHORIZATION" ] (
      builtins.toJSON package
    )
  );
in
{
  imports = [ ../atlas-cast-vars.nix ];

  virtualisation.oci-containers.containers.homeassistant = {
    # the file name is the package name, which has to be a slug
    volumes = [ "${yaml}:/config/packages/atlas_cast.yaml:ro" ];
    environmentFiles = [
      config.clan.core.vars.generators.atlas-cast-control.files."hass.env".path
    ];
  };
}
