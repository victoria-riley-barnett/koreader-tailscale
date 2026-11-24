# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [1.4.1] — 2026-11-23

### Added

- **Enable Tailscale SSH** setting (`tailscale_ssh`, off by default), passing
  `--ssh`. Serves SSH on port 22 over the tailnet, works in userspace mode, and
  keeps host keys under `<state dir>/ssh/`.
- `docs/networking.md`: authoritative guide to networking modes, SSH, proxy
  ports, exit nodes, subnet routes, and state/log locations.
- A troubleshooting section and a networking support matrix in the README.
- Lua unit tests (`luajit tests/unit.lua`) to complement the shell tests.

### Changed

- Logs now live in the private state directory instead of the USB-exported plugin
  directory, since they can contain the login URL.
- README intro tightened, with CI and latest-release badges.

### Fixed

- Removed the startup connectivity preflight, which blocked PocketBook on networks
  that filter ICMP or public DNS.
- Dispatcher **Toggle Tailscale** action works again.
- The HTTP proxy is reconciled at launch and restored on uninstall or disconnect,
  instead of being left pointing at a dead `127.0.0.1:1056` after a crash.
- Login polling stops on disconnect and uninstall.
- USB mass-storage resume can no longer double-start the daemon.
- tmpfs state is never overwritten by an older copy in `bin/`.
- The status dialog falls back to `tailscale ip` when status JSON is malformed.
- Turning off **Automatically configure HTTP proxy** now restores KOReader's
  saved proxy immediately instead of leaving it pointed at `127.0.0.1:1056`.

## [1.4.0] — 2026-11-04

### Added

- **Accept subnet routes** toggle, on by default.
- CI, one-click release automation, and a weekly job that updates the pinned
  Tailscale version.
- Script tests (`sh tests/run.sh`) run against fake binaries.

### Changed

- Hardened binary installation, shell argument handling, and secret storage.
- README rewritten; device-specific setup moved into `docs/platforms/`.

### Fixed

- Automatically configured HTTP proxy was not applied at autostart.
- PocketBook connectivity check tried `ping` first, which fails without root on
  PocketBook; a TCP connect is now attempted first
  ([#51](https://github.com/victoria-riley-barnett/koreader-tailscale/issues/51)).
- Kindle TUN traffic was dropped by firewall chains with a DROP policy.
- tmpfs state is persisted after a successful startup.

## [1.3.0] — 2026-09-16

### Added

- Exit node support and automatic HTTP proxy configuration.
- Dispatcher action `toggle_tailscale_vpn`, so the toggle can be bound to a
  gesture or menu entry.
- Headscale auth-key support.
- Plugin directory derived from the module path instead of KOReader's default,
  which fixes installation on reMarkable.

### Changed

- Refactor moving networking decisions from shell into Lua.
- README rewritten in a plain tool-doc style.

### Fixed

- `readAuthKey` loop variable reassignment broke sign-in on Lua 5.4.
- Tailscale is stopped automatically when USB mass storage starts.
- Status crash, Wi-Fi hang, missing TUN fallback, and Headscale key handling
  ([#16](https://github.com/victoria-riley-barnett/koreader-tailscale/issues/16),
  [#25](https://github.com/victoria-riley-barnett/koreader-tailscale/issues/25),
  [#17](https://github.com/victoria-riley-barnett/koreader-tailscale/issues/17),
  [#20](https://github.com/victoria-riley-barnett/koreader-tailscale/issues/20)).
- Node state on FAT32 storage persisted on stop; tmpfs state cleaned on uninstall.
- Start failures are surfaced in the UI.

## [1.1.2] — 2026-03-20

### Fixed

- Forced userspace networking to fix a watchdog timeout on Reconfig
  ([#14](https://github.com/victoria-riley-barnett/koreader-tailscale/pull/14)).
