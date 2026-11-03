#!/usr/bin/env bash
# The program cage runs on the kiosk stick: makes sure there is a network
# (a WiFi picker if there is none), then runs Firefox. When Firefox quits,
# it starts over, so closing Firefox is the way back to the WiFi picker.

has_network() {
  [[ $(nmcli --terse --fields STATE general) == connected* ]]
}

# Shows the WiFi networks in range, asks for the password of the chosen one
# and connects. Returns non-zero when nothing got connected; the caller just
# asks again (with a fresh scan).
pick_wifi() {
  local -A security_of=()
  local rows=() line signal rest security ssid text choice password log

  # SSID last and unescaped: colons inside it end up in $ssid
  while IFS= read -r line; do
    signal=${line%%:*}
    rest=${line#*:}
    security=${rest%%:*}
    ssid=${rest#*:}
    [[ -z $ssid || -n ${security_of[$ssid]+x} ]] && continue
    [[ $security == "--" ]] && security=""
    security_of[$ssid]=$security
    rows+=("$ssid" "$signal" "${security:-open}")
  done < <(
    nmcli --terse --escape no --fields SIGNAL,SECURITY,SSID device wifi list --rescan yes |
      sort --field-separator=: --key=1,1nr
  )

  text="No network connection. Choose a WiFi network:"
  ((${#rows[@]} == 0)) && text="No network connection and no WiFi networks found."
  choice=$(
    zenity --list --title="WiFi" --text="$text" \
      --column="Network" --column="Signal" --column="Security" \
      --ok-label="Connect" --cancel-label="Rescan" \
      --width=700 --height=500 \
      "${rows[@]}"
  ) || return 1
  [[ -n $choice && -n ${security_of[$choice]+x} ]] || return 1

  password=""
  if [[ -n ${security_of[$choice]} ]]; then
    password=$(
      zenity --entry --hide-text --title="WiFi" \
        --text="Password for \"$choice\":" --ok-label="Connect"
    ) || return 1
  fi

  # a profile left over from an earlier attempt would keep the old password
  nmcli connection delete id "$choice" >/dev/null 2>&1 || true
  local args=(device wifi connect "$choice")
  [[ -n $password ]] && args+=(password "$password")
  log=$(mktemp)
  # zenity closes when nmcli exits: the subshell writes nothing to the pipe
  (nmcli --wait 60 "${args[@]}" >"$log" 2>&1) |
    zenity --progress --pulsate --auto-close --no-cancel \
      --title="WiFi" --text="Connecting to \"$choice\"…" || true

  if ! has_network; then
    nmcli connection delete id "$choice" >/dev/null 2>&1 || true
    zenity --error --title="WiFi" \
      --text="Could not connect to \"$choice\":\n\n$(<"$log")"
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

while true; do
  # at boot NetworkManager needs a moment to bring up a cable connection
  if ! nm-online --quiet --timeout=10; then
    until has_network; do
      pick_wifi || true
    done
  fi
  firefox || true
done
