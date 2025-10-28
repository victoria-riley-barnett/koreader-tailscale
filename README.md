# Tailscale Plugin for KOReader

Secure remote access and file synchronization for your Kindle using Tailscale VPN.

## Features

- **Secure Remote Access**: Access your Kindle from anywhere via Tailscale VPN.
- **File Synchronization**: Use Syncthing for file transfers without being on the same network over Tailscale.

## Prerequisites

1. **Tailscale Account**: Sign up at [tailscale.com](https://tailscale.com).
2. **Auth Key**: Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
3. **Jailbroken Kindle**: With KOReader installed. Tested on PW6.

## Installation

1. Copy `tailscale.koplugin` to `/mnt/us/koreader/plugins/`.
2. Restart KOReader.
3. In KOReader: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

**Note**: Installation downloads ~57 MB and may take 5–10 minutes on slow Wi-Fi. Pre-download binaries and transfer via SCP/SSH to `/mnt/us/tailscale/bin/` to speed up.

## Setup

1. **Get Auth Key**:
   - Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
   - Copy the key (starts with `tskey-`).

2. **Configure Auth Key**:
   - Save the key to `/mnt/us/tailscale/bin/auth.key`:
     ```sh
     scp -P 2222 auth.key user@kindle-ip:/mnt/us/tailscale/bin/auth.key
     ```

3. **Start Tailscale**:
   - In KOReader: Menu → Network → Tailscale VPN → Toggle "On".
   - Check status via Menu → Network → Tailscale VPN → Status.

## Usage with Syncthing

1. Note your Kindle's Tailscale IP from the status menu.
2. Install Tailscale and Syncthing on other devices.
3. Configure Syncthing to use the Tailscale IP by adding the address:
   ```
   tcp://<tailscale-ip>:22000
   ```
4. Enjoy secure, remote file synchronization without having to be on the same local network.

## Plugin Menu Commands

- **Tailscale VPN**: Toggle connection.
- **Status**: Show device IP and info.
- **Install/Update Tailscale**: Download and install binaries.
- **Uninstall Tailscale**: Stop and remove Tailscale files (removes auth key).

## Files Location

- Binaries: `/mnt/us/tailscale/bin/`
- Logs: `/mnt/us/tailscale/bin/tailscale.log`
- Configuration: `/mnt/us/tailscale/bin/auth.key`

## Uninstall / Reinstall

1. **Uninstall**: Menu → Plugins → Tailscale VPN → Uninstall Tailscale.
2. **Reinstall**: Menu → Plugins → Tailscale VPN → Install/Update Tailscale.

**Tip**: Backup `/mnt/us/tailscale/bin/auth.key` before uninstalling and restore it after reinstalling.

## Troubleshooting

- **Logs**:
  - Daemon logs: `/mnt/us/tailscale/bin/tailscaled.log`
  - Client logs: `/mnt/us/tailscale/bin/tailscale.log`

## Security Notes

- Tailscale uses end-to-end encryption.
- Your Kindle is only accessible to devices in your Tailscale network.
- Auth keys are stored locally on the Kindle.
- No inbound internet ports are opened.

## Credits

Some parts based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), though expanded and adapted for KOReader, with in place installation + instructions, and can run side by side with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

## License

MIT License - See included LICENSE file.