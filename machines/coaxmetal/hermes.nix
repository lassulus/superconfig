{
  self,
  config,
  lib,
  pkgs,
  ...
}:
let
  # Pinned Piper voice for the bot's spoken replies. Single-speaker on purpose:
  # the radio's libritts-high (configs/services/radio/tts.nix) is multi-speaker
  # and needs an -s speaker id per call.
  piperVoice = pkgs.runCommand "piper-voice-en_US-amy-medium" { } ''
    mkdir -p $out
    ln -s ${
      pkgs.fetchurl {
        url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium/en_US-amy-medium.onnx?download=true";
        hash = "sha256-s6bke1e4x/vmoM4lGBYaUPWanN2KUINcAssCvdYgbBg=";
      }
    } $out/model.onnx
    ln -s ${
      pkgs.fetchurl {
        url = "https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/en/en_US/amy/medium/en_US-amy-medium.onnx.json?download=true";
        hash = "sha256-laI+tNQpCdON9zu5rH9F9Zfb/N4tG/lSb96vVGaXfXc=";
      }
    } $out/model.onnx.json
  '';

  # TTS backend for the gateway, wired as a `type: command` provider below.
  #
  # Hermes's built-in `tts.provider = "piper"` cannot work on this deployment:
  # it imports the `piper` Python module, which is in neither the sealed uv2nix
  # venv nor tools/lazy_deps.py's install allowlist, and the venv is a
  # read-only store path — so its lazy `pip install` has nowhere to land. Same
  # for the upstream default "edge" (lazy edge-tts). A command provider calls
  # nixpkgs' piper instead: no runtime pip, no runtime voice download.
  #
  # Contract: hermes writes the reply text to $1 and expects audio at $2.
  hermes-tts = pkgs.writeShellApplication {
    name = "hermes-tts";
    runtimeInputs = [ self.packages.${pkgs.stdenv.hostPlatform.system}.piper-tts ];
    text = ''
      piper --model ${piperVoice}/model.onnx --output-file "$2" < "$1"
    '';
  };

  # The gateway's webhook platform (settings.platforms.webhook below),
  # loopback only.
  webhookPort = 8644;

  # Post a message to Matrix through the running gateway: the
  # "notify" webhook route below hands it to the gateway's own Matrix adapter.
  # For the agent's shell scripts (phonetpm heads-ups, background deploys).
  # Posts into the calling session's room/thread, the home room otherwise.
  # `hermes send -t matrix` is no substitute: outside the gateway it opens a
  # second Matrix client on the gateway's device and crypto store, and the two
  # desync the Olm sessions until no client can decrypt Hermes any more.
  hermes-notify = pkgs.writeShellApplication {
    name = "hermes-notify";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnused
      pkgs.jq
      pkgs.openssl
    ];
    text = ''
      if [ $# -eq 0 ]; then
        echo "usage: hermes-notify <message>" >&2
        exit 2
      fi
      secret=$(sed -n 's/^WEBHOOK_SECRET=//p' "''${HERMES_HOME:-/var/lib/hermes/.hermes}/.env")
      body=$(jq -cn --arg text "$*" \
        --arg chat_id "''${HERMES_SESSION_CHAT_ID:-}" \
        --arg thread_id "''${HERMES_SESSION_THREAD_ID:-}" \
        '{text: $text, chat_id: $chat_id, thread_id: $thread_id}')
      stamp=$(date +%s)
      signature=$(printf '%s.%s' "$stamp" "$body" | openssl dgst -sha256 -hmac "$secret" -r | cut -d' ' -f1)
      curl -fsS --max-time 30 -o /dev/null \
        -H 'Content-Type: application/json' \
        -H "X-Webhook-Timestamp: $stamp" \
        -H "X-Webhook-Signature-V2: $signature" \
        --data-binary "$body" \
        http://127.0.0.1:${toString webhookPort}/webhooks/notify
    '';
  };

  # The package's override arguments do not reach its uv2nix python set, only
  # the uv2nix it is built with: wrap loadWorkspace so the workspace overlay
  # patches the hermes-agent wheel source. A patch that stops applying fails
  # the build.
  patchHermesWheel =
    uv2nix:
    lib.recursiveUpdate uv2nix {
      lib.workspace.loadWorkspace =
        args:
        let
          workspace = uv2nix.lib.workspace.loadWorkspace args;
        in
        workspace
        // {
          mkPyprojectOverlay =
            overlayArgs:
            lib.composeExtensions (workspace.mkPyprojectOverlay overlayArgs) (
              _final: prev:
              # pm-runtime.nix loads a second workspace without hermes-agent.
              lib.optionalAttrs (prev ? hermes-agent) {
                hermes-agent = prev.hermes-agent.overrideAttrs (old: {
                  patches = (old.patches or [ ]) ++ [ ./hermes-cron-matrix-dm-seed.patch ];
                });
              }
            );
        };
    };

