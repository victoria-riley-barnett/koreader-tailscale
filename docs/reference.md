# Reference

Everything the README leaves out: where files go on each device, how the two
networking modes differ, what each setting changes, and where Tailscale keeps
state and logs.

The plugin supports ARMv7 and ARM64 devices.

## Platform paths

| Platform | KOReader plugin folder | Auth-key file | Node state |
| --- | --- | --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` | `<plugin>/bin/auth.key` | `/var/local/koreader-tailscale/` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` | `<plugin>/bin/auth.key` | `/usr/local/koreader-tailscale/` |
| PocketBook | `/mnt/ext1/koreader/plugins/` | `/mnt/ext1/tailscale/bin/auth.key` | `/var/lib/koreader-tailscale/` |
| Other | `<koreader>/plugins/` | `<plugin>/bin/auth.key` | `/var/lib/koreader-tailscale/` |

PocketBook keeps the binaries and the auth key at `/mnt/ext1/tailscale/bin/`
instead of inside the plugin folder, so updating the plugin does not disturb
them.

These are the paths common setups use. A device that loads plugins through
`extra_plugin_paths` (reMarkable) keeps everything under that path instead, and
the plugin derives its own location rather than assuming the default.

For TLS the plugin uses KOReader's CA bundle when it finds one, probing
`<koreader>/data/ca-bundle.crt`, `/mnt/us/koreader/data/ca-bundle.crt`, and
`/mnt/onboard/.adds/koreader/data/ca-bundle.crt` in that order. Nothing to
configure.

## State and logs

`tailscaled.state` holds the node's private keys, so where it lives decides who
can clone the node. On Kindle, Kobo and PocketBook the plugin folder is on
storage a computer can read over USB, so state moves to the root-only directory
listed in the table above. A device whose plugin folder is private keeps state
where it is.

If no private directory can be made, the plugin falls back to `/tmp/tailscale`
and copies state back into the plugin folder on a clean stop. That state does not
survive a reboot. All of this is automatic.

| File | Contents |
| --- | --- |
| `tailscaled.state` | Node keys and identity |
| `tailscaled.log.conf` | Tailscale's log settings |
| `ssh/` | Tailscale SSH host keys, when that setting is on |
| `logs/tailscaled.log`, `logs/tailscale.log` | Daemon and client logs |

Logs live in the state directory rather than the USB-exported plugin folder
because they can contain the interactive login URL.

## Networking modes

**Kernel TUN.** `tailscaled` creates a `tailscale0` interface and the kernel
routes traffic into it. Host processes — KOReader, Syncthing, anything you start
from a shell — reach the tailnet directly, and connections from the tailnet reach
whatever is listening on the device. On Kindle, where firewall chains default to
DROP, the plugin also lets `tailscale0` traffic through.

**Userspace networking.** `tailscaled` terminates connections itself, inside the
process. There is no interface for the kernel to route into, so host processes
get nothing by default: outbound traffic has to go through the local proxy, and
inbound connections only reach services `tailscaled` implements itself (Tailscale
SSH). This is the mode that works on devices without a usable `/dev/net/tun`.

The plugin picks the mode from the device's capabilities, not its name, so
different models in the same product family may behave differently. **Force
userspace mode** in Plugin config overrides the choice when kernel TUN is
unstable; it takes effect on the next start.

`tailscaled` stays running when connectivity drops and reconnects when it
returns, so networks that block public DNS servers or ICMP are fine.

The two modes are not interchangeable in practice. Kernel TUN carries the whole
client; userspace mode carries HTTP outbound only, because HTTPS through
KOReader's HTTP proxy is blocked by an upstream bug
([koreader/koreader#14693](https://github.com/koreader/koreader/issues/14693)).

### Inbound

In kernel TUN mode the device looks like any other tailnet node: connect to its
Tailscale IP and port and you reach the listening process.

In userspace mode `tailscaled` still accepts inbound TCP on the tailnet and
re-dials `127.0.0.1:<the same port>` as an ordinary local client, so a service
listening on the device is reachable but sees the connection from localhost. UDP
is not forwarded. Tailscale SSH is served inside `tailscaled` in both modes.

### Outbound

Kernel TUN mode is transparent; no proxy setting is involved.

In userspace mode, point clients at the local proxy that `tailscaled` exposes:

| Proxy | Address |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP | `127.0.0.1:1056` |

Plugin config does not touch KOReader's proxy. In userspace mode, point KOReader
at `http://127.0.0.1:1056` yourself under Settings → Network → Proxy and clear it
when you disconnect; the plugin leaves that setting exactly as you left it.
Programs you run from a shell do not pick it up on their own; pass the proxy
explicitly (`curl -x http://127.0.0.1:1056 …`).

## Control plane

By default the device joins Tailscale's own control plane. To join a self-hosted
[Headscale](https://headscale.net/stable/) server instead, set Network setup →
**Control plane** to that server's URL. The plugin writes it to
`<plugin>/bin/headscale.url` and passes `--login-server` on the next connect, so
restart Tailscale to apply it. Clearing the field returns the device to
Tailscale's control plane.

The server side belongs to Headscale's documentation:
[installation](https://headscale.net/stable/setup/install/main/), then
[getting started](https://headscale.net/stable/usage/getting-started/), which
shows creating a user and a pre-auth key. A Headscale pre-auth key carries the
`hskey-auth-…` prefix and goes in the same auth-key file as a Tailscale
`tskey-…`.

## Tailscale SSH

Plugin config → **Enable Tailscale SSH** (`tailscale_ssh`, off by default) passes
`--ssh`. `tailscaled` serves SSH on port `22` of the device's tailnet address,
governed by your tailnet ACLs. It works in userspace mode as well as kernel TUN,
and host keys are generated under `<state dir>/ssh/`, so no rootfs writes are
needed.

This is independent of KOReader's own SSH server, which listens on `2222`. Both
can run at once.

From another tailnet machine:

```sh
tailscale ssh <user>@<device>
```

`<user>` must be permitted by the tailnet policy. On the device, `./tailscale
status` shows the node and whether SSH is offered.

## Exit nodes

Plugin config → Exit node: choose one from the list or enter it manually. It
applies on the next connect (disconnect and reconnect in the plugin). In
userspace mode, exit-node routing covers only traffic sent through the proxy.

## Subnet routes

Plugin config → **Accept subnet routes** (on by default) lets the device reach
networks a subnet router advertises. Accepted routes take priority over the local
network, so if one covers the device's own LAN the device stops answering on its
LAN address while Tailscale is connected. Applies on the next connect, and in
userspace mode it again covers only traffic sent through the proxy.
