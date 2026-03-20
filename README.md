# Tailscale Plugin for KOReader
Tailscale VPN plugin for KOReader. Run Tailscale on your e-reader for remote access and file sync.

## Supported Devices
| Device | Storage Path | Architecture |
|--------|-------------|-------------|
| Kindle (PW5, PW6, etc.) | `/mnt/us/tailscale/` | ARM 32-bit |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/` | ARM 32-bit |
| PocketBook (Verse Pro, etc.) | `/mnt/ext1/tailscale/` | ARM 32-bit |

> **Note:** The PocketBook Verse Pro has a 64-bit CPU (Cortex-A53) but runs a **32-bit userspace**. The plugin detects the actual architecture at runtime via `uname -m` and downloads the matching binary.

The plugin auto-detects your device and uses the correct paths and binary architecture.

## Features
- Access your e-reader from anywhere via Tailscale VPN
- Pair with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) for file sync across networks
- HTTP CONNECT proxy for devices without TUN support (PocketBook), so KOReader can reach OPDS and other services through Tailscale

## Prerequisites
1. **Tailscale Account**: Sign up at [tailscale.com](https://tailscale.com).
2. **Auth Key**: Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
3. **E-reader with KOReader**: Tested on Kindle PW5/PW6, Kobo, and PocketBook Verse Pro. Should work on any device with ARMv7 or ARM64.

## Installation

1. Copy `tailscale.koplugin` to your KOReader plugins directory:
   - **Kindle**: `/mnt/us/koreader/plugins/`
   - **Kobo**: `/mnt/onboard/.adds/koreader/plugins/`
   - **PocketBook**: `/mnt/ext1/koreader/plugins/`
2. Restart KOReader.
3. In KOReader: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

**Note**: Installation downloads ~25-57 MB depending on architecture. If WiFi is slow, pre-download and SCP the binaries (see Manual Installation below).

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
      # Kobo
      scp auth.key user@device-ip:/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key
      # PocketBook
      scp -P 2222 auth.key user@device-ip:/mnt/ext1/tailscale/bin/auth.key
      ```

3. **(Optional) Use a self-hosted Headscale server**:
    - Create a `headscale.url` file containing the full Headscale URL (e.g. `https://headscale.example.com`).
    - Place it in the tailscale bin directory (e.g. `/mnt/us/tailscale/bin/headscale.url` on Kindle, `/mnt/ext1/tailscale/bin/headscale.url` on PocketBook).
    - The plugin exposes a menu item *Set Headscale URL* which shows the currently configured URL.

4. **Start Tailscale**:
   - In KOReader: Menu → Network → Tailscale VPN → Toggle "On".
   - Check status via Menu → Network → Tailscale VPN → Status.

### Scripts

- `bin/start_tailscale.sh`: Standard start script. Includes the current device hostname (if present) and uses an `auth.key` when available. Use this for normal Tailscale operation.
- `bin/start_tailscale_headscale.sh`: Headscale start script. Reads a Headscale URL from `headscale.url` and passes it to `tailscale up` via `--login-server`.

To make the scripts executable on the device:
```sh
cd /mnt/us/tailscale/bin
chmod +x start_tailscale.sh start_tailscale_headscale.sh

# PocketBook
cd /mnt/ext1/koreader/plugins/tailscale.koplugin/bin
chmod +x start_tailscale.sh start_tailscale_headscale.sh
```

If you prefer automated behavior, use `start_tailscale.sh`. If you manage devices with Headscale, run `start_tailscale_headscale.sh` explicitly so the script only applies the `--login-server` flag when you opt in.

## Installation Location

Tailscale binaries are installed in the plugin's `bin/` directory for Kindle and Kobo devices. For PocketBook devices, binaries are installed in external storage (`/mnt/ext1/tailscale/bin`) to avoid read-only filesystem limitations.

### Troubleshooting Space Issues

If installation fails due to insufficient space:

1. **Check available space** on the partition containing KOReader:
   ```bash
   df -h /mnt/us /mnt/onboard /mnt
   ```

2. Ensure at least 100MB free space is available.

3. If space is limited, consider moving KOReader to a different partition or using manual installation (see Manual Installation section).

## Usage with Syncthing
1. Note your device's Tailscale IP from the status menu.
2. Install Tailscale and Syncthing on other devices.
3. Configure Syncthing to use the Tailscale IP by adding the address:
   ```
   tcp://<tailscale-ip or magic dns>:22000
   ```
