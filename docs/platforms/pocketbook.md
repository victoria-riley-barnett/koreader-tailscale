# PocketBook

## Installation

Copy `tailscale.koplugin` to:

```text
/mnt/ext1/koreader/plugins/
```

Tailscale's binaries and auth-key file are stored separately from the plugin
at:

```text
/mnt/ext1/tailscale/bin/
```

Place an auth key at `/mnt/ext1/tailscale/bin/auth.key`.

## Networking

The plugin does not require a separate internet-connectivity probe before
starting Tailscale. `tailscaled` stays running and reconnects when connectivity
becomes available, including on networks that block public DNS servers or
ICMP.

Networking mode is selected based on the device's available TUN support. If
userspace mode is selected, configure KOReader's HTTP proxy as described in the
README. You can also enable **Force userspace mode** in Plugin config if kernel
TUN is unstable.
