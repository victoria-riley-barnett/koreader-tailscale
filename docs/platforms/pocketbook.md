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

The plugin checks network availability with a TCP connection, which works
without root privileges. Some PocketBook firmware versions do not allow
KOReader's user account to run `ping`.

Networking mode is selected based on the device's available TUN support. If
userspace mode is selected, configure KOReader's HTTP proxy as described in the
README. You can also enable **Force userspace mode** in Plugin config if kernel
TUN is unstable.
