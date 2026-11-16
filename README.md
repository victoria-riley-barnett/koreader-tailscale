# Tailscale Plugin for KOReader

A Tailscale client for KOReader, for cross-network syncing, SSH, and file sharing on e-readers.

It was bothering me that I had to get my phone and Kindle onto the same network just to sync my Syncthing files (a key player in any open alternative that skips paid services or sync features locked in w/ library apps. 

Checking which new IP my e-reader had picked up (for something like the Filebrowser plugin), connecting this to some service (for a limited time, etc) was a lot of steps. 

This plugin aims to fix both & did for me: it runs [Tailscale](https://tailscale.com) on your e-reader from inside KOReader, enabling [Syncthing](https://github.com/syncthing/syncthing), [SSH](https://github.com/koreader/koreader/wiki/SSH), and other file & library sync strategies. 

Recently added support for Headscale, so some users can interface even more directly with their own services. I haven't set up my own yet, but there are setup examples in the [GH issues](https://github.com/victoria-riley-barnett/koreader-tailscale/issues), please create one if you have any problems.

- **Always reachable.** Your e-reader gets a permanent Tailscale IP or Magic DNS, even when it's on a different Wi-Fi network (home, work, café)
- **No hassle.** With a now more permanent identity, Syncthing, SSH, and other services:
    - Can do their work regardless of where your two devices are
    - Will be more reliable, and require less configuration (a great deal of potential opens up once you have both shell & file system access, ala [PuTTY](https://putty.org/index.html))

Most testing has been on Kindle, but we are able to generally implement platform fixes (mostly file path variety or service swaps). See the [platform notes](docs/platforms/README.md) for device-specific paths and behavior. 

Feedback and contributions are welcome!

## Setup

1. Tailscale account (a self-hosted [Headscale](https://headscale.net) server
   works too).
2. Download the plugin from the
   [releases page](https://github.com/victoria-riley-barnett/koreader-tailscale/releases)
   and copy `tailscale.koplugin` into KOReader's `plugins` folder.
3. Restart KOReader and tap Network → Tailscale VPN → Install/Update Tailscale.
   It downloads the right binaries for your device and checks them before
   installing.
4. Sign in by scanning the QR code with your phone, or use an auth key.

### Pointing services at the device

Every service on the e-reader is reached the same way: by the address Tailscale
gives it, not by whatever IP the local network handed out this week.

For Syncthing, put the e-reader's Tailscale IP in the device's Addresses field
on your other machines:

```
tcp://<tailscale-ip>:22000
```

SSH, a file browser, or an OPDS server are configured identically, using the IP
shown under Status.

**Names vs. addresses.** From your laptop or phone you can usually use the
device's MagicDNS name (`<device>.<tailnet>.ts.net`) instead of the IP. On the
e-reader itself, the plugin runs `tailscaled` with `--accept-dns=false` so
Tailscale cannot rewrite KOReader's resolver — which means the e-reader dials
out to IP addresses, while everything else may dial the name. If a name does not
resolve in one direction, use the IP.

## Installation

1. Copy `tailscale.koplugin` into KOReader's plugins directory. See the
   [platform notes](docs/platforms/README.md) for device-specific locations.
2. Restart KOReader.
3. Open Network → Tailscale VPN → Install/Update Tailscale. In reader mode,
   open the gear icon and go to Settings → Network → Tailscale VPN.

### Manual installation

If the automatic installation fails, install the binaries by hand.

1. Download the binaries for your architecture (`arm` for ARMv7, `arm64` for
   ARM64) from [pkgs.tailscale.com/stable](https://pkgs.tailscale.com/stable/).

   ```sh
   wget https://pkgs.tailscale.com/stable/tailscale_<version>_arm.tgz
   wget https://pkgs.tailscale.com/stable/tailscale_<version>_arm.tgz.sha256
   echo "$(cat tailscale_<version>_arm.tgz.sha256)  tailscale_<version>_arm.tgz" | sha256sum -c
   ```

2. Transfer the archive to the device's plugin `bin` directory. See the
   [platform notes](docs/platforms/README.md) for common paths.

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

- **Scan QR code** — shows a sign-in QR for pairing a new Tailscale device. Scan
  it with your phone to finish the approval process on Tailscale.
- **Use an auth key** — place a key in the plugin's `bin/auth.key` file and tap
  **Check again**. The exact path varies by platform (on PocketBook the key does
  not live under the plugin directory); the table in the
  [platform notes](docs/platforms/README.md) lists each one.

The file should contain only the key: `tskey-...` or `hskey-auth-...`. Once the
device is signed in and its node state is stored persistently, the plugin
deletes the file — the key is no longer needed, and `bin/` is readable over USB.
The key is handed to `tailscale up` as a root-only file in `/tmp` rather than as
an argument, so it does not show up in `ps`.

To use a self-hosted Headscale server instead of the official control plane, go
to Network setup → **Control plane** and enter your server URL.

## Networking

The plugin picks the networking mode supported by your device. If a device
doesn't support kernel TUN, tailnet traffic from KOReader must go through the
HTTP proxy.

### Exit nodes

Plugin config → Exit node: pick a node from the list or enter one manually. This
applies on the next restart, which can be triggered by disconnecting in the
plugin and then reconnecting.

### HTTP proxy

Plugin config → Automatically configure HTTP proxy sets KOReader's HTTP proxy to
`http://127.0.0.1:1056` when the device connects, and restores the previous
setting on disconnect.

### Userspace mode

Plugin config → Force userspace mode selects the alternate networking mode; use
it when kernel TUN is unstable on your device. Takes effect on the next start.

In userspace mode, enable Automatically configure HTTP proxy in Plugin config, or
set Settings → Network → Proxy to `http://127.0.0.1:1056`. Exit-node routing in
this mode applies only to traffic sent through the proxy.

With kernel TUN, KOReader gets transparent tailnet routing. Either mode carries
file sync via [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

### Subnet routes

Plugin config → Accept subnet routes (on by default) lets the device reach
networks that a subnet router advertises to the tailnet. Turn it off if one of
those routes covers the device's own LAN: accepted routes take priority over the
local network, so the device stops answering on its LAN address while Tailscale
is connected. Takes effect on the next start.

## Credits

Inspired by [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual),
our `.sh` access to Tailscale is essentially the same.

The manual setup this plugin replaces has a longer tail: Anarcat's
[notes on running Syncthing on a Kobo Clara HD](https://anarc.at/hardware/tablet/kobo-clara-hd/)
and MrCarl's
[My KOReader Syncthing Journey](https://www.mobileread.com/forums/showthread.php?t=359310)
show why "put the binary on the device and forward a port" was the standard
answer. Those setups work — they just leave you tracking IPs and keeping the
WebGUI off the network. Retiring that last step is the point of this plugin.

MIT License.
