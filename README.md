# Tailscale Plugin for KOReader

Run [Tailscale](https://tailscale.com) on your e-reader from inside KOReader:
the device joins your tailnet and gets a Tailscale IP for OPDS, progress sync,
and file sync over the tailnet. Requires an ARMv7 or ARM64 device.

## Installation

1. Copy `tailscale.koplugin` into the KOReader plugins directory:

   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`
   - PocketBook: `/mnt/ext1/koreader/plugins/`

2. Restart KOReader.
3. Open Network → Tailscale VPN → Install/Update Tailscale. In reader mode,
   open the gear icon and go to Settings → Network → Tailscale VPN.

The download is about 57 MB. Do not close KOReader during installation.

### Manual installation

If the automatic installation fails, install the binaries by hand. The
examples use the Kindle paths; substitute the plugin directory on your device.

1. Download the binaries for your architecture (`arm` for ARMv7, `arm64` for
   ARM64). The version in the URLs is an example; current releases are listed
   at [pkgs.tailscale.com/stable](https://pkgs.tailscale.com/stable/).

   ```sh
   wget https://pkgs.tailscale.com/stable/tailscale_<version>_arm.tgz
   ```

2. Transfer the archive to the device and extract it:

   ```sh
   scp -P 2222 tailscale_<version>_arm.tgz root@<device-ip>:/mnt/us/koreader/plugins/tailscale.koplugin/bin/
   cd /mnt/us/koreader/plugins/tailscale.koplugin/bin
   tar xzf tailscale_<version>_arm.tgz
   mv tailscale_*/tailscale tailscale_*/tailscaled ./
   rm -rf tailscale_* tailscale_<version>_arm.tgz
   chmod +x tailscale tailscaled
   ```

3. Start Tailscale from the plugin menu and sign in.

### Uninstall

Network → Tailscale VPN → Plugin config → Uninstall Tailscale stops Tailscale
and removes its files, including the auth key. Restart KOReader to finish.
Back up `bin/auth.key` first if you want to keep it, then reinstall with
Install/Update Tailscale.

### What the plugin relies on from the device

A CA bundle for TLS. Typically located in KOReader's data directory:

- Kindle: `/mnt/us/koreader/data/ca-bundle.crt`
- Kobo: `/mnt/onboard/.adds/koreader/data/ca-bundle.crt`

The start script probes these paths, non-exhaustively. If your bundle lives
elsewhere, export `SSL_CERT_FILE=/path/to/ca-bundle.crt` before starting
KOReader and it is used as-is.

## Usage

The top row of Network → Tailscale VPN reports the connection and acts on it:
tap `Off` to connect, `Connected` to disconnect, `Not connected — tap to sign
in` to sign in.

### Sign in

Under Network setup:

- **Scan QR code** — shows the sign-in QR (connecting first if needed). Scan
  it with your phone, approve the device, and the code dismisses itself.
- **Use an auth key** — drop a reusable key at `bin/auth.key` and tap
  "Check again". The file must contain the key alone (`tskey-...` or
  `hskey-auth-...`):

  - Kindle: `/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key`
  - Kobo: `/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key`
  - PocketBook: `/mnt/ext1/tailscale/bin/auth.key` (external storage)

  ```sh
  scp -P 2222 auth.key user@kindle-ip:/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key
  ```

- **Control plane** — Network setup → Control plane, enter the URL of a
  self-hosted Headscale server. The row reads `Control plane: Tailscale
  (default)` until set. Headscale auth keys may start with `hskey-auth-`.

Tailscale starts when KOReader opens and resumes its last state: a device
left connected reconnects, one left off stays off.

### Exit node

Plugin config → Exit node: pick a node from the list or enter one manually.
Restart Tailscale to apply.

### HTTP proxy

Plugin config → Automatically configure HTTP proxy sets KOReader's HTTP proxy
to `http://127.0.0.1:1056` when the device connects and restores the previous
setting on disconnect.

### Force userspace mode

Plugin config → Force userspace mode switches the daemon to
`--tun=userspace-networking`; use it when kernel TUN is unstable on your
device. Takes effect on the next start.

### Status and logs

Status shows the device IP and connection info. Logs are written to
`bin/tailscale.log` and `bin/tailscaled.log` in the plugin's bin directory.

## Networking

The plugin uses kernel TUN when `/dev/net/tun` exists and
`--tun=userspace-networking` otherwise; it brings up loopback itself if the
firmware did not. Both modes expose SOCKS5 on `127.0.0.1:1055` and HTTP
CONNECT on `127.0.0.1:1056`.

In userspace mode, tailnet traffic to KOReader must go through the HTTP
proxy on port 1056: enable Automatically configure HTTP proxy in Plugin
config, or set Settings → Network → Proxy to `http://127.0.0.1:1056` by
hand. Exit-node routing applies only to traffic sent through the proxy in
this mode.

With kernel TUN, KOReader gets transparent tailnet routing for OPDS, progress
sync, and Home Assistant. Either mode carries file sync via
[koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

## Credits

Based on [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual). MIT License.
