# Notes

Developer and contributor notes for tailscale.koplugin. User-facing documentation lives in [README.md](README.md).

## DESCRIPTION

The plugin installs and manages Tailscale on e-readers. It keeps the Tailscale binaries in a `bin/` directory it manages. On most devices this is `tailscale.koplugin/bin/`. On PocketBook the binaries go to `/mnt/ext1/tailscale/bin/`, because the plugin directory may sit on a read-only filesystem.

Config files (`auth.key`, `headscale.url`) live alongside the binaries. Logs (`tailscale.log`, `tailscaled.log`) live there too.

## ARCHITECTURE

Lua owns every decision. The relevant functions are `resolveStateDir`, `resolveTunFlag`, `readAuthKey`, `readHeadscaleUrl`, and `buildUpCommand`.

The shell scripts are thin executors. They receive everything via `TS_*` environment variables: `TS_BIN`, `TS_STATEDIR`, `TS_TUN_FLAG`, `TS_NETWORK_MODE`, `TS_UP_FLAGS`, `TS_LOGIN_SERVER`, `TS_AUTH_KEY`. They make no decisions of their own.

There is no `start_tailscale_headscale.sh`. Headscale is selected by the presence of `headscale.url`.

## STATE DIRECTORY

The plugin resolves the state directory with a `chmod` test on the `bin/` directory.

- If `chmod` succeeds (ext4, for example Kobo), state stays in `bin/`.
- If `chmod` fails (FAT32, for example Kindle), state goes to `/tmp/tailscale` on tmpfs.

Existing state is copied into the tmpfs directory at start. State is synced back to `bin/` on stop. Identity survives reboots.

## NETWORKING

The plugin uses kernel TUN (`--tun=tailscale0`) when `/dev/net/tun` is a readable and writable character device. Kernel mode provides transparent routing for KOReader features such as progress sync, OPDS, and other plugins.

When TUN is unavailable, the plugin falls back to `--tun=userspace-networking`. Outbound connections can then use the SOCKS5/HTTP CONNECT listeners.

An empty `bin/force-userspace` file forces userspace mode. The selected mode is written at the top of `tailscaled.log`.

## BUGS

Some constrained e-reader kernels expose an unstable TUN driver. Kernel TUN can trigger `wgengine: watchdog timeout on Reconfig`, observed on the Kobo Sage. Create the `bin/force-userspace` file to avoid it.

## LOOPBACK

Some firmware (Kobo, PocketBook) does not configure `lo` at boot. The start script detects whether `127.0.0.1` is present and brings up loopback with `ifconfig`, falling back to `ip`. Loopback is required for the SOCKS5/HTTP proxy listeners to bind.

## PROXY LISTENERS

The daemon runs with two listeners:

- SOCKS5 proxy: `127.0.0.1:1055`
- HTTP CONNECT proxy: `127.0.0.1:1056`

## USB MASS STORAGE

The plugin hooks `UIManager:quit` exit code 86 (`KO_RC_USBMS`). It stops `tailscaled` before KOReader enters USB storage mode. It leaves a restart marker file and restarts on the next plugin init.

`stop_tailscale.sh` waits for `tailscaled` to actually exit. It loops on `pgrep` and falls back to SIGKILL. This keeps the filesystem free for the USB connection.

If the device is killed without a clean stop, the node re-registers via `auth.key` on the next start.

## SCRIPTS

All scripts are POSIX sh (busybox). Each accepts the tailscale directory as `$1` or `$TS_DIR`. The default is `/mnt/us/tailscale`.

- `install-tailscale.sh` — fetches the stable version from pkgs.tailscale.com. It parses the `TarballsVersion` field from the JSON index and falls back to the pinned `TS_FALLBACK_VER`. It skips the install if the installed version matches.
- `start_tailscale.sh` — stops old instances, starts `tailscaled`, and runs `tailscale up`.
- `stop_tailscale.sh` — runs `tailscale down`, cleans up, and kills the daemon.
- `uninstall-tailscale.sh` — stops the daemon and removes binaries, config, and state.

## MANUAL INSTALLATION

If `Install/Update Tailscale` fails (no WiFi, slow connection), install by hand.

On your computer, fetch the archive for the device architecture:

```sh
wget https://pkgs.tailscale.com/stable/tailscale_1.96.2_arm.tgz
```

Transfer the archive to the device. Then, on the device:

```sh
cd /<path-to-plugin>/tailscale.koplugin/bin
tar xzf tailscale_1.96.2_arm.tgz
mv tailscale_*/tailscale tailscale_*/tailscaled ./
rm -rf tailscale_*
chmod +x tailscale tailscaled
```

Then create `auth.key` and start from the plugin menu.

## TESTS

- `test.sh` — static checks.
- `test/suite.sh` — test suite.
- `test/deploy.sh` — deployment tests.

## RELEASING

Push a `vX.Y.Z` tag. The GitHub Actions workflow in `.github/workflows/release.yml` verifies the tag matches `_meta.lua`, builds the zip, and publishes the GitHub release. The tag, plugin version, and release artifact stay in sync by construction.

## SEE ALSO

- [README.md](README.md) — user documentation
- `main.lua` — plugin entry point
- `bin/` — device scripts
- `.github/workflows/release.yml` — release pipeline
