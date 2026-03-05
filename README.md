# Tailscale Plugin for KOReader
Secure cross-network remote access and file synchronization for your e-reader using Tailscale VPN.

## Supported Devices
| Device | Storage Path | Architecture |
|--------|-------------|-------------|
| Kindle (PW5, PW6, etc.) | `/mnt/us/tailscale/` | ARM 32-bit |
| PocketBook (Verse Pro, etc.) | `/mnt/ext1/tailscale/` | ARM 64-bit |

The plugin **auto-detects** your device and uses the correct paths and binary architecture automatically.

## Features
- **Secure Remote Access**: Access your e-reader from anywhere via Tailscale VPN.
- **Cross-network File Synchronization**: Use KOreader [Syncthing](https://github.com/jasonchoimtt/koreader-syncthing) for file transfers **without being on the same network**.

## Prerequisites
1. **Tailscale Account**: Sign up at [tailscale.com](https://tailscale.com).
2. **Auth Key**: Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
3. **E-reader with file and/or ssh access**: With KOReader installed. Tested on Kindle PW6, PW5, and PocketBook Verse Pro.

## Installation

### Kindle
1. Copy `tailscale.koplugin` to `/mnt/us/koreader/plugins/`.

### PocketBook
1. Copy `tailscale.koplugin` to the KOReader plugins directory (usually `/mnt/ext1/applications/koreader/plugins/` or wherever KOReader stores its plugins on your device).

### All Devices
2. Restart KOReader.
3. In KOReader: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

**Note**: Installation downloads ~25–57 MB (depending on architecture) and may take 5–10 minutes on slow Wi-Fi. You can pre-download binaries and transfer via SCP/SSH to speed up.

## Setup
1. **Get Auth Key**:
   - Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
   - Copy the key (starts with `tskey-`).
   - Save the key as auth.key

2. **Configure Auth Key**:
   - Copy the auth.key file to your device's tailscale bin directory:
     ```sh
     # Kindle
     scp -P 2222 auth.key user@device-ip:/mnt/us/tailscale/bin/auth.key
     # PocketBook
     scp -P 2222 auth.key user@device-ip:/mnt/ext1/tailscale/bin/auth.key
     ```

3. **(Optional) Use a self-hosted Headscale server**:
   - If you run Headscale and want your device to use it instead of tailscale.com, create a `headscale.url` file containing the full Headscale URL (for example: `https://headscale.example.com`).
   - Place it in the tailscale bin directory (e.g. `/mnt/us/tailscale/bin/headscale.url` on Kindle, `/mnt/ext1/tailscale/bin/headscale.url` on PocketBook).

4. **Start Tailscale**:
   - In KOReader: Menu → Network → Tailscale VPN → Toggle "On".
   - Check status via Menu → Network → Tailscale VPN → Status.

### Scripts

- `bin/start_tailscale.sh`: Standard start script. Includes the current device hostname (if present) and uses an `auth.key` when available. Use this for normal Tailscale operation.
- `bin/start_tailscale_headscale.sh`: Explicit Headscale start script. Reads a Headscale URL from the device's `headscale.url` file and passes it to `tailscale up` via `--login-server`. Run this when you manage devices via a self-hosted Headscale server.

To make the scripts executable on the device:
```sh
cd /mnt/us/tailscale/bin
chmod +x start_tailscale.sh start_tailscale_headscale.sh
```

If you prefer automated behavior, use `start_tailscale.sh`. If you manage devices with Headscale, run `start_tailscale_headscale.sh` explicitly so the script only applies the `--login-server` flag when you opt in.

## Usage with Syncthing
1. Note your device's Tailscale IP from the status menu.
2. Install Tailscale and Syncthing on other devices.
3. Configure Syncthing to use the Tailscale IP by adding the address:
   ```
   tcp://<tailscale-ip or magic dns>:22000
   ```
4. Enjoy secure, remote file synchronization without having to be on the same network.

## Plugin Menu Commands
- **Tailscale VPN**: Toggle connection.
- **Status**: Show device IP and info.
- **Install/Update Tailscale**: Download and install binaries.
- **Uninstall Tailscale**: Stop and remove Tailscale files (removes auth key).

## Files Location

| File | Kindle | PocketBook |
|------|--------|------------|
| Binaries | `/mnt/us/tailscale/bin/` | `/mnt/ext1/tailscale/bin/` |
| Logs | `/mnt/us/tailscale/bin/tailscale.log` | `/mnt/ext1/tailscale/bin/tailscale.log` |
| Auth Key | `/mnt/us/tailscale/bin/auth.key` | `/mnt/ext1/tailscale/bin/auth.key` |

## Uninstall / Reinstall
1. **Uninstall**: Menu → Plugins → Tailscale VPN → Uninstall Tailscale.
2. **Reinstall**: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

You may want to backup `/mnt/us/tailscale/bin/auth.key` by moving it to `/mnt/us/tailscale/bin/auth.key.backup` or similar before uninstalling, and restore its name after reinstalling.

## Troubleshooting
- **Logs** (paths depend on device):
  - Kindle: `/mnt/us/tailscale/bin/tailscaled.log` and `tailscale.log`
  - PocketBook: `/mnt/ext1/tailscale/bin/tailscaled.log` and `tailscale.log`

## Security Notes
- Tailscale uses end-to-end encryption.
- Your e-reader is only accessible to devices in your Tailscale network.
- Auth keys are stored locally on the device.
- No inbound internet ports are opened.

## Credits
Some parts based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), though expanded and adapted for KOReader, with in place installation + instructions, and can run side by side with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

## License
MIT License - See included LICENSE file.
