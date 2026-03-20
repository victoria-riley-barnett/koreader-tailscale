# Tailscale Plugin for KOReader
Tailscale VPN plugin for KOReader. Run Tailscale on your e-reader for remote access and file sync.

Tested on Kindle PW5/PW6, Kobo, and PocketBook Verse Pro. Should work on any KOReader device with ARMv7 or ARM64. The plugin auto-detects your device, architecture, and paths at runtime.

## Features
- Access your e-reader from anywhere via Tailscale VPN
- Pair with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) for file sync across networks
- HTTP CONNECT + SOCKS5 proxy for devices without TUN support, so KOReader can reach OPDS and other services through Tailscale

## Prerequisites
1. **Tailscale Account**: Sign up at [tailscale.com](https://tailscale.com).
2. **Auth Key**: Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
3. **E-reader with KOReader** installed.

## Installation

1. Copy the `tailscale.koplugin` folder to your KOReader plugins directory (wherever KOReader stores its plugins on your device).
2. Restart KOReader.
3. Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

The installer downloads ~25-57 MB depending on architecture. If WiFi is slow, see Manual Installation below.

Common KOReader plugin paths:
- **Kindle**: `/mnt/us/koreader/plugins/`
- **Kobo**: `/mnt/onboard/.adds/koreader/plugins/`
- **PocketBook**: `/mnt/ext1/koreader/plugins/`

## Setup

1. **Create an auth key** at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys). Copy the key (starts with `tskey-`).

2. **Save the key** as `auth.key` in the plugin's `bin/` directory:
   ```sh
   # Example for Kindle (adjust path for your device)
   scp auth.key root@<device-ip>:/<koreader-plugins>/tailscale.koplugin/bin/auth.key
   ```

3. **(Optional) Headscale**: If you use a self-hosted Headscale server, create a `headscale.url` file containing the full URL (e.g. `https://headscale.example.com`) in the same `bin/` directory. The plugin menu also shows the currently configured URL under *Headscale URL info*.

4. **Start Tailscale**: Menu → Network → Tailscale VPN → Toggle "On". Check status via Status menu item.

## How It Works

The plugin installs Tailscale binaries into a `bin/` directory that it manages. On most devices this is `tailscale.koplugin/bin/` inside the plugin itself. On PocketBook, binaries go to `/mnt/ext1/tailscale/bin/` because the plugin directory may be on a read-only filesystem.

All configuration files (`auth.key`, `headscale.url`) and logs (`tailscale.log`, `tailscaled.log`) live in the same directory as the binaries.

### TUN and Userspace Networking

If the device has `/dev/net/tun`, Tailscale uses it normally. If not (common on PocketBook, some Kindles), the plugin falls back to **userspace networking** automatically — no configuration needed.

In userspace mode, apps can't reach Tailscale peers through normal TCP connections. The plugin exposes HTTP CONNECT and SOCKS5 proxies on `127.0.0.1:1055` so KOReader can still reach tailnet services. Enable the proxy in KOReader via **Menu → Network → Tailscale VPN → Settings/Config → Proxy for userspace mode**.

> **PocketBook note**: PocketBook firmware doesn't configure the loopback interface at boot. The start script handles this automatically.

### FAT32 and Read-Only Filesystems

On devices where the binary directory doesn't support `chmod` (FAT32), the plugin uses a tmpfs state directory at `/tmp/tailscale/` for runtime state and copies it back to persistent storage. This is handled automatically.

## Plugin Menu Commands
- **Tailscale VPN**: Toggle connection.
- **Status**: Show device IP and info.
- **Start/Stop Daemon**: Control the daemon independently.
- **Install/Update Tailscale**: Download and install binaries.
- **Settings / Config**: Auth key, Headscale URL, proxy toggle, uninstall.

## Usage with Syncthing
1. Note your device's Tailscale IP from the status menu.
2. Install Tailscale and Syncthing on other devices.
3. Configure Syncthing to use the Tailscale IP:
   ```
   tcp://<tailscale-ip or magic dns>:22000
   ```

## Scripts

The `bin/` directory contains shell scripts that the plugin calls. You can also run them manually over SSH:

- `start_tailscale.sh` — start daemon + connect (standard Tailscale)
- `start_tailscale_headscale.sh` — start with `--login-server` for self-hosted Headscale
- `stop_tailscale.sh` — disconnect and stop daemon
- `install-tailscale.sh` — download and install binaries (fetches latest version, falls back to pinned version)
- `uninstall-tailscale.sh` — stop and remove all Tailscale files

Scripts accept the tailscale directory as `$1` or via `$TS_DIR` env var, defaulting to `/mnt/us/tailscale`. All scripts are POSIX sh (no bash required).

## Uninstall / Reinstall
1. **Uninstall**: Menu → Plugins → Tailscale VPN → Settings → Uninstall Tailscale.
2. **Reinstall**: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

Back up your `auth.key` before uninstalling if you want to keep it.

## Manual Installation

If automatic installation fails:

1. Download on your computer:
   ```bash
   wget https://pkgs.tailscale.com/stable/tailscale_1.96.2_arm.tgz
   ```

2. Transfer and extract on device:
   ```bash
   cd /<path-to-plugin>/tailscale.koplugin/bin
   tar xzf tailscale_1.96.2_arm.tgz
   mv tailscale_*/tailscale tailscale_*/tailscaled ./
   rm -rf tailscale_*
   chmod +x tailscale tailscaled
   ```

3. Create `auth.key` with your Tailscale auth key, then start from the plugin menu.

## Troubleshooting

Check logs in the plugin's `bin/` directory: `tailscaled.log` (daemon) and `tailscale.log` (client).

If installation fails due to space, ensure at least 100MB free on the partition containing KOReader (`df -h`).

## Security
- End-to-end encrypted via WireGuard (Tailscale's transport)
- Device only reachable from your tailnet
- Auth keys stored locally on device
- No inbound ports opened

## Credits
Based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), adapted for KOReader. Runs alongside [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

## License
MIT License - See included LICENSE file.
