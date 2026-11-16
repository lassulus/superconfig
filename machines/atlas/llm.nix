{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Qwen3.8-27B with its refusals removed (abliterated). IQ4_XS (14.4 GB)
  # fits the 16 GB of the RX 6800 XT together with the context.
  model = {
    name = "qwen3.8-27b-abliterated";
    file = "Huihui-Qwen3.8-27B-abliterated-UD-IQ4_XS.gguf";
    url = "https://huggingface.co/huihui-ai/Huihui-Qwen3.8-27B-abliterated-GGUF/resolve/c4b90228246aef7ecc6cb2be9d80575a911a0f3a/Huihui-Qwen3.8-27B-abliterated-UD-IQ4_XS.gguf";
    sha256 = "d83adbbbaace8acdfcfe28004f779326176b9df00b4ec99dc6c24d749723d3b9";
  };
  dir = "/var/lib/llm-models";
in
{
  # The model is too big for the nix store (CI would build and cache it), so
  # it is downloaded once into the state dir and checked against the hash.
  # Files of earlier models are removed.
  systemd.services.llm-model-download = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [ pkgs.curl ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "llm-models";
      WorkingDirectory = dir;
    };
    script = ''
      find . -maxdepth 1 -type f ! -name ${model.file} ! -name ${model.file}.part -delete
      [ -e ${model.file} ] && exit 0
      curl -fsSL -C - --retry 5 -o ${model.file}.part ${model.url}
      if ! echo "${model.sha256}  ${model.file}.part" | sha256sum -c; then
        rm ${model.file}.part
        exit 1
      fi
      mv ${model.file}.part ${model.file}
    '';
  };

  # llama-swap starts llama-server on the first request and stops it after
  # 10 minutes without one, so the GPU is free for games in between.
  # Web UI and OpenAI-compatible API on http://atlas.r:8080 (retiolum only).
  services.llama-swap = {
    enable = true;
    listenAddress = "0.0.0.0";
    settings = {
      # loading 14 GB into VRAM
      healthCheckTimeout = 300;
      models.${model.name} = {
        # 8-bit KV cache: twice the context (~50k instead of ~27k on 16 GB),
        # no measurable quality loss, same speed
        cmd = "${lib.getExe' pkgs.llama-cpp-vulkan "llama-server"} --port \${PORT} -m ${dir}/${model.file} -fa on -ctk q8_0 -ctv q8_0";
        ttl = 600;
      };
    };
  };
  systemd.services.llama-swap = {
    requires = [ "llm-model-download.service" ];
    after = [ "llm-model-download.service" ];
  };

  lass.ports.${toString config.services.llama-swap.port} = "llama-swap";
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [
    config.lass.servicePorts.llama-swap
  ];
}
