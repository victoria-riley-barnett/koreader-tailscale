# Tailscale Plugin for KOReader

[![CI](https://github.com/victoria-riley-barnett/koreader-tailscale/actions/workflows/ci.yml/badge.svg)](https://github.com/victoria-riley-barnett/koreader-tailscale/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/victoria-riley-barnett/koreader-tailscale)](https://github.com/victoria-riley-barnett/koreader-tailscale/releases)

A tailscale client for KOReader, allowing you to connect your e-reader to your tailnet.

I was extremely tired of looking up short lived ip addresses and reconfiguring sync plugins. This plugin addresses the disposability problem head-on, virtualizing a persistent network connection by allowing KOReader traffic to go  through Tailscale (or [Headscale](https://headscale.net)).

This connection enables services like Syncthing and SSH to work seamlessly across your tailnet devices as you change networks.

Most testing has been on two Kindles I own, but we are able to implement platform fixes (mostly file path variety or service swaps). See the [platform notes](docs/platforms/README.md) for device-specific paths and behavior.

I have not set up my own headscale instance, there are setup examples:

Please create an [issue](https://github.com/victoria-riley-barnett/koreader-tailscale/issues) if you have any problems. Feedback and contributions are welcome!

## Setup
1. Tailscale account (or a self-hosted [Headscale](https://headscale.net) server).
2. Download the plugin from the
[releases page](https://github.com/victoria-riley-barnett/koreader-tailscale/releases) and copy `tailscale.koplugin` into KOReader's `plugins` folder.
3. Restart KOReader and tap Network → Tailscale VPN → Install/Update Tailscale.
4. Sign in by scanning the QR code with your phone, or use an auth key file. See the [Sign in](#sign-in) section for details.

### On your other devices
Remember your ports! An example address in my [syncthing client](https://apps.apple.com/us/app/synctrain/id6553985316) on iOS:
```
tcp://<kindle.tailscalestuffhere>:22000
```

## Installation

1. Copy `tailscale.koplugin` into KOReader's plugins directory. See the
[platform notes](docs/platforms/README.md) for device-specific locations.
2. Restart KOReader.
3. Open Network → Tailscale VPN → Install/Update Tailscale. In reader mode,
open the gear icon and go to Settings → Network → Tailscale VPN.


## Sign in

- Scan QR code: show a sign-in QR for pairing a new Tailscale device, it's tailscale's own check-in flow.
- Auth key: place a key in the plugin's `bin/auth.key` file and tap the connection button. 
   - The exact path varies by [platform](docs/platforms/README.md).

The file should contain only the key: `tskey-...` or `hskey-auth-...`. 

### Networking
The plugin picks the networking mode the device supports. If a device has no usable kernel TUN, tailnet traffic from KOReader has to go through the local proxy. The mode matrix above and [docs/networking.md](docs/networking.md) describe both modes in full.

To use a self-hosted Headscale server instead of the official control plane, go to Network setup → **Control plane** and enter your server URL.

| Capability | Kernel TUN | Userspace networking |
| --- | --- | --- |
| Inbound to services on the device (Syncthing `:22000`, KOReader SSH `:2222`) | Yes | Yes — TCP is accepted and re-dialed to localhost |
| Outbound from apps (KOReader, Syncthing) | Transparent | Only through the local proxy |
| Tailscale SSH (`:22`) | Yes | Yes |
| HTTP proxy `127.0.0.1:1056` | Optional | Required for outbound traffic |

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

## Credits

Inspired by [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), our `.sh` access to Tailscale is essentially the same.

MIT License.
