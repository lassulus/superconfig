# Home Assistant side of ./tv.nix: a "TV" dashboard to switch the TV,
# remote-control Kodi on styx (until the Bluetooth remote is there), search
# Kodi's library to play something on the TV (Kodi Search Card with the Kodi
# Media Sensors integration) and request new movies and shows from Seerr on
# flix (Seerr Request Card on HA's Seerr integration). Mounted into the
# container as a package and a YAML dashboard like ./internet-hass.nix.
# Set up in Home Assistant, not here:
# - from HACS like the other cards: Kodi Media Sensors and Kodi Search Card
#   (jtbgroup), Seerr Request Card (custom repository
#   willmakenoise/ha_seerr_card), auto-entities
# - the integrations, which can only be set up in the UI:
#   - Kodi: host 10.42.0.3, port 8082, user kodi, password from the kodi
#     vars generator on styx; its media player was renamed to
#     media_player.kodi_living_room, which everything below uses
#   - Kodi Media Sensors: label "Living room TV", that media player; gives
#     sensor.kodi_living_room_tv for the search card
#   - Seerr: http://yellow.r:5055 with Seerr's API key (main.apiKey in its
#     settings.json), so requests are filed as the admin and auto-approved;
#     it takes Seerr's only webhook slot for its push updates
{
  lib,
  pkgs,
  ...
}:
let
  kodi = "media_player.kodi_living_room";
  json = name: value: pkgs.writeText name (builtins.toJSON value);
  seerrEntry = "01M6GQGWG1M3Q1R6AJ0SRBE2XC";
  # Player.GetItem properties of the history's own lookups, also how its
  # answers are told apart
  historyItemProperties = [
    "title"
    "showtitle"
    "season"
    "episode"
  ];

  package = {
    # Kodi's sound goes to the speakers through the audio hub, not the TV, so
    # switching only the TV off would keep a film playing
    script.tv_off = {
      alias = "TV off";
      icon = "mdi:television-off";
      sequence = [
        {
          action = "media_player.media_stop";
          target.entity_id = kodi;
          continue_on_error = true;
        }
        {
          action = "switch.turn_off";
          target.entity_id = "switch.tv";
        }
      ];
    };
    # play a pasted video link (YouTube and anything else yt-dlp knows)
    # through tv-play on styx (./tv-play.py); its error text ends up in a
    # notification when it can't
    rest_command.tv_play = {
      url = "http://10.42.0.3:8083/play";
      method = "post";
      content_type = "application/json";
      payload = "{{ {'url': url} | to_json }}";
      # yt-dlp takes a few seconds
      timeout = 90;
    };
    script.tv_play_url = {
      alias = "Play a video link on the TV";
      icon = "mdi:play-box";
      fields.url.description = "Link to the video";
      sequence = [
        {
          action = "rest_command.tv_play";
          data.url = "{{ url }}";
          response_variable = "result";
          continue_on_error = true;
        }
        {
          "if" = [
            {
              condition = "template";
              value_template = "{{ result is defined and result.status == 200 }}";
            }
          ];
          # tv-play answers with the title; for the history below
          "then" = [
            {
              event = "tv_link_played";
              event_data = {
                title = "{{ result.content }}";
                url = "{{ url }}";
              };
            }
          ];
          "else" = [
            {
              action = "persistent_notification.create";
              data = {
                title = "TV: can't play the link";
                message = "{{ url }}: {{ result.content if result is defined else 'tv-play on styx is not reachable' }}";
              };
            }
          ];
        }
      ];
    };
    # an entry of sensor.tv_history: a link again, a movie or episode from
    # the library where it was stopped
    script.tv_replay = {
      alias = "Play something from the TV history again";
      icon = "mdi:history";
      fields = {
        kind.description = "link, movie or episode";
        id.description = "Kodi library id (movie, episode)";
        url.description = "Link (link)";
      };
      sequence = [
        {
          "if" = [
            {
              condition = "template";
              value_template = "{{ kind == 'link' }}";
            }
          ];
          "then" = [
            {
              action = "script.tv_play_url";
              data.url = "{{ url }}";
            }
          ];
          "else" = [
            {
              action = "kodi.call_method";
              target.entity_id = kodi;
              data = {
                method = "Player.Open";
                item = "{{ {kind ~ 'id': id | int} }}";
                options.resume = true;
              };
            }
          ];
        }
      ];
    };
    input_text.tv_link = {
      name = "Video link (YouTube, ...)";
      icon = "mdi:play-box";
      max = 255;
    };
    # entering a link plays it, the field is cleared for the next one
    automation = [
      {
        id = "tv_play_link";
        alias = "TV: play a video link";
        triggers = [
          {
            trigger = "state";
            entity_id = "input_text.tv_link";
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = "{{ trigger.to_state.state | trim != '' }}";
          }
        ];
        actions = [
          {
            action = "input_text.set_value";
            target.entity_id = "input_text.tv_link";
            data.value = "";
          }
          {
            action = "script.tv_play_url";
            data.url = "{{ trigger.to_state.state | trim }}";
          }
        ];
      }
      # when Kodi starts a movie or episode, ask it for the item's library id
      # and titles (HA's media_content_id is Kodi's uniqueid, e.g. the IMDb
      # id); the answer is a kodi_call_method_result event for the history
      {
        id = "tv_history_item";
        alias = "TV: note a movie or episode for the history";
        triggers = [
          {
            trigger = "state";
            entity_id = kodi;
          }
        ];
        conditions = [
          {
            condition = "template";
            value_template = "{{ trigger.to_state is not none and trigger.to_state.state == 'playing' and trigger.to_state.attributes.media_content_type in ['movie', 'tvshow'] and (trigger.from_state is none or trigger.from_state.attributes.media_content_id != trigger.to_state.attributes.media_content_id) }}";
          }
        ];
        actions = [
          {
            action = "kodi.call_method";
            target.entity_id = kodi;
            data = {
              method = "Player.GetItem";
              playerid = 1;
              properties = historyItemProperties;
            };
          }
        ];
      }
    ];
    # what the TV played, newest first, at most 12: links (from tv_play_url)
    # and movies and episodes from the library (however Kodi started them);
    # restored after restarts like every trigger-based template
    template = [
      {
        triggers = [
          {
            trigger = "event";
            event_type = "tv_link_played";
          }
          {
            trigger = "event";
            event_type = "kodi_call_method_result";
            event_data.entity_id = kodi;
          }
        ];
        # only the answers to tv_history_item (kodi_media_sensors asks
        # Player.GetItem too, without these properties)
        conditions = [
          {
            condition = "template";
            value_template = "{% set d = trigger.event.data %}{{ trigger.event.event_type == 'tv_link_played' or (d.result_ok and d.input.method == 'Player.GetItem' and d.input.params.properties == ${builtins.toJSON historyItemProperties} and d.result.item.type in ['movie', 'episode']) }}";
          }
        ];
        sensor = [
          {
            name = "TV history";
            unique_id = "tv_history";
            icon = "mdi:history";
            # when something was last added
            device_class = "timestamp";
            state = "{{ now().isoformat() }}";
            attributes.videos = lib.concatStrings [
              "{% set d = trigger.event.data %}"
              "{% if trigger.event.event_type == 'tv_link_played' %}"
              "{% set new = {'kind': 'link', 'title': d.title, 'url': d.url} %}"
              "{% else %}{% set i = d.result.item %}"
              "{% if i.type == 'movie' %}"
              "{% set new = {'kind': 'movie', 'id': i.id, 'title': i.title or i.label} %}"
              "{% else %}"
              "{% set new = {'kind': 'episode', 'id': i.id, 'title': i.showtitle ~ ' S%02dE%02d ' | format(i.season | int(0), i.episode | int(0)) ~ (i.title or i.label)} %}"
              "{% endif %}{% endif %}"
              "{% set old = this.attributes.videos | default([]) | rejectattr('title', 'eq', new.title) | list %}"
              "{{ ([new] + old)[:12] }}"
            ];
          }
        ];
      }
    ];
    lovelace.dashboards.tv-gg23 = {
      mode = "yaml";
      title = "TV";
      icon = "mdi:television";
      show_in_sidebar = true;
      filename = "dashboards/tv.yaml";
    };
  };

  # remote button calling a Kodi JSON-RPC method (`data` holds its params)
  key = name: icon: data: {
    type = "button";
    inherit name icon;
    show_name = false;
    icon_height = "48px";
    grid_options.columns = 4;
    tap_action = {
      action = "perform-action";
      perform_action = "kodi.call_method";
      target.entity_id = kodi;
      inherit data;
    };
    hold_action.action = "none";
  };
  # a Kodi action (keymap action name), labelled since icons are ambiguous
  kodiAction =
    name: icon: action:
    key name icon {
      method = "Input.ExecuteAction";
      inherit action;
    }
    // {
      show_name = true;
      icon_height = "32px";
    };
  # jump `seconds` back or forward in the playing video (player 1)
  seek =
    name: icon: seconds:
    key name icon {
      method = "Player.Seek";
      playerid = 1;
      value = { inherit seconds; };
    }
    // {
      show_name = true;
      icon_height = "32px";
      grid_options.columns = 3;
    };

  dashboard = {
    title = "TV";
    views = [
      {
        title = "TV";
        path = "tv";
        icon = "mdi:television";
        type = "sections";
        max_columns = 2;
        sections = [
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "TV";
                icon = "mdi:television";
              }
              {
                type = "button";
                entity = "switch.tv";
                name = "TV on";
                icon = "mdi:television";
                show_state = true;
                grid_options.columns = 6;
                tap_action = {
                  action = "perform-action";
                  perform_action = "switch.turn_on";
                  target.entity_id = "switch.tv";
                };
                hold_action.action = "none";
              }
              {
                type = "button";
                entity = "script.tv_off";
                name = "TV off";
                icon = "mdi:television-off";
                grid_options.columns = 6;
                tap_action = {
                  action = "perform-action";
                  perform_action = "script.tv_off";
                };
                hold_action.action = "none";
              }
              {
                type = "media-control";
                entity = kodi;
                grid_options.columns = "full";
              }
              {
                type = "heading";
                heading = "Speakers";
                icon = "mdi:speaker-multiple";
                heading_style = "subtitle";
              }
              # the TV row of the Audio dashboard (./audio/hub.nix): per room
              # its route switch, crossed out when off, and its volume slider
              # (number.audio_volume_<room>, from the switch's id)
              {
                type = "custom:auto-entities";
                grid_options.columns = "full";
                card = {
                  type = "grid";
                  columns = 3;
                  square = false;
                };
                card_param = "cards";
                show_empty = false;
                filter.template = ''{% set ns = namespace(out=[]) %}{% for e in states.switch | selectattr('entity_id', 'search', '^switch\\.audio_route_tv_') | sort(attribute='attributes.speaker') %}{% set room = e.entity_id[${toString (builtins.stringLength "switch.audio_route_tv_")}:] %}{% set ns.out = ns.out + [{"type": "vertical-stack", "cards": [{"type": "button", "entity": e.entity_id, "name": e.attributes.speaker, "icon": ("mdi:speaker" if e.state == "on" else "mdi:speaker-off"), "icon_height": "40px", "tap_action": {"action": "toggle"}, "hold_action": {"action": "none"}}, {"type": "tile", "entity": "number.audio_volume_" ~ room, "name": "Volume", "icon": "mdi:volume-high", "features": [{"type": "numeric-input", "style": "slider"}]}]}] %}{% endfor %}{{ ns.out }}'';
              }
            ];
          }
          {
            type = "grid";
            cards = [
              {
                type = "heading";
                heading = "Remote";
                icon = "mdi:remote";
              }
              (key "Back" "mdi:arrow-u-left-top" { method = "Input.Back"; })
              (key "Up" "mdi:chevron-up" { method = "Input.Up"; })
              (key "Menu" "mdi:menu" { method = "Input.ContextMenu"; })
              (key "Left" "mdi:chevron-left" { method = "Input.Left"; })
              (key "OK" "mdi:circle-outline" { method = "Input.Select"; })
              (key "Right" "mdi:chevron-right" { method = "Input.Right"; })
              (key "Home" "mdi:home" { method = "Input.Home"; })
              (key "Down" "mdi:chevron-down" { method = "Input.Down"; })
              (key "Info" "mdi:information-outline" { method = "Input.Info"; })
              (seek "-10 min" "mdi:rewind-10" (-600))
              (seek "-30 s" "mdi:rewind-30" (-30))
              (seek "+30 s" "mdi:fast-forward-30" 30)
              (seek "+10 min" "mdi:fast-forward-10" 600)
              (kodiAction "Subtitles on/off" "mdi:subtitles-outline" "showsubtitles")
              (kodiAction "Next subtitle" "mdi:subtitles" "nextsubtitle")
              (kodiAction "Next audio track" "mdi:translate" "audionextlanguage")
            ];
          }
          {
            type = "grid";
            column_span = 2;
            cards = [
              {
                type = "entities";
                title = "Play a link";
                entities = [ "input_text.tv_link" ];
                grid_options.columns = "full";
              }
              # sensor.tv_history as rows; Play starts the entry again
              {
                type = "custom:auto-entities";
                grid_options.columns = "full";
                card = {
                  type = "entities";
                  title = "History";
                };
                card_param = "entities";
                show_empty = false;
                filter.template = ''{% set icons = {"link": "mdi:play-box", "movie": "mdi:movie-open", "episode": "mdi:television-classic"} %}{% set ns = namespace(out=[]) %}{% for v in state_attr('sensor.tv_history', 'videos') or [] %}{% set ns.out = ns.out + [{"type": "button", "name": v.title, "icon": icons[v.kind], "action_name": "Play", "tap_action": {"action": "perform-action", "perform_action": "script.tv_replay", "data": {"kind": v.kind, "id": v.id | default(0), "url": v.url | default("")}}}] %}{% endfor %}{{ ns.out }}'';
              }
              {
                type = "custom:kodi-search-card";
                entity = "sensor.kodi_living_room_tv";
                title = "Search";
                grid_options.columns = "full";
                # tapping plays on the TV; no music, the library has none
                show_action_mode = false;
                action_mode = "play";
                show_recently_played = false;
                show_current_artist = false;
                show_music_playlist = false;
                media_type_order = [
                  "movie"
                  "tvshow"
                  "episode"
                ];
              }
              {
                type = "custom:seerr-request-card";
                config_entry_id = seerrEntry;
                name = "Request something new";
                # its default is a fixed 4 rows with the results scrolling
                # inside; grow with the results instead
                grid_options = {
                  columns = "full";
                  rows = "auto";
                };
              }
            ];
          }
        ];
      }
    ];
  };
in
{
  virtualisation.oci-containers.containers.homeassistant.volumes = [
    "${json "tv.yaml" package}:/config/packages/tv.yaml:ro"
    "${json "tv-dashboard.yaml" dashboard}:/config/dashboards/tv.yaml:ro"
  ];
}
