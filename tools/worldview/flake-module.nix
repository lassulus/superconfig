{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      version = "0-unstable-2026-05-03";
      rev = "f325daad229bb15f6a1d1d3d1e9f76a744d2b2c4";
      src = pkgs.fetchFromGitHub {
        owner = "audibleblink";
        repo = "worldview";
        inherit rev;
        hash = "sha256-L18lWcK5gEEiLyYSETk3+7KacBjxpr4SwrolcWXu4sc=";
      };
    in
    {
      packages.worldview = pkgs.writeShellApplication {
        name = "worldview";
        passthru = {
          inherit version;
          updateScript = ./update.sh;
        };
        runtimeInputs = [
          pkgs.bun
          pkgs.ungoogled-chromium
          pkgs.python3
          pkgs.curl
          pkgs.gnused
        ];
        text = ''
          # Required env vars
          if [ -z "''${GOOGLE_MAPS_TILE_API_KEY:-}" ]; then
            echo "ERROR: GOOGLE_MAPS_TILE_API_KEY is not set" >&2
            echo "Get one at: https://console.cloud.google.com/google/maps-apis/credentials" >&2
            echo "Export it: export GOOGLE_MAPS_TILE_API_KEY=your_key_here" >&2
            exit 1
          fi

          get_free_port() {
            python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
          }

          FRONTEND_PORT=$(get_free_port)
          BACKEND_PORT=$(get_free_port)

          WORKDIR="''${XDG_DATA_HOME:-$HOME/.local/share}/worldview"
          mkdir -p "$WORKDIR"

          # Copy source if not yet present or if version changed
          MARKER="$WORKDIR/.version"
          CURRENT_REV="${rev}"
          if [ ! -f "$MARKER" ] || [ "$(cat "$MARKER")" != "$CURRENT_REV" ]; then
            echo "Setting up worldview source..."
            rm -rf "$WORKDIR/src"
            cp -r ${src} "$WORKDIR/src"
            chmod -R u+w "$WORKDIR/src"
            echo "$CURRENT_REV" > "$MARKER"
            rm -f "$WORKDIR/.installed"
          fi

          cd "$WORKDIR/src"

          # Install dependencies if needed
          if [ ! -f "$WORKDIR/.installed" ]; then
            echo "Installing dependencies..."
            bun install
            touch "$WORKDIR/.installed"
          fi

          # Patch hardcoded ports in source
          sed -i 's|const PORT = [0-9]*;|const PORT = '"$FRONTEND_PORT"';|' src/server.ts
          sed -i 's|http://localhost:[0-9]*"|http://localhost:'"$BACKEND_PORT"'"|g' src/config.ts

          cleanup() {
            echo "Shutting down..."
            # Kill entire process group to catch bun child processes
            kill -- -$$ 2>/dev/null || true
          }
          trap cleanup EXIT INT TERM

          export GOOGLE_MAPS_TILE_API_KEY
          export SERVER_PORT="$BACKEND_PORT"
          ''${AISSTREAM_API_KEY:+export AISSTREAM_API_KEY}

          # Start backend server
          bun run --hot src/server/index.ts &

          # Start frontend dev server
          bun run --hot src/server.ts &

          # Wait for frontend to be ready
          for _ in $(seq 1 30); do
            if curl -s "http://localhost:$FRONTEND_PORT" > /dev/null 2>&1; then
              break
            fi
            sleep 1
          done

          echo "WorldView is running at http://localhost:$FRONTEND_PORT"

          # Open in chromium app mode with a dedicated profile
          CHROME_DIR="$WORKDIR/chromium-profile"
          # Remove stale singleton locks from crashed sessions
          rm -f "$CHROME_DIR/SingletonLock" "$CHROME_DIR/SingletonCookie" "$CHROME_DIR/SingletonSocket"
          mkdir -p "$CHROME_DIR"
          chromium \
            --user-data-dir="$CHROME_DIR" \
            --no-first-run \
            --no-default-browser-check \
            --disable-gpu-compositing \
            --app="http://localhost:$FRONTEND_PORT" &
          CHROME_PID=$!

          # Wait for chromium to exit (closing the window kills the process)
          wait "$CHROME_PID" 2>/dev/null || true
        '';
      };
    };
}
