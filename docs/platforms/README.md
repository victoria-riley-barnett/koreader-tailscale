# Platform notes

The plugin supports ARMv7 and ARM64 devices. It chooses kernel TUN when the
device provides a usable TUN device; otherwise, it uses userspace networking.
You can also turn on **Force userspace mode** in Plugin config if kernel TUN is
unstable on your device.

| Platform | KOReader plugin folder | Auth-key file |
| --- | --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` | `/mnt/us/koreader/plugins/tailscale.koplugin/bin/auth.key` |
| Kobo | `/mnt/onboard/.adds/koreader/plugins/` | `/mnt/onboard/.adds/koreader/plugins/tailscale.koplugin/bin/auth.key` |
| PocketBook | `/mnt/ext1/koreader/plugins/` | `/mnt/ext1/tailscale/bin/auth.key` |

These are platform-specific paths used by common setups. The plugin may be
installed in a different location if KOReader is configured to load plugins
from elsewhere.

## Taildrop

Files sent via Taildrop are saved automatically to a `taildrop` folder inside
KOReader's home folder — `/mnt/us/taildrop` on Kindle, `/mnt/onboard/taildrop`
on Kobo, `/mnt/ext1/taildrop` on PocketBook (separate from the Tailscale
binaries, which live under `/mnt/ext1/tailscale/`). If KOReader's home folder
has been changed from the device default (file manager → long-press a folder
→ "Set as home folder"), `taildrop` follows it there instead.

## Networking

With kernel TUN, KOReader can reach tailnet services directly. In userspace
mode, configure KOReader's HTTP proxy as described in the README; exit-node
routing then applies only to traffic sent through that proxy.

The plugin picks a mode based on the device's capabilities, not its name, so
different models in the same product family may behave differently. The
platform pages record known setup and networking differences:

- [Kindle](kindle.md)
- [Kobo](kobo.md)
- [PocketBook](pocketbook.md)

## Device state and TLS certificates

On devices whose plugin files are stored on USB-accessible storage, the plugin
keeps Tailscale's node state in a private persistent location when one is
available. If not, it falls back to temporary storage and preserves state
across a normal stop. This is automatic.

The plugin also uses KOReader's CA bundle for TLS when it can find one. The
known Kindle and Kobo locations are listed on their platform pages. These are
troubleshooting details; most users do not need to configure either setting.
