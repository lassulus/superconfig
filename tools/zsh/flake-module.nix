{ self, inputs, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      zshrc = ''
        autoload -U compinit && compinit

        # Setup custom interactive shell init stuff.
        # Bind gpg-agent to this TTY if gpg commands are used.
        export GPG_TTY=$(tty)

        # show how long a command takes
        ZSH_COMMAND_TIME_MIN_SECONDS=3
        ZSH_COMMAND_TIME_EXCLUDE=(vim)
        ZSH_COMMAND_TIME_MSG="took: %s sec"
        source ${
          pkgs.fetchFromGitHub {
            owner = "popstas";
            repo = "zsh-command-time";
            rev = "803d26eef526bff1494d1a584e46a6e08d25d918";
            hash = "sha256-ndHVFcz+XmUW0zwFq7pBXygdRKyPLjDZNmTelhd5bv8=";
          }
        }/command-time.plugin.zsh

        unsetopt nomatch # no matches found urls
        setopt autocd extendedglob
        bindkey -e

        #C-x C-e open line in editor
        autoload -z edit-command-line
        zle -N edit-command-line
        bindkey "^X^E" edit-command-line

        #fzf inclusion
        source ${pkgs.fzf}/share/fzf/completion.zsh
        source ${pkgs.fzf}/share/fzf/key-bindings.zsh

        # atuin distributed shell history
        if type -p atuin >/dev/null; then
          export ATUIN_CONFIG_DIR=${pkgs.writeTextDir "/config.toml" ''
            auto_sync = true
            update_check = false
            sync_address = "http://green.r:8888"
            sync_frequency = 0
            style = "compact"
          ''};
          export ATUIN_NOBIND="true" # disable all keybdinings of atuin
          eval "$(${self.packages.${pkgs.system}.atuin}/bin/atuin init zsh)" # TODO make this optional?
          bindkey '^r' _atuin_search_widget # bind ctrl+r to atuin
          # use zsh only session history
          fc -p
        fi

        #completion magic
        autoload -Uz compinit
        compinit
        zstyle ':completion:*' menu select

        #enable automatic rehashing of $PATH
        zstyle ':completion:*' rehash true

        # Lazy load completions for commands based on their installation path
        _lazy_completion_loader() {
          local cmd="$words[1]"
          local basename_cmd="$cmd"
          local cmd_path=""

          [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: _lazy_completion_loader called for: $cmd" >&2

          # Get command path and basename
          if [[ "$cmd" == /* ]] && [[ -x "$cmd" ]]; then
            cmd_path="$cmd"
            basename_cmd="$(basename "$cmd")"
          elif command -v "$cmd" >/dev/null 2>&1; then
            cmd_path="$(which "$cmd" 2>/dev/null)"
            basename_cmd="$(basename "$cmd_path")"
          fi

          [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: cmd_path=$cmd_path, basename_cmd=$basename_cmd" >&2

          # Find and load completion file
          local current="$cmd_path"
          while [[ -n "$current" ]]; do
            local share_dir="$(dirname "$current")/../share"
            for subdir in zsh/site-functions zsh/vendor-completions; do
              local dir="$share_dir/$subdir"
              if [[ -f "$dir/_$basename_cmd" ]]; then
                [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: found completion: $dir/_$basename_cmd" >&2
                [[ ! " ''${fpath[@]} " =~ " $dir " ]] && fpath=("$dir" $fpath)
                source "$dir/_$basename_cmd"
                [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: after sourcing, _comps[$basename_cmd]=''${_comps[$basename_cmd]:-not set}" >&2
                break 2
              fi
            done
            # Follow absolute symlinks only
            [[ -L "$current" ]] || break
            current="$(readlink "$current" 2>/dev/null)"
            [[ "$current" == /* ]] || break
          done

          # Register completion for the original command if needed
          if [[ -n "''${_comps[$basename_cmd]:-}" ]]; then
            if [[ "$cmd" != "$basename_cmd" ]]; then
              _comps[$cmd]="''${_comps[$basename_cmd]}"
              [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: registered ''${_comps[$basename_cmd]} for $cmd" >&2
            fi
          fi

          # Remove lazy loader only if it's still set
          if [[ "''${_comps[$cmd]:-}" == "_lazy_completion_loader" ]]; then
            compdef -d "$cmd" 2>/dev/null
          fi

          # Run the appropriate completion
          local comp="''${_comps[$cmd]:-}"
          [[ -z "$comp" ]] && comp="''${_comps[$basename_cmd]:-_normal}"
          [[ -n "$ZSH_COMP_DEBUG" ]] && echo "DEBUG: using completion: $comp" >&2
          $comp "$@"
        }

        # Set as default completer for commands without completions
        zstyle -e ':completion:*' completer '
          if [[ -z $_comps[$words[1]] ]]; then
            reply=(_lazy_completion_loader _complete)
          else
            reply=(_complete)
          fi
        '

        # fancy mv which interactively gets the second argument if not given
        function mv() {
          if [[ "$#" -ne 1 ]] || [[ ! -e "$1" ]]; then
            command mv -v "$@"
            return
          fi

          newfilename="$1"
          vared newfilename
          command mv -v -- "$1" "$newfilename"
        }

        #emacs bindings
        bindkey "[7~" beginning-of-line
        bindkey "[8~" end-of-line
        bindkey "Oc" emacs-forward-word
        bindkey "Od" emacs-backward-word

        # direnv integration
        eval "$(${pkgs.direnv}/bin/direnv hook zsh)"

        # Use nvim as MANPAGER if available and output is not piped
        if command -v nvim >/dev/null 2>&1; then
          export MANPAGER='sh -c "if [ -t 1 ]; then nvim +Man!; else cat; fi"'
        fi

        # This function is called whenever a command is not found.
        command_not_found_handler() {
          local p='${pkgs.nix-index}/etc/profile.d/command-not-found.sh'
          if [ -x "$p" ] && [ -f '/nix/var/nix/profiles/per-user/root/channels/nixos/programs.sqlite' ]; then
            # Run the helper program.
            "$p" "$@"

            # Retry the command if we just installed it.
            if [ $? = 126 ]; then
              "$@"
            else
              return 127
            fi
          else
            # Indicate than there was an error so ZSH falls back to its default handler
            echo "$1: command not found" >&2
            return 127
          fi
        }

        download_nixpkgs_cache_index () {
          filename="index-$(uname -m | sed 's/^arm64$/aarch64/')-$(uname | tr A-Z a-z)"
          mkdir -p ~/.cache/nix-index && cd ~/.cache/nix-index
          # -N will only download a new version if there is an update.
          , wget -q -N https://github.com/nix-community/nix-index-database/releases/latest/download/$filename
          ln -f $filename files
        }

        # Setup aliases.
        alias -- grep='grep --color=auto'
        alias -- ip='ip -color=auto'
        alias -- l='ls -alh'
        alias -- la='ls -la'
        alias -- ll='ls -l'
        alias -- ls='ls --color'
        alias -- ns='nix-shell --command zsh'
        alias -- nb='nix build --no-link --print-out-paths -L'
        alias -- ne='nix eval --json'
        alias -- nloc='nix-locate --top-level --whole-name'
        # a child process cannot change this shell's env, so eval its export line
        alias -- ssh-agent-pick='eval "$(${
          self.packages.${pkgs.system}.ssh-agent-pick
        }/bin/ssh-agent-pick)"'

        # Setup prompt.
        autoload -U promptinit
        promptinit

        p_error='%(?..%F{red}%?%f )'
        t_error='%(?..%? )'

        case $UID in
          0)
            p_username='%F{red}root%f'
            t_username='root'
            ;;
          1337)
            p_username=""
            t_username=""
            ;;
          *)
            p_username='%F{blue}%n%f'
            t_username='%n'
            ;;
        esac

        if test -n "$SSH_CLIENT"; then
          p_hostname='@%F{magenta}%M%f '
          t_hostname='@%M '
        else
          p_hostname=""
          t_hostname=""
        fi

        #check if in nix shell
        if test -n "$IN_NIX_SHELL"; then
          p_nixshell='%F{green}[s]%f '
          t_nixshell='[s] '
        else
          p_nixshell=""
          t_nixshell=""
        fi

        PROMPT="$p_error$p_username$p_hostname$p_nixshell%~ "
        TITLE="$t_error$t_username$t_hostname$t_nixshell%~"
        case $TERM in
          (*xterm* | *rxvt*)
            function precmd {
              PROMPT_EVALED=$(print -P "$TITLE")
              echo -ne "\033]0;$$ $PROMPT_EVALED\007"
            }
            # This seems broken for some reason
            # # This is seen while the shell waits for a command to complete.
            # function preexec {
            #   PROMPT_EVALED=$(print -P "$TITLE")
            #   echo -ne "\033]0;$$ $PROMPT_EVALED $1\007"
            # }
          ;;
        esac


        # Auto-start tmux for new sessions
        # Check if we're already in tmux (even through sudo)
        # Only run in interactive shells — non-interactive SSH commands must not exec tmux
        if [[ -o interactive && "$TERM" != "linux" && -z "$TMUX" && "$TERM" != "dumb" ]]; then
          # Check if we're inside tmux by looking for tmux in the process tree
          in_tmux=false
          pid=$$
          while [[ $pid -ne 1 ]]; do
            if ps -p $pid -o comm= 2>/dev/null | grep -q '^tmux'; then
              in_tmux=true
              break
            fi
            # Get parent PID
            pid=$(ps -p $pid -o ppid= 2>/dev/null | tr -d ' ') || break
          done

          if [[ "$in_tmux" == "false" ]]; then
            # Preserve SSH_AUTH_SOCK for tmux
            if [[ -n "$SSH_AUTH_SOCK" ]]; then
              tmux set-environment -g SSH_AUTH_SOCK "$SSH_AUTH_SOCK" 2>/dev/null
            fi

            # SSH session chooser: show existing sessions via fzf
            # Delete key kills the highlighted session, then refreshes the list
            if [[ -n "$SSH_CLIENT" ]]; then
              while true; do
                existing=$(tmux list-sessions -F '#{session_name}: #{session_windows} windows (created #{session_created_string})#{?session_attached, (attached),}' 2>/dev/null)
                [[ -z "$existing" ]] && break
                chosen=$(echo ">>> new session <<<\n$existing" \
                  | fzf --height=80% --reverse \
                        --header="Pick a tmux session (DEL to kill)" \
                        --expect=delete \
                        --preview='s={1}; s=''${s%:}; [ "$s" = ">>>" ] && echo "Create a new session" || tmux capture-pane -t "$s" -p -e 2>/dev/null' \
                        --preview-window=right:60%)
                key=$(echo "$chosen" | head -1)
                selection=$(echo "$chosen" | tail -1)
                chosen_name=$(echo "$selection" | cut -d: -f1)
                if [[ "$key" == "delete" && -n "$chosen_name" && "$chosen_name" != ">>> new session <<<" ]]; then
                  tmux kill-session -t "$chosen_name" 2>/dev/null
                  continue
                fi
                if [[ -n "$chosen_name" && "$chosen_name" != ">>> new session <<<" ]]; then
                  exec tmux -u attach -t "$chosen_name"
                fi
                break
              done
            fi

            # Generate a readable session name using name-generator
            session_name=$(${
              self.packages.${pkgs.system}.name-generator
            }/bin/name-generator 2>/dev/null || echo "session-$$")
            # Prefix with workspace name in graphical sessions
            if [[ -n "$WAYLAND_DISPLAY" ]]; then
              _ws_name=$(${
                self.packages.${pkgs.system}.workspace-manager
              }/bin/workspace-manager workspace 2>/dev/null)
              [[ -n "$_ws_name" ]] && session_name="''${_ws_name}-''${session_name}"
            fi
            # Start tmux with the generated session name
            exec tmux -u new-session -s "$session_name"
          fi
        fi

        # Set tmux status bar color based on hostname for SSH sessions
        if [[ -n "$TMUX" && "$__host__" != "$HOST" ]]; then
          # Generate a color based on hostname hash
          color=$(( $(echo -n "$HOST" | od -An -N4 -tu4) % 255 ))
          tmux set -g status-bg "colour$color" 2>/dev/null || true
          export __host__="$HOST"
        fi

        # Configure tmux for better mouse support
        if [[ -n "$TMUX" ]]; then
          # Enable mouse mode for scrolling
          tmux set -g mouse on 2>/dev/null || true
        fi

        # Workspace manager integration: cd to workspace directory on new terminal.
        # Only for shells that start in $HOME: a pane spawned with an explicit
        # directory (tmux split in cwd) must keep it.
        if [[ "$PWD" == "$HOME" ]]; then
          _ws_dir=$(${self.packages.${pkgs.system}.workspace-manager}/bin/workspace-manager dir 2>/dev/null)
          [[ -n "$_ws_dir" && -d "$_ws_dir" ]] && cd "$_ws_dir"
        fi

        # Disable some features to support TRAMP.
        if [ "$TERM" = dumb ]; then
            unsetopt zle prompt_cr prompt_subst
            unset RPS1 RPROMPT
            PS1='$ '
            PROMPT='$ '
        fi
      '';
    in
    {
      packages.zsh =
        (inputs.wrappers.lib.wrapPackage {
          pkgs = pkgs;
          package = pkgs.zsh;
          runtimeInputs = with pkgs; [
            gnugrep
            tmux
            fzf
            direnv
            self.packages.${pkgs.system}.atuin
            nix-index
            self.packages.${pkgs.system}.name-generator
          ];
          env = {
            ZDOTDIR = pkgs.writeTextDir "/.zshrc" zshrc;
          };
        }).overrideAttrs
          (old: {
            passthru = (old.passthru or { }) // {
              inherit zshrc;
            };
          });
    };
}
