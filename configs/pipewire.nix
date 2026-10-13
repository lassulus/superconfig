{ pkgs, ... }:
{
  security.rtkit.enable = true;

  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  environment.systemPackages = with pkgs; [
    alsa-utils
    pulseaudio
    ponymix
    bluetuith
  ];

  users.users.mainUser.extraGroups = [
    "bluetooth"
    "pipewire"
  ];

  services.pipewire = {
    enable = true;
    systemWide = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  # WirePlumber's bluez monitor calls node:activate() on the result of
  # LocalNode(), which is nil when the adapter factory refuses the node. The
  # WH-1000XM5 triggers that whenever its audio transport dies ("spa.bluez5:
  # Failure in Bluetooth audio transport", then "mod.adapter: can't get
  # format: Invalid argument"): the Lua hook throws, its AsyncEventHook
  # transition never completes, and the event dispatcher stalls for good --
  # after which no node ever activates again, the ALSA sinks sit in SUSPENDED,
  # and every player blocks until
  # wireplumber is restarted by hand. Fail the transition instead.
  services.pipewire.wireplumber.package = pkgs.wireplumber.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/scripts/monitors/bluez/create-node.lua \
        --replace-fail \
          'local node = LocalNode("adapter", properties)' \
          'local node = LocalNode("adapter", properties)
        if node == nil then
          transition:return_error ("Failed to create BT node " .. tostring (properties["node.name"]))
          return
        end'
    '';
  });
}
