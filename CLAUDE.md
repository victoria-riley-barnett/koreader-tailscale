# tailscale.koplugin

KOReader plugin that installs and manages Tailscale VPN on e-readers (Kindle, Kobo, PocketBook).

## Architecture

- `main.lua` - Plugin entry point. Extends `WidgetContainer`. Registers menu items under Network. Manages the Tailscale lifecycle: install, start/stop, status, config, uninstall. Registers the Dispatcher action `toggle_tailscale_vpn` for gestures.
- `_meta.lua` - Plugin metadata (name, version, author).
- `bin/` - Shell scripts executed on device:
  - `install-tailscale.sh` - Downloads and extracts Tailscale binaries from pkgs.tailscale.com. Parses `TarballsVersion` from the stable JSON feed. Falls back to the pinned `TS_FALLBACK_VER`.
  - `start_tailscale.sh` - Stops old instances, starts `tailscaled`, runs `tailscale up`.
  - `stop_tailscale.sh` - Runs `tailscale down`, cleans up, kills the daemon.
  - `uninstall-tailscale.sh` - Stops Tailscale, removes binaries and state.

## Key patterns

- Lua owns the engineering decisions: TUN mode, state directory, auth key, headscale URL, flags. Shell receives them as `TS_*` environment variables.
- Shell scripts locate themselves with `BIN_DIR="${TS_BIN:-$(cd "$(dirname "$0")" && pwd)}"`. The caller overrides with `TS_BIN`.
- PocketBook uses `/mnt/ext1/tailscale` (external storage) instead of the plugin directory. The plugin directory is read-only there.
- The plugin shells out via `os.execute()` and `io.popen()`. No FFI, no async. The UI blocks during operations.
- Scripts are POSIX sh, not bash. Target devices run busybox.
- The Tailscale version is pinned in `install-tailscale.sh` (`TS_FALLBACK_VER`).

## Development notes

- `test.sh` runs static checks on the host. Run it with `sh test.sh`.
- `test/suite.sh` is an integration suite that runs on the device. `test/deploy.sh` pushes the plugin to a Kindle and runs the suite.
- There is no unit test framework on device. Test by deploying to a device.
- KOReader APIs used: `UIManager`, `InfoMessage`, `WidgetContainer`, `DataStorage`, `Dispatcher`, `logger`.
- The `.zip` files in the repo root are release artifacts. They are gitignored.
