# Kobo

## Installation

Copy `tailscale.koplugin` to:

```text
/mnt/onboard/.adds/koreader/plugins/
```

For auth-key sign-in, place the key at:

```text
/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key
```

The plugin's TLS setup checks KOReader's CA bundle at:

```text
/mnt/onboard/.adds/koreader/data/ca-bundle.crt
```

## Networking

Networking mode is selected based on the device's available TUN support. If
userspace mode is selected, configure KOReader's HTTP proxy as described in the
README. You can also enable **Force userspace mode** in Plugin config if kernel
TUN is unstable.
