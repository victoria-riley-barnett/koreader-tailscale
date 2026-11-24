# Networking

How the plugin moves traffic, what works in each networking mode, and where
Tailscale keeps state and logs. The README covers day-to-day use; this page is
the reference.

## Two modes

**Kernel TUN.** `tailscaled` creates a `tailscale0` interface and the kernel
routes traffic into it. Host processes — KOReader, Syncthing, anything you start
from a shell — reach the tailnet directly, and connections from the tailnet reach
whatever is listening on the device. The plugin also lets `tailscale0` traffic
through firewall chains whose default policy is DROP on Kindle.

**Userspace networking.** `tailscaled` terminates connections itself, inside the
process. There is no interface for the kernel to route into, so host processes get
nothing by default: outbound traffic has to go through the local proxy, and
inbound connections only reach services `tailscaled` implements itself (Tailscale
SSH). This is the mode that works on devices without a usable `/dev/net/tun`.

The plugin picks the mode from the device's capabilities, not its name. **Force
userspace mode** in Plugin config overrides the choice when kernel TUN is unstable;
it takes effect on the next start.

## What works in each mode

| Capability | Kernel TUN | Userspace networking |
| --- | --- | --- |
| Inbound to services on the device (Syncthing `:22000`, KOReader's SSH server `:2222`) | Yes | Yes for TCP — re-dialed to localhost |
| Outbound from host apps (KOReader, Syncthing) | Transparent | Only through the local proxy |
| Tailscale SSH (`:22`) | Yes | Yes |
| Exit-node routing | All traffic | Only traffic through the proxy |
| Subnet routes | All traffic | Only traffic through the proxy |
| Local proxy (`1055`/`1056`) | Optional | Required |

## Inbound

In kernel TUN mode the device looks like any other tailnet node: connect to its
Tailscale IP and port and you reach the listening process.

In userspace mode `tailscaled` still accepts inbound TCP on the tailnet and
re-dials `127.0.0.1:<the same port>` as an ordinary local client, so a service
listening on the device is reachable but sees the connection from localhost. UDP
is not forwarded. Tailscale SSH is served inside `tailscaled` in both modes.

## Outbound

Kernel TUN mode is transparent; no proxy setting is involved.

In userspace mode, point clients at the local proxy that `tailscaled` exposes:

| Proxy | Address |
| --- | --- |
| SOCKS5 | `127.0.0.1:1055` |
| HTTP | `127.0.0.1:1056` |

Plugin config → **Automatically configure HTTP proxy** sets KOReader's proxy to
`http://127.0.0.1:1056` when the device connects and restores the previous value
on disconnect or uninstall. Programs you run from a shell do not pick that up on
their own; pass the proxy explicitly (`curl -x http://127.0.0.1:1056 …`).

HTTPS through KOReader's HTTP proxy is affected by an upstream KOReader bug,
[koreader/koreader#14693](https://github.com/koreader/koreader/issues/14693).

## Tailscale SSH

**Enable Tailscale SSH** (`tailscale_ssh`, off by default) passes `--ssh`.
`tailscaled` serves SSH on port `22` of the device's tailnet address, governed by
your tailnet ACLs. It works in userspace mode as well as kernel TUN, and host keys
are generated under `<state dir>/ssh/`, so no rootfs writes are needed.

This is independent of KOReader's own SSH server, which listens on `2222`. Both can
run at once.

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
LAN address while Tailscale is connected. Applies on the next connect.

## State and logs

Node state is private, root-owned, and kept off the storage that USB mass storage
exports:

| Device | State directory |
| --- | --- |
| Kindle | `/var/local/koreader-tailscale` |
| Kobo | `/usr/local/koreader-tailscale` |
| Others | `/var/lib/koreader-tailscale` |

If none of those can be made private and persistent, the plugin falls back to
`/tmp/tailscale` and copies state back to the plugin's `bin/` directory on a clean
stop; that state does not survive a reboot.

Files in the state directory:

| File | Contents |
| --- | --- |
| `tailscaled.state` | Node keys and identity |
| `tailscaled.log.conf` | Tailscale's log settings |
| `ssh/` | Tailscale SSH host keys, when that setting is on |
| `tailscaled.log`, `tailscale.log` | Daemon and client logs |

Logs live in the state directory rather than the USB-exported plugin directory
because they can contain the interactive login URL.
