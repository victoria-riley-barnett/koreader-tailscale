# Tailscale Plugin for KOReader

It was really bothering me that I had to switch networks on my phone just to sync my Syncthing files, and checking which new IP my e-reader had picked up
(for something like the Filebrowser plugin) was a lot of steps. This plugin fixes both: it runs [Tailscale](https://tailscale.com) on your e-reader from
inside KOReader, so it slots right into your Syncthing, SSH or OPDS setup.

- **Always reachable.** Your e-reader gets a permanent Tailscale IP, even when it's on a different Wi-Fi network (home, work, café).
- **No hassle.** Tailscale takes care of NAT traversal, so Syncthing, SSH, etc just work from anywhere.

Most testing has been on Kindle, but we are able to generally implement platform fixes (as this is mostly file path variety or service swaps).

Feedback and contributions are welcome, create an [Issue](https://github.com/victoria-riley-barnett/koreader-tailscale/issues) if you run into any problems <3

## Setup

1. Tailscale account (a [Headscale](https://headscale.net) server
   works too).
2. Download the plugin from the [releases page](../../releases) and copy
   `tailscale.koplugin` into KOReader's `plugins` folder.
3. Restart KOReader and tap Network → Tailscale VPN → Install/Update Tailscale.
   It downloads the right binaries for your device and checks them before
   installing.
4. Sign in by scanning the QR code with your phone, or use an auth key. See the
   [platform notes](docs/platforms/README.md) for device-specific paths and
   networking details.

For Syncthing, use the Tailscale IP in the device's Addresses field:
`tcp://<tailscale-ip>:22000`. Any other service on the device (SSH, a file
browser) is reached the same way, using the IP shown in Status.

## Installation

1. Copy `tailscale.koplugin` into KOReader's plugins directory. See the
   [platform notes](docs/platforms/README.md) for device-specific locations.
2. Restart KOReader.
3. Open Network → Tailscale VPN → Install/Update Tailscale. In reader mode,
   open the gear icon and go to Settings → Network → Tailscale VPN.

### Manual installation

If the automatic installation fails, install the binaries by hand.

1. Download the binaries for your architecture (`arm` for ARMv7, `arm64` for ARM64). Releases are at [pkgs.tailscale.com/stable](https://pkgs.tailscale.com/stable/).

   ```sh
   wget https://pkgs.tailscale.com/stable/tailscale_<version>_arm.tgz
   wget https://pkgs.tailscale.com/stable/tailscale_<version>_arm.tgz.sha256
   echo "$(cat tailscale_<version>_arm.tgz.sha256)  tailscale_<version>_arm.tgz" | sha256sum -c
   ```

2. Transfer the archive to the device's plugin `bin` directory. See the [platform notes](docs/platforms/README.md) for common
   paths.

   ```sh
   scp -P 2222 tailscale_<version>_arm.tgz root@<device-ip>:/path/to/tailscale.koplugin/bin/
   ```

   Then, on the device:

   ```sh
   cd /path/to/tailscale.koplugin/bin
   tar xzf tailscale_<version>_arm.tgz
   mv tailscale_*/tailscale tailscale_*/tailscaled ./
   rm -rf tailscale_* tailscale_<version>_arm.tgz
   chmod +x tailscale tailscaled
   ```

3. Start Tailscale from the plugin menu and sign in.

## Sign in
- **Scan QR code** — shows a sign-in QR for pairing a new Tailscale device. Scan it with your phone to finish the approval process on Tailscale.
- Alternatively, **Use an auth key** — place a key in the plugin's `bin/auth.key` file and tap "Check again".

See the [platform notes](docs/platforms/README.md) for file path considerations. The file should contain the key onliy: `tskey-...` or `hskey-auth-...`. Once the device is signed in the plugin deletes the file, since the key is no longer needed and `bin/` is readable over USB.

- Finally, you can go to Network setup → **Control plane** to enter the URL of a self-hosted Headscale server.

## Networking

The plugin picks the networking mode supported by your device. If a device doesn't support kernel TUN, tailnet traffic from KOReader must go through the HTTP proxy.

### Exit nodes

Plugin config → Exit node: pick a node from the list or enter one manually. This applies on the next restart, which can be triggered by disconnecting in plugin & then reconnecting.

### HTTP proxy

Plugin config → Automatically configure HTTP proxy sets KOReader's HTTP proxy to `http://127.0.0.1:1056` when the device connects and restores the previous setting on disconnect.

### userspace mode

Plugin config → Force userspace mode selects the alternate networking mode; use it when kernel TUN is unstable on your device. Takes effect on the next start.

In userspace mode, enable Automatically configure HTTP proxy in Plugin config, or set Settings → Network → Proxy to `http://127.0.0.1:1056`. Exit-node routing in this mode applies only to traffic sent through the proxy.

With kernel TUN, KOReader gets transparent tailnet routing. Either mode carries file sync via [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

### Subnet routes

Plugin config → Accept subnet routes (on by default) lets the device reach networks that a subnet router advertises to the tailnet. Turn it off if one of those routes covers the device's own LAN: accepted routes take priority over the local network, so the device stops answering on its LAN address while Tailscale is connected. Takes effect on the next start.

See the [platform notes](docs/platforms/README.md) for device-specific behavior.

## Credits

Inspired by [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), our .sh tailscale access is essentially the same. MIT License.