4. Files sync across networks.

## Plugin Menu Commands
- **Tailscale VPN**: Toggle connection.
- **Status**: Show device IP and info.
- **Install/Update Tailscale**: Download and install binaries.
- **Uninstall Tailscale**: Stop and remove Tailscale files (removes auth key).
- **Proxy for userspace mode** *(Settings/Config submenu)*: Enable/disable the HTTP CONNECT proxy at `127.0.0.1:1055`.

## HTTP Proxy for Userspace Mode

### Why it exists

The PocketBook Verse Pro does not have the Linux TUN kernel module, so Tailscale cannot create a virtual network interface. Instead it runs in **userspace networking mode**: WireGuard runs entirely in the `tailscaled` process and no routes are added to the kernel's routing table.

This means apps on the device (KOReader included) cannot reach Tailscale peers through normal TCP connections — there is no `/dev/net/tun` interface to route through.

To work around this, the plugin starts `tailscaled` with `--outbound-http-proxy-listen=127.0.0.1:1055` and `--socks5-server=localhost:1055`, which expose HTTP CONNECT and SOCKS5 proxies on the loopback interface. Any client configured to use these proxies will have its connections tunnelled through the Tailscale WireGuard stack.

> **PocketBook loopback note**: PocketBook firmware does not configure the loopback interface at boot. The start script brings it up via `sudo ifconfig lo 127.0.0.1 up` before binding the proxy.

### Enabling the proxy in KOReader

In KOReader: **Menu → Network → Tailscale VPN → Settings/Config → Proxy for userspace mode**

## Files Location

| File | Kindle | PocketBook |
|------|--------|------------|
| Binaries | `/mnt/us/tailscale/bin/` | `/mnt/ext1/tailscale/bin/` |
| Logs | `/mnt/us/tailscale/bin/tailscale.log` | `/mnt/ext1/tailscale/bin/tailscale.log` |
| Auth Key | `/mnt/us/tailscale/bin/auth.key` | `/mnt/ext1/tailscale/bin/auth.key` |

Logs (`tailscale.log`, `tailscaled.log`) and configuration files (`auth.key`, `headscale.url`) are stored in the same directory.

## Uninstall / Reinstall
1. **Uninstall**: Menu → Plugins → Tailscale VPN → Uninstall Tailscale.
2. **Reinstall**: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

You may want to back up your `auth.key` before uninstalling, and restore it after reinstalling.

## Manual Installation

If the automatic installation fails, you can install Tailscale manually:

### 1. Download Tailscale Binaries
Download the appropriate binaries for your device architecture (ARMv7/ARM64):
```bash
# On your computer
wget https://pkgs.tailscale.com/stable/tailscale_1.96.2_arm.tgz
# or
curl -O https://pkgs.tailscale.com/stable/tailscale_1.96.2_arm.tgz
```

### 2. Transfer to Your Device
```bash
# Kindle (SSH on port 2222)
scp -P 2222 tailscale_1.96.2_arm.tgz root@<device-ip>:/mnt/us/tailscale/bin/

# Kobo
scp tailscale_1.96.2_arm.tgz root@<device-ip>:/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/
```

### 3. Extract and Install
SSH into your device and run:
```bash
cd /mnt/us/tailscale/bin  # adjust path for your device

tar xzf tailscale_1.96.2_arm.tgz
mv tailscale_*/tailscale tailscale_*/tailscaled ./
rm -rf tailscale_* tailscale_1.96.2_arm.tgz
chmod +x tailscale tailscaled
touch auth.key
```

### 4. Configure Auth Key
```bash
echo "tskey-..." > /mnt/us/tailscale/bin/auth.key
```

### 5. Start Tailscale
Return to KOReader and use the plugin menu to start Tailscale.

## Troubleshooting
- **Logs** (paths depend on device):
  - Kindle: `/mnt/us/tailscale/bin/tailscaled.log` and `tailscale.log`
  - PocketBook: `/mnt/ext1/tailscale/bin/tailscaled.log` and `tailscale.log`

## Security
- End-to-end encrypted via WireGuard (Tailscale's transport)
- Device only reachable from your tailnet
- Auth keys stored locally on device
- No inbound ports opened

## Credits
Based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), adapted for KOReader. Runs alongside [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

## License
MIT License - See included LICENSE file.
