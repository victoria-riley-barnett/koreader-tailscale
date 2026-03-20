# Tailscale Plugin for KOReader

Run Tailscale on your e-reader. Tested on Kindle PW5/PW6, Kobo, and PocketBook. Should work on any KOReader device with ARMv7 or ARM64.

Pairs well with [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing) for file sync over your tailnet.

## Installation

1. Copy `tailscale.koplugin/` to your KOReader plugins directory and restart KOReader.
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - PocketBook: `/mnt/ext1/koreader/plugins/`

2. Menu → Network → Tailscale VPN → **Install/Update Tailscale** (~25–57 MB).

## Setup

1. Create a reusable auth key at [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).

2. Save it as `auth.key` in the plugin's `bin/` directory (starts with `tskey-`).

3. Menu → Network → Tailscale VPN → toggle **On**.

**Headscale**: place your server URL in `bin/headscale.url` (e.g. `https://headscale.example.com`).

## Proxy

The plugin runs SOCKS5 on `127.0.0.1:1055` and HTTP CONNECT on `127.0.0.1:1056` so KOReader can reach tailnet services (OPDS, sync, etc.).

## Troubleshooting

Check `bin/tailscaled.log` and `bin/tailscale.log` in the plugin directory. See [NOTES.md](NOTES.md) for internals and manual installation.

## Credits

Based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual). MIT License.
