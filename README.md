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
**Check again**. The exact path varies by platform (on PocketBook the key does not live under the plugin directory); the table in the [platform notes](docs/platforms/README.md) lists each one.

The file should contain only the key: `tskey-...` or `hskey-auth-...`. 

Once the device is signed in and its node state is stored persistently, the plugin deletes the file.

To use a self-hosted Headscale server instead of the official control plane, go to Network setup → **Control plane** and enter your server URL.

## Networking

The plugin picks the networking mode the device supports. If a device has no usable kernel TUN, tailnet traffic from KOReader has to go through the local proxy. The mode matrix above and [docs/networking.md](docs/networking.md) describe both modes in full.

| Capability | Kernel TUN | Userspace networking |
| --- | --- | --- |
| Inbound to services on the device (Syncthing `:22000`, KOReader SSH `:2222`) | Yes | Yes — TCP is accepted and re-dialed to localhost |
| Outbound from apps (KOReader, Syncthing) | Transparent | Only through the local proxy |
| Tailscale SSH (`:22`) | Yes | Yes |
| HTTP proxy `127.0.0.1:1056` | Optional | Required for outbound traffic |

### Exit nodes

Plugin config → Exit node: pick a node from the list or enter one manually. This applies on the next connect (disconnect and reconnect in the plugin).

### HTTP proxy

Plugin config → Automatically configure HTTP proxy sets KOReader's HTTP proxy to `http://127.0.0.1:1056` when the device connects, and restores the previous setting on disconnect or uninstall. The proxy is reconciled at each launch, so a crash cannot leave KOReader pointing at a dead port. `tailscaled` also offers SOCKS5 on `127.0.0.1:1055`.

### Tailscale SSH

Plugin config → **Enable Tailscale SSH** (`tailscale_ssh`, off by default) passes `--ssh`. `tailscaled` serves SSH on port `22` of the device's tailnet address, subject to your tailnet ACLs. It works in userspace mode as well as kernel TUN, and host keys live under `<state dir>/ssh/`, so no rootfs writes are needed.

This is independent of KOReader's own SSH server, which normally listens on `2222`; both can run at once. From another tailnet machine, use `tailscale ssh <user>@<device>`, with a user your tailnet policy allows. `./tailscale status` shows the node either way.

### Userspace mode

Plugin config → Force userspace mode selects the alternate networking mode; use it when kernel TUN is unstable on your device. Takes effect on the next start.

In userspace mode, enable Automatically configure HTTP proxy in Plugin config, or set Settings → Network → Proxy to `http://127.0.0.1:1056`. Exit-node routing in this mode applies only to traffic sent through the proxy.

With kernel TUN, KOReader gets transparent tailnet routing. Either mode carries file sync via [koreader-syncthing](https://github.com/jasonchoimtt/koreader-syncthing).

### Subnet routes

Plugin config → Accept subnet routes (on by default) lets the device reach networks that a subnet router advertises to the tailnet. Turn it off if one of those routes covers the device's own LAN: accepted routes take priority over the local network, so the device stops answering on its LAN address while Tailscale is connected. Takes effect on the next connect.

## Troubleshooting

**Connections time out; curl or ssh from a shell never routes; the device has no
`/dev/net/tun`.** That device is in userspace mode, where host apps only get the
tailnet through the local proxy. KOReader's own traffic uses it when Automatically
configure HTTP proxy is on, but programs you run from a shell do not: pass the
proxy explicitly (`curl -x http://127.0.0.1:1056 …`) or use a device with kernel
TUN.

**OPDS fails with "host or service not provided, or not known".** Turn on
**Automatically configure HTTP proxy**; KOReader's HTTP requests then resolve names
through Tailscale's proxy. As a fallback, enter the remote device's `100.x`
address.

**PocketBook shows "No network connectivity" on 1.3.0.** That version's
connectivity preflight blocked startup on filtered networks. The preflight has been
removed; upgrade to 1.4.1.

**HTTPS fails through the HTTP proxy.** This is an upstream KOReader bug, not the
plugin: [koreader/koreader#14693](https://github.com/koreader/koreader/issues/14693).
Kernel TUN mode avoids the proxy entirely.

## Testing

```sh
sh tests/run.sh       # shell scripts, run against fake tailscale/tailscaled/iptables binaries
luajit tests/unit.lua # Lua unit tests, headless (also runs under Lua 5.1+)
```

`tests/run.sh` needs no device and no network: it puts the scripts in a temporary
directory next to stub binaries and checks the behavior the plugin depends on.
`tests/unit.lua` exercises the Lua side without KOReader. CI runs both, plus Lua
syntax checks and shellcheck.

## Design

- **Lua decides, shell executes.** `main.lua` builds every `tailscaled` and
  `tailscale` argument and passes it to `bin/*.sh` as quoted environment
  variables. The scripts never re-parse a command string, so hostnames, auth
  keys and Headscale URLs cannot turn into shell code.
- **Node identity stays private.** `tailscaled.state` is kept off USB-exported
  storage in a root-only directory, and logs (which can contain the login URL)
  live beside it rather than in `bin/`.
- **Login never blocks the UI.** `tailscale up` runs in the background; the
  plugin polls `status --json` and shows the QR code only when asked.
- **Networking mode is a capability check, not a device list.** Kernel TUN is
  used when `/dev/net/tun` is usable, userspace otherwise, with an explicit
  override for unstable kernels.
- **Tests run without a device.** `tests/unit.lua` stubs KOReader and exercises
  the decision logic under LuaJIT; `tests/run.sh` runs the scripts against fake
  binaries.

## Credits

Inspired by [mitanshu7/tailscale_kual](https://github.com/mitanshu7/tailscale_kual), our `.sh` access to Tailscale is essentially the same.

MIT License.
