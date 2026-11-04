# Kindle

## Installation

Copy `tailscale.koplugin` to:

```text
/mnt/us/koreader/plugins/
```

For auth-key sign-in, place the key at:

```text
/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key
```

The plugin's TLS setup checks KOReader's CA bundle at:

```text
/mnt/us/koreader/data/ca-bundle.crt
```

## Networking

Networking mode is selected automatically for each device. On Kindle models
using kernel TUN, the plugin allows `tailscale0` traffic through firewall
chains whose default policy is DROP. Other models may use userspace networking;
in that mode, configure KOReader's HTTP proxy as described in the README.
