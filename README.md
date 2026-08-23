# Tailscale Plugin for KOReader

## Description

Run Tailscale on your e-reader. Tested on Kindle PW5/PW6, Kobo, and PocketBook. Should work on any KOReader device with ARMv7 or ARM64.

Pairs well with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) for file sync over your tailnet.

## Prerequisites

1. A Tailscale account. Sign up at [tailscale.com](https://tailscale.com).
2. A reusable auth key. Create it at the [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
3. An e-reader with file or SSH access. KOReader must be installed.

## Installation

1. Copy `tailscale.koplugin` to the KOReader plugins directory.
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - PocketBook: `/mnt/ext1/koreader/plugins/`
2. Restart KOReader.
3. Open Network → Tailscale VPN and select Install/Update Tailscale. In reader mode, open the gear icon and select Settings → Network → Tailscale VPN.

Installation downloads 25 to 57 MB. Do not close KOReader during installation.

To skip the download, transfer the binaries to the plugin `bin/` directory over SCP/SSH. See Manual Installation.

## Setup

1. Save the auth key. Copy the reusable auth key to `bin/auth.key`. Default locations:
   - Kindle: `/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key`
   - PocketBook: `/mnt/ext1/tailscale/bin/auth.key` (external storage)

   ```sh
   scp -P 2222 auth.key user@kindle-ip:/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key
   scp -P 2222 auth.key user@kobo-ip:/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key
   scp -P 2222 auth.key user@pocketbook-ip:/mnt/ext1/tailscale/bin/auth.key
   ```

2. Optional: use a self-hosted Headscale server. Create `headscale.url` in the bin directory and write the server URL to it. Default locations match the auth.key locations above. Headscale auth keys may start with `hskey-auth-`. The menu item "Headscale URL info" shows the configured URL and how to update it.

3. Enable the connection. Open Network → Tailscale VPN and toggle On.

## Networking

The plugin uses kernel TUN when `/dev/net/tun` is a readable and writable character device. Kernel mode gives KOReader transparent tailnet routing for OPDS, progress sync, and Home Assistant. Without a usable TUN device, the plugin uses `--tun=userspace-networking`.

The selected mode is written as the first line of `bin/tailscaled.log`.

To force userspace mode, create an empty file `bin/force-userspace` and restart Tailscale. Use this when the TUN driver is unstable. On certain Kobo devices, kernel TUN crashes the device with `wgengine: watchdog timeout on Reconfig`. The force-userspace file fixes it.

In both modes the plugin listens for SOCKS5 on `127.0.0.1:1055` and HTTP CONNECT on `127.0.0.1:1056`. In userspace mode, set KOReader's HTTP proxy to `http://127.0.0.1:1056` (Settings → Network → Proxy).

## Files

Binaries, configuration, and logs live in the bin directory. The location depends on the device.

- Kindle: `/mnt/us/koreader/plugins/tailscale.koplugin/bin/`
- Kobo: `/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/`
- PocketBook: `/mnt/ext1/tailscale/bin/` (external storage)

PocketBook uses external storage because the plugin directory may be on a read-only filesystem. Logs (`tailscale.log`, `tailscaled.log`) and configuration (`auth.key`, `headscale.url`) are stored in the same directory.

Make the scripts executable on the device:

```sh
cd /mnt/us/koreader/plugins/tailscale.koplugin/bin
chmod +x start_tailscale.sh
```

The Kobo and PocketBook locations follow the list above.

Installation needs space for the download. Check free space with `df -h /mnt/us /mnt/onboard /mnt` and keep at least 100 MB free. If space is short, move KOReader to another partition or use Manual Installation.

## Usage

### Syncthing

1. Read the device's Tailscale IP from the plugin status menu.
2. Install Tailscale and Syncthing on other devices.
3. Add the Tailscale address to Syncthing.

   ```
   tcp://<tailscale-ip or magic dns>:22000
   ```

This gives secure remote file synchronization without a shared network.

### Commands

- Tailscale VPN: toggle the connection.
- Status: show the device IP and info.
- Install/Update Tailscale: download and install the binaries.
- Uninstall Tailscale: stop and remove all Tailscale files. This removes the auth key.

### Platform notes

- Loopback: some firmware (Kobo, PocketBook) does not configure `lo` at boot. The plugin brings it up before starting the daemon. The SOCKS5 and HTTP proxy listeners need loopback to bind.
- FAT32: on devices with a FAT32 filesystem, state lives in `/tmp/tailscale` (tmpfs). The plugin copies it in at start and syncs it back to `bin/` on stop. Identity survives reboots because the node re-registers with `auth.key`.
- USB mass storage: tailscaled stops before KOReader enters USB storage mode and restarts after. If the device crashes mid-session, the node re-registers via `auth.key`.

## Uninstall

Open Network → Tailscale VPN and select Uninstall Tailscale. Reinstall with Install/Update Tailscale.

Back up the auth key before uninstalling. Move `bin/auth.key` to `auth.key.backup` and restore the name after reinstalling.

## Manual Installation

If the automatic installation fails, install the binaries by hand. The examples use the Kindle path. Replace it with your plugin path.

1. Download the binaries for the device architecture (ARMv7/ARMv8/ARM64).

   ```sh
   wget https://pkgs.tailscale.com/stable/tailscale_1.94.2_arm.tgz
   # or
   curl -O https://pkgs.tailscale.com/stable/tailscale_1.94.2_arm.tgz
   ```

2. Transfer the archive to the device.

   ```sh
   scp -P 2222 tailscale_1.94.2_arm.tgz root@<device-ip>:/mnt/us/koreader/plugins/tailscale.koplugin/bin/
   ```

3. Extract and install on the device.

   ```sh
   cd /mnt/us/koreader/plugins/tailscale.koplugin/bin
   tar xzf tailscale_1.94.2_arm.tgz
   mv tailscale_*/tailscale tailscale_*/tailscaled ./
   rm -rf tailscale_* tailscale_1.94.2_arm.tgz
   chmod +x tailscale tailscaled
   touch auth.key
   ```

4. Write the auth key.

   ```sh
   echo "tskey-..." > auth.key
   ```

5. Start Tailscale from the plugin menu.

If you previously kept binaries outside the plugin directory (for example `/mnt/us/tailscale`), move them into the plugin `bin/` directory.

## Troubleshooting

- No network: the plugin will not start while the device has no network. It shows an airplane mode message. Enable the network first.
- Logs: check `bin/tailscaled.log` and `bin/tailscale.log` in the plugin directory. The networking mode is the first line of `tailscaled.log`.
- Status: use the plugin status menu to see device info.

See [NOTES.md](NOTES.md) for internals.

## Credits

Based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual). MIT License.
