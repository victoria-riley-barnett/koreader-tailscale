# Notes

Developer and contributor notes. User-facing docs are in [README.md](README.md).

## How It Works

The plugin installs Tailscale binaries into a `bin/` directory it manages. On most devices this is `tailscale.koplugin/bin/`. On PocketBook, binaries go to `/mnt/ext1/tailscale/bin/` because the plugin directory may be on a read-only filesystem.

All config files (`auth.key`, `headscale.url`) and logs (`tailscale.log`, `tailscaled.log`) live alongside the binaries.

### Userspace networking

The plugin always runs `tailscaled --tun=userspace-networking`. Kernel TUN on constrained e-reader kernels triggers `wgengine: watchdog timeout on Reconfig` — the WireGuard engine's `Reconfig` call times out when peer or route state changes. Userspace networking avoids that entirely. Outbound connections work via the SOCKS5/HTTP proxy listeners.

The device won't appear with a `tailscale0` interface and isn't directly addressable from the tailnet, but for the e-reader use case (outbound to a sync server, OPDS catalog, etc.) that doesn't matter.

### Loopback

Some firmware (Kobo, PocketBook) doesn't configure `lo` at boot. The start scripts detect whether `127.0.0.1` is present and bring up loopback using `ifconfig` (busybox-universal) with `ip` fallback. Required for the SOCKS5/HTTP proxy to bind.

### FAT32 / read-only filesystems

On devices where the binary directory doesn't support `chmod` (FAT32), the plugin uses `/tmp/tailscale/` as a tmpfs state directory and copies state back to persistent storage. Detected automatically via a temp-file chmod test.

## Scripts

All scripts are POSIX sh (no bash). Accept the tailscale directory as `$1` or `$TS_DIR`, defaulting to `/mnt/us/tailscale`.

- `install-tailscale.sh` — fetches latest stable version from pkgs.tailscale.com, falls back to pinned version
- `start_tailscale.sh` — start daemon + connect (standard Tailscale)
- `start_tailscale_headscale.sh` — start with `--login-server` for self-hosted Headscale
- `stop_tailscale.sh` — disconnect and stop daemon
- `uninstall-tailscale.sh` — stop and remove all Tailscale files

## Manual Installation

If `Install/Update Tailscale` fails (no WiFi, slow connection):

```sh
# On your computer
wget https://pkgs.tailscale.com/stable/tailscale_1.96.2_arm.tgz

# Transfer to device, then on-device
cd /<path-to-plugin>/tailscale.koplugin/bin
tar xzf tailscale_1.96.2_arm.tgz
mv tailscale_*/tailscale tailscale_*/tailscaled ./
rm -rf tailscale_*
chmod +x tailscale tailscaled
```

Then create `auth.key` and start from the plugin menu.

## Releasing

Push a `vX.Y.Z` tag. The GitHub Actions workflow in `.github/workflows/release.yml` verifies the tag matches `_meta.lua`, builds the zip, and publishes a GitHub release. The tag, plugin version, and release artifact are always in sync by construction.