in
{
  imports = [
    self.inputs.hermes-agent.nixosModules.default
    ../../configs/hermes-mail-vars.nix
    # Phone-approved ssh for the agent: the phonetpm user service runs in the
    # hermes user manager (the module sets linger), see SSH_AUTH_SOCK below.
    ../../configs/phonetpm.nix
  ];

  # Hermes Agent (Nous Research) — autonomous agent run as a native systemd
  # gateway, reachable over Matrix (@hermes:lassul.us). Model backend is our
  # shared llama cluster: one vLLM instance behind an OpenAI-compatible
  # endpoint, so the model is whatever the cluster currently serves and a swap
  # is a one-line settings.model.default change.
  services.hermes-agent = {
    enable = true;

    # Build the Matrix platform dependency group into the sealed venv (mautrix
    # SDK + liboqs for optional E2EE; Linux-only). "voice" adds faster-whisper,
    # which is what `stt.provider = "local"` below runs — that group exists
    # precisely because local STT pulls wheel-only transitive deps
    # (ctranslate2, onnxruntime) that uv2nix has to resolve at build time.
    # "anthropic" is the SDK the anthropic model provider imports; the venv is
    # sealed (lazy installs disabled), so without it every turn fails with
    # "The 'anthropic' package is required for the Anthropic provider".
    extraDependencyGroups = [
      "matrix"
      "voice"
      "anthropic"
    ];

    # Matrix DM cron briefs are seeded under the group session key, so the
    # in-thread reply never sees the brief (hermes-agent#141429); drop once
    # upstream fixes #141429.
    package =
      self.inputs.hermes-agent.packages.${pkgs.stdenv.hostPlatform.system}.default.override
        (old: {
          uv2nix = patchHermesWheel old.uv2nix;
        });

    # Put the Claude Code CLI on the agent's PATH so its bundled "claude-code"
    # skill can delegate coding via `terminal(command="claude -p '...'")`.
    # extraPackages lands in both the systemd service PATH and the hermes
    # user's profile. Auth is separate (run `claude` once as the hermes user).
    extraPackages = [
      self.legacyPackages.${pkgs.system}.llm.claude-code
      # Voice both ways: the Matrix adapter shells out to ffmpeg to transcode
      # piper's WAV to Ogg/Opus (native MSC3245 voice bubbles in Element) and
      # to ffprobe for the duration + waveform metadata those bubbles carry.
      pkgs.ffmpeg
      hermes-tts
      # CalDAV (calendar skill below) is plain HTTP; curl is not otherwise on
      # the gateway PATH.
      pkgs.curl
      # ssh through the phonetpm agent (SSH_AUTH_SOCK below).
      pkgs.openssh
      hermes-notify
    ];

    # Home Assistant (acheron, configs/hass) left hermes core for the
    # `homeassistant` catalog plugin: the ha_* tools plus a gateway platform
    # for state-change events. Pinned to the sha plugin-catalog/homeassistant.yaml
    # ships; its only Python dependency, aiohttp, is already in the venv via
    # the "matrix" group. HASS_TOKEN comes from hermes-env.
    #
    # The flake builds hermes as version 0.0.0 (pyproject.toml; no release
    # version is stamped), so the plugin's `requires_hermes: ">=0.21.5"` gate
    # refused to load it. The pinned hermes-agent input already has Home
    # Assistant moved out of core (hermes_cli/left_core_migration.py), so the
    # gate is met in substance; drop it.
    extraPlugins = [
      (pkgs.applyPatches {
        name = "homeassistant";
        src = pkgs.fetchFromGitHub {
          owner = "NousResearch";
          repo = "hermes-homeassistant";
          rev = "ba30cb0cf86c52bdb5cde98974bc062e97966529";
          hash = "sha256-Pg4smvkiVpmcmUola0rziMBfq5V7UjzX8864Dem76pI=";
        };
        postPatch = ''
          sed -i '/^requires_hermes:/d' plugin.yaml
        '';
      })
    ];
    # Non-bundled plugins are opt-in. The module links the plugin as
    # plugins/nix-managed-homeassistant, but the left-core migration only
    # recognizes plugins/homeassistant: without the marker it would see
    # HASS_TOKEN, call the plugin missing, and warn on every start that it
    # cannot fetch it (lazy installs are off in the sealed venv).
    # settings does not merge lists, so hermes-voice.nix's plugin is enabled
    # here as well.
    settings.plugins.enabled = [
      "homeassistant"
      "hermes-voice"
    ];
    settings._left_core_installed = [ "homeassistant" ];

    settings.model = {
      # Claude Opus 5.5 on lass's Claude subscription: the anthropic provider
      # takes the `claude setup-token` OAuth token (sk-ant-oat…) from
      # ANTHROPIC_TOKEN (hermes-anthropic generator below) and sends it as a
      # Bearer token. Anthropic bills third-party apps on subscription tokens
      # as extra usage; hermes renames some tools on the OAuth wire to avoid
      # that classification (agent/anthropic_adapter.py), which goes against
      # Anthropic's usage policies and risks the account. Chosen knowingly.
      #
      # Context (1M) and output (128k) limits come from hermes's own model
      # tables, so nothing is pinned here.
      provider = "anthropic";
      default = "claude-opus-5-5";
    };

    # The shared llama cluster stays configured as a named provider, so
    # `/model Qwen3.6-27B-FP8 --provider custom:llama` switches back. Its key
    # comes from hermes-env (key_env), never the nix store. It MUST be a
    # *named* custom provider ("custom:<name>" + this entry), not bare
    # "custom": bare custom resolves its credential from a host-gated list
    # (hermes_cli/runtime_provider.py:1244) that only forwards OPENAI_API_KEY
    # to openai.com and otherwise sends "no-key-required" (upstream #28660 /
    # GHSA-76xc-57q6-vm5m). api_mode is pinned because auto-detection only
    # runs as a fallback.
    settings.custom_providers = [
      {
        name = "llama";
        base_url = "https://inference.p0.contact/v1";
        key_env = "LLAMA_API_TOKEN";
        api_mode = "chat_completions";
      }
    ];

    # Voice in. Element voice notes arrive flagged MSC3245; the Matrix adapter
    # recognizes that flag and routes the audio to STT before the agent sees
    # the turn, so a held-down mic button is just another prompt.
    #
    # "local" = faster-whisper in-process (from the "voice" dep group). An
    # explicit provider is honored strictly: if it cannot run, transcription
    # errors out loud instead of silently falling back to a cloud key.
    settings.stt = {
      provider = "local";
      # "" = auto-detect per clip, instead of upstream's "en" hint — commands
      # here switch between English and German mid-conversation.
      language = "";
      # Vocabulary bias (faster-whisper initial_prompt). Every name here is one
      # the agent has to route on — a misheard host or tool name is a failed
      # command, not a typo.
      prompt = "Jargon: omp, nix, clan, retiolum, coaxmetal, neoprism, ignavia, lassulus.";
      local = {
        # small is the first size whose transcripts survive our jargon; a 4s
        # clip takes ~3s warm on this CPU (int8), ~6s from cold weights.
        model = "small";
        # Release the weights after five idle minutes; this is a laptop, and
        # the next voice note pays the reload instead of holding the RAM.
        unload_after_idle_seconds = 300;
      };
    };

    # Voice out. `voice_compatible` is the opt-in that makes the gateway treat
    # this provider's output as a voice message (Opus-transcoding it on the
    # way) rather than a file attachment, so replies land as playable bubbles.
    settings.tts = {
      provider = "piper-local";
      providers.piper-local = {
        type = "command";
        command = "${hermes-tts}/bin/hermes-tts {input_path} {output_path}";
        output_format = "wav";
        voice_compatible = true;
      };
    };

    # Text replies only: live voice moved to hermes-voice (assist.lassul.us,
    # hermes-voice.nix). Voice notes still reach the agent through STT, and
    # `/voice tts` in a chat still turns spoken replies on there.
    settings.voice.auto_tts = false;

    # In rooms Hermes requires an @mention by default; DMs always respond.
    settings.matrix.session_scope = "room";

    # A restart waits for running turns before it stops the gateway, and
    # refuses every new chat message during that wait. The default (1800 s)
    # let one turn waiting on an unanswered clarify block all chats for
    # 13 minutes. After 5 minutes the remaining turns are interrupted and
    # resume on the next message.
    settings.agent.restart_after_turn_timeout = 300;

    # Matrix is a Tier-2 platform whose default tool-progress preview caps
    # commands at 40 chars (so a `terminal` call shows only `curl -X POST -H
    # "Content-Type: applic...`). "verbose" makes the gateway render the FULL
    # command — multi-line — as a fenced code block instead of the truncated
    # one-liner. Trade-off: verbose also prints full JSON args for every other
    # tool call, so the channel is chattier.
    settings.display.platforms.matrix.tool_progress = "verbose";

    # The EMAIL_* credentials below are for mail-sending skills only. Hermes
    # turns the email gateway on by itself once all four of EMAIL_ADDRESS,
    # EMAIL_PASSWORD, EMAIL_IMAP_HOST and EMAIL_SMTP_HOST are set
    # (gateway/config_env.py); only an explicit `enabled: false` stops that.
    settings.platforms.email.enabled = false;

    # deliver_only routes post their rendered prompt to the Matrix home room
    # through the gateway, no agent turn. Signed with WEBHOOK_SECRET, the API
    # server key again (hermes-env). hermes-voice.nix adds voice-approval.
    settings.platforms.webhook = {
      enabled = true;
      extra = {
        host = "127.0.0.1";
        port = webhookPort;
        routes.notify = {
          deliver = "matrix";
          deliver_only = true;
          prompt = "{text}";
          deliver_extra = {
            chat_id = "{chat_id}";
            thread_id = "{thread_id}";
          };
        };
      };
    };

    # The one shared calendar (configs/radicale.nix): lass's own events, the
    # book.lassul.us requests and bookings, and anything Hermes adds. Hermes
    # authenticates as its own radicale user, which may only touch this
    # collection. Booking events are read back by book, so deleting, moving
    # or confirming them in CalDAV manages the booking (tools/book).
    hermesHomeFiles."skills/calendar/SKILL.md" = ''
      ---
      name: calendar
      description: Read and manage lass's calendar (CalDAV) and approve, decline or cancel book.lassul.us booking requests.
      version: 1.0.0
      license: MIT
      platforms: [linux]
      required_environment_variables:
        - name: CALDAV_PASSWORD
          prompt: Radicale password of the hermes user
          help: Provisioned by clan vars (radicale-hermes) on coaxmetal.
          required_for: any calendar access
      prerequisites:
        commands: [curl]
      metadata:
        hermes:
          tags: [calendar, caldav, schedule, booking, appointments]
          requires_toolsets: [terminal]
      ---

      # calendar

      lass has exactly one calendar, at `$CALDAV_CALENDAR_URL`
      (CalDAV on radicale). It holds his own events, booking requests and
      bookings from https://book.lassul.us, and events you add. The booking
      page treats every event in it as busy time.

      Use it when the user asks what is on his schedule, whether he is free,
      to add, move or remove an appointment, or about booking requests.

      Authenticate every request with
      `curl -sS -u "$CALDAV_USER:$CALDAV_PASSWORD"`. Never print, echo or
      repeat the password. Times are Europe/Berlin unless the user says
      otherwise; write DTSTART/DTEND with `;TZID=Europe/Berlin` or in UTC (`Z`).

      ## Reading

      Events overlapping a range (UTC, `YYYYMMDDTHHMMSSZ`):

      ```sh
      curl -sS -u "$CALDAV_USER:$CALDAV_PASSWORD" -X REPORT -H 'Depth: 1' \
        -H 'Content-Type: application/xml; charset=utf-8' "$CALDAV_CALENDAR_URL" --data '
      <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
        <D:prop><D:getetag/><C:calendar-data/></D:prop>
        <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">
          <C:time-range start="20261010T000000Z" end="20261017T000000Z"/>
        </C:comp-filter></C:comp-filter></C:filter>
      </C:calendar-query>'
      ```

      Each `<D:response>` has the event's `href` (its URL path), `getetag` and
      the iCalendar text. Recurring events (RRULE) come back once with their
      rule; expand them yourself when answering "what is on Tuesday".

      ## Adding, changing, removing your own events

      - Add: pick a UID (`uuidgen`-style, suffix `@hermes`), then
        `PUT "$CALDAV_CALENDAR_URL<uid>.ics"` with
        `-H 'Content-Type: text/calendar; charset=utf-8' -H 'If-None-Match: *'`
        and a body of one `VCALENDAR` (VERSION:2.0, PRODID) holding one
        `VEVENT` with UID, DTSTAMP, DTSTART, DTEND (or DURATION) and SUMMARY.
        Add a `VALARM` (ACTION:DISPLAY, TRIGGER:-PT15M) when the user wants a
        reminder.
      - Change: GET the event, edit it, PUT it back to the same href with
        `-H 'If-Match: <etag>'` so you never overwrite a concurrent edit.
      - Remove: `DELETE` the href with `-H 'If-Match: <etag>'`.
      - Success is HTTP 201/204. 412 means it changed meanwhile: re-read and
        retry. Confirm by reading the range again.

      Before adding, check the range for overlaps and tell the user about
      any. Do not change or delete events the user did not ask about.

      ## Booking requests and bookings (book.lassul.us)

      Events whose UID ends in `@book.lassul.us` come from the booking page.
      It reads them back every minute (for bookings that have not started
      yet) and mails the guest about what changed, so editing them is how
      bookings are managed:

      - Pending request: `STATUS:TENTATIVE`, SUMMARY starts with `? `.
      - Booked: `STATUS:CONFIRMED`.
      - The DESCRIPTION holds the guest (`Name <email>`), their note, and as
        its last line the admin link `https://book.lassul.us/a/<token>`.

      | Calendar edit | Effect, guest mail |
      | --- | --- |
      | DELETE a booked event (or set `STATUS:CANCELLED`) | cancelled, guest gets a cancellation |
      | DELETE a pending request | declined, guest gets a decline |
      | Change DTSTART/DTEND | rescheduled; a booked guest gets the updated invitation |
      | Set a pending request to `STATUS:CONFIRMED` | approved, guest gets the invitation |

      Use If-Match as for your own events. The booking page rewrites SUMMARY
      and DESCRIPTION itself; edits to them are not kept. Act on a booking
      only when the user decided to.

      To send the guest a personal message with the decision, use the admin
      link instead (an optional `message` is mailed along):

      ```sh
      curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
        --data-urlencode 'message=Looking forward to it' \
        'https://book.lassul.us/a/<token>/approve'   # or /decline, /cancel
      ```

      A 303 means it worked. `GET` on the admin link shows the request's
      current state. Treat admin links as secrets: never paste one into a
      chat unless the user asks for it.
    '';

    # Non-secret connection + SECURITY gate. Invites are auto-accepted and that
    # cannot be disabled, so the agent may join any room it's invited to. Joining
    # is harmless on its own — what matters is who can *trigger* the agent, which
    # on this host has terminal / filesystem / web tools (chat-driven RCE).
    # MATRIX_ALLOWED_USERS is the universal trigger gate (applies even in DMs);
    # only these MXIDs can make the agent act, in any room it's joined.
    environment = {
      MATRIX_HOMESERVER = "https://matrix.lassul.us";
      MATRIX_USER_ID = "@hermes:lassul.us";
      MATRIX_ALLOWED_USERS = "@lassulus:lassul.us";
      # The DM with lassulus: default target for deliver=matrix (cron jobs,
      # the voice-approval webhook and the matrix_dm_send tool of
      # hermes-voice.nix). Without it cron delivery fails with "no delivery
      # target resolved for deliver=matrix".
      MATRIX_HOME_ROOM = "!QSmQTYGdeExThpCqNh:lassul.us";
      # Each top-level DM message starts a thread; each thread is its own session.
      MATRIX_DM_AUTO_THREAD = "true";

      # The shared calendar (calendar skill above); CALDAV_PASSWORD comes from
      # hermes-env.
      CALDAV_USER = "hermes";
      CALDAV_CALENDAR_URL = "https://cal.lassul.us/lass/calendar/";

      # Home Assistant on acheron, over retiolum (configs/hass opens 8123 there).
      HASS_URL = "http://acheron.r:8123";

      # Element makes DMs end-to-end encrypted by default, so the bot must do
      # E2EE or it can't read messages. The `matrix` dep group already bundles
      # mautrix[encryption] (python-olm); "optional" initializes E2EE when those
      # deps are present (they are) and keeps the crypto store under
      # /var/lib/hermes/.hermes/platforms/matrix/store/.
      MATRIX_E2EE_MODE = "optional";
      # Element is moving to exclude devices their owner did not cross-sign
      # (MSC4153). With this set the adapter bootstraps cross-signing once (no
      # master key on the account yet) and signs its device; the key is
      # written here 0600 and never overwritten. Move it into pass afterwards;
      # it is needed only to cross-sign a new device id (MATRIX_RECOVERY_KEY).
      MATRIX_RECOVERY_KEY_OUTPUT_FILE = "/var/lib/hermes/.hermes/matrix-recovery-key";
      # Optional defense-in-depth (confine to specific rooms; DMs are exempt):
      # MATRIX_ALLOWED_ROOMS = "!yourRoomId:lassul.us";

      # The OpenAI-compatible API server: the assistant-button lane, reached
      # both directly from massulus.r and through the public
      # hermes.lassul.us proxy on neoprism. API_SERVER_KEY comes from clan
      # vars via environmentFiles; API_SERVER_HOST is written at start by the
      # ExecStartPre below (the retiolum address). Unlike Matrix there is no
      # per-user allowlist here — the bearer token is the whole gate.
      API_SERVER_ENABLED = "true";
      API_SERVER_PORT = "8642";

      # Mailbox hermes@lassul.us on neoprism (configs/mailserver.nix).
      # EMAIL_PASSWORD comes from the shared hermes-mail var via hermes-env.
      # 993 is implicit-TLS IMAP, 465 is implicit-TLS submission (smtps).
      EMAIL_ADDRESS = "hermes@lassul.us";
      EMAIL_IMAP_HOST = "mail.lassul.us";
      EMAIL_IMAP_PORT = "993";
      EMAIL_SMTP_HOST = "mail.lassul.us";
      EMAIL_SMTP_PORT = "465";
    };

    # Secrets (MATRIX_ACCESS_TOKEN, LLAMA_API_TOKEN, API_SERVER_KEY,
    # EMAIL_PASSWORD, HASS_TOKEN) come from clan vars below,
    # merged into $HERMES_HOME/.env at activation. WEBHOOK_SECRET is the API
    # server key again: hermes-voice signs its webhook posts with it
    # (hermes-voice.nix).
    environmentFiles = [
      config.clan.core.vars.generators.hermes-env.files."hermes.env".path
    ];
  };

  # ssh as hermes signs with the phone key (keys/ssh/phonetpm_massulus.pub,
  # authorized on all hosts): every login asks for a fingerprint on the phone.
  # The daemon only starts once paired:
  #   sudo -u hermes phonetpm pair <endpoint id>
  #   systemctl --user -M hermes@ start phonetpm
  # %U is the hermes uid, so this is the user manager's %t/phonetpm/agent.sock.
  systemd.services.hermes-agent.environment.SSH_AUTH_SOCK = "/run/user/%U/phonetpm/agent.sock";

  # Boot-race guard. matrix.lassul.us is IPv6-only; on this desktop
  # network-online.target can fire before v6 DNS is ready, so the gateway's
  # first Matrix connect fails ("Name or service not known") and it does not
  # retry — leaving the bot silent until a manual restart. Block startup until
  # the homeserver resolves (best-effort, ~60s cap) so reboots come up
  # connected.
  #
  # The second entry resolves the API server's bind address (see the
  # API_SERVER_* environment above). Retiolum, because both consumers live
  # there: massulus.r talks to it directly, and neoprism reverse-proxies it
  # to hermes.lassul.us. This host joins untrusted networks, so binding the
  # mesh address rather than "::" keeps the listener off café wifi even
  # before the packet filter sees it; the public door is nginx on neoprism,
  # which we control.
  #
  # It is resolved at start rather than hardcoded because the address derives
  # from the retiolum key in clan vars, so a regenerated key would otherwise
  # leave the unit bound to a stale literal. It waits because the interface
  # gets its address after network-online, and aiohttp cannot bind an address
  # that does not exist yet. "+" runs it as root: /run is not writable by
  # hermes.
  systemd.services.hermes-agent.serviceConfig.ExecStartPre = [
    "${pkgs.writeShellScript "hermes-wait-matrix-dns" ''
      i=0
      while [ "$i" -lt 30 ]; do
        ${pkgs.getent}/bin/getent ahosts matrix.lassul.us >/dev/null 2>&1 && exit 0
        ${pkgs.coreutils}/bin/sleep 2
        i=$((i + 1))
      done
      echo "matrix.lassul.us did not resolve within 60s; starting anyway" >&2
      exit 0
    ''}"
    "+${pkgs.writeShellScript "hermes-api-bind-retiolum" ''
      set -eu
      i=0
      while [ "$i" -lt 30 ]; do
        addr=$(${pkgs.iproute2}/bin/ip -6 -o addr show dev retiolum scope global \
          | ${pkgs.gawk}/bin/awk '{print $4}' | ${pkgs.coreutils}/bin/cut -d/ -f1 \
          | ${pkgs.coreutils}/bin/head -n1)
        if [ -n "$addr" ]; then
          ${pkgs.coreutils}/bin/mkdir -p /run/hermes-api
          echo "API_SERVER_HOST=$addr" > /run/hermes-api/host.env
          ${pkgs.coreutils}/bin/chmod 0444 /run/hermes-api/host.env
          exit 0
        fi
        ${pkgs.coreutils}/bin/sleep 2
        i=$((i + 1))
      done
      # No retiolum address: leave the file absent so the API server falls
      # back to its 127.0.0.1 default rather than silently listening on every
      # interface. The Matrix lane keeps working either way.
      ${pkgs.coreutils}/bin/rm -f /run/hermes-api/host.env
      echo "retiolum has no global address after 60s; API server stays on localhost" >&2
      exit 0
    ''}"
    # Bundled skills are copied out of the Nix store with shutil.copytree,
    # which keeps the store's r-x/r-- modes, so skill_manage could not patch
    # them ("Permission denied: skills/productivity/maps/.tmp_…"). Seed them
    # here instead of at gateway start, then make them writable; the gateway's
    # own sync then finds nothing to copy (its hash is content-only, so the
    # chmod does not mark them user-modified). `opt-in` only drops the
    # .no-bundled-skills marker, which this host never sets.
    "${pkgs.writeShellScript "hermes-skills-writable" ''
      set -eu
      hermes skills opt-in --sync
      ${pkgs.findutils}/bin/find ${config.services.hermes-agent.stateDir}/.hermes/skills \
        ! -perm -u+w -exec ${pkgs.coreutils}/bin/chmod u+w {} +
    ''}"
  ];

  # The packet filter drops INPUT by default here (configs/default.nix sets
  # filter.INPUT.policy = "DROP"), so the API server's port has to be opened
  # for the interface it binds. Without this neoprism's proxy_pass times out
  # and hermes.lassul.us answers 504, while a local curl to the same
  # address:port returns 200 — traffic to the host's own address goes through
  # lo, which is accepted.
  networking.firewall.interfaces.retiolum.allowedTCPPorts = [ 8642 ];

  # "-" because the file is absent until the ExecStartPre above finds an
  # address, and a missing bind override must not fail the unit.
  systemd.services.hermes-agent.serviceConfig.EnvironmentFile = [
    "-/run/hermes-api/host.env"
  ];

  # Matrix bot access token for @hermes:lassul.us (minted against the neoprism
  # Synapse). persist=true so the prompt value is stored once.
  clan.core.vars.generators.hermes-matrix.prompts.matrix-access-token = {
    description = "Matrix access token for @hermes:lassul.us";
    type = "hidden";
    persist = true;
  };

  # API token for the shared llama cluster, surfaced to hermes as
  # LLAMA_API_TOKEN (the custom_providers key_env above).
  # persist=true so the prompt value is stored once.
  clan.core.vars.generators.hermes-llama.prompts.llama-api-token = {
    description = "API token for the shared llama cluster (inference.p0.contact)";
    type = "hidden";
    persist = true;
  };

  # Bearer token for the API server. Generated, not prompted, and kept in a
  # separate file as well so it can be read back out for the phone:
  #   clan vars get coaxmetal hermes-api/api_key
  clan.core.vars.generators.hermes-api = {
    files."api_key" = { };
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssl
    ];
    script = ''
      openssl rand -hex 32 | tr -d '\n' > "$out/api_key"
    '';
  };

  # Hermes's radicale login (configs/radicale.nix). Shared with neoprism, where
  # radicale runs; a shared generator has to be declared identically on every
  # machine that uses it, hence the common definition.
  clan.core.vars.generators.radicale-hermes =
    import ../../configs/radicale-user-generator.nix pkgs "hermes"
    // {
      share = true;
    };

  # Claude subscription OAuth token for the anthropic provider: run
  # `claude setup-token` (long-lived, sk-ant-oat…) and paste it at the
  # prompt. persist=true so it is asked once.
  clan.core.vars.generators.hermes-anthropic.prompts.oauth-token = {
    description = "Claude subscription OAuth token from `claude setup-token` (sk-ant-oat…)";
    type = "hidden";
    persist = true;
  };

  # Home Assistant long-lived access token for the homeassistant plugin
  # (HA profile -> Security -> Long-lived access tokens). persist=true so the
  # prompt value is stored once.
  clan.core.vars.generators.hermes-homeassistant.prompts.token = {
    description = "Home Assistant long-lived access token for hermes";
    type = "hidden";
    persist = true;
  };

  # Assemble the .env Hermes reads from the generators above.
  clan.core.vars.generators.hermes-env = {
    dependencies = [
      "hermes-matrix"
      "hermes-llama"
      "hermes-api"
      "radicale-hermes"
      "hermes-anthropic"
      "hermes-mail"
      "hermes-homeassistant"
      "agentd"
    ];
    files."hermes.env" = { };
    # clan regenerates a var only when its validation changes, not when the
    # script does: without this a key added below never reaches the .env.
    validation.script = builtins.hashString "sha256" config.clan.core.vars.generators.hermes-env.script;
    runtimeInputs = [ pkgs.coreutils ];
    script = ''
      cat > "$out/hermes.env" <<EOF
      MATRIX_ACCESS_TOKEN=$(cat "$in"/hermes-matrix/matrix-access-token)
      LLAMA_API_TOKEN=$(cat "$in"/hermes-llama/llama-api-token)
      API_SERVER_KEY=$(cat "$in"/hermes-api/api_key)
      WEBHOOK_SECRET=$(cat "$in"/hermes-api/api_key)
      CALDAV_PASSWORD=$(cat "$in"/radicale-hermes/password)
      ANTHROPIC_TOKEN=$(cat "$in"/hermes-anthropic/oauth-token)
      EMAIL_PASSWORD=$(cat "$in"/hermes-mail/password)
      HASS_TOKEN=$(cat "$in"/hermes-homeassistant/token)
      AGENTD_TOKEN=$(cat "$in"/agentd/hermes-token)
      EOF
    '';
  };

  # The home without caches, toolchains and git clones; the SQLite databases
  # under .hermes are dumped consistently instead of copied.
  lass.backup.state.hermes =
    let
      home = config.services.hermes-agent.stateDir;
    in
    {
      folders = [ home ];
      exclude = [
        "${home}/.cache"
        "${home}/.cargo"
        "${home}/.gradle"
        "${home}/go"
        "${home}/.hermes/cache"
        "${home}/workspace"
        "${home}/.local/share/Trash"
        "${home}/*/node_modules"
        "${home}/*/target"
        "${home}/.hermes/*.db"
        "${home}/.hermes/*.db-wal"
        "${home}/.hermes/*.db-shm"
      ];
      preBackup = ''
        rm -rf /var/backup/hermes
        cd ${home}/.hermes
        ${pkgs.findutils}/bin/find . -path ./cache -prune -o -type f -name '*.db' -printf '%P\n' |
          while read -r db; do
            mkdir -p "/var/backup/hermes/$(dirname "$db")"
            ${pkgs.sqlite}/bin/sqlite3 -cmd ".timeout 60000" "$db" ".backup '/var/backup/hermes/$db'"
          done
      '';
      # WAL-mode SQLite readers need to write the -shm file
      readWritePaths = [ "${home}/.hermes" ];
    };
}
