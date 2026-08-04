# Orange Pi Zero 3 Debian adaptation task log

## Analysis

Reviewed the entry installer and install scripts:

- `newinstaller.sh` clones the upstream branch, requires passwordless sudo, and
  reboots automatically after install.
- `scripts/install_birdnet.sh` delegates system setup to
  `scripts/install_services.sh`, creates the virtualenv, installs Python
  dependencies, and writes `/etc/timezone` when present.
- `scripts/install_services.sh` performs the major system changes: package
  installation, `apt upgrade`, hostname edits, TTY autologin, tmp.mount changes,
  Caddy/PHP/Icecast configuration, gotty web terminal setup, cron entries,
  service generation, and broad Caddy sudoers.
- Recording and livestream scripts can use ALSA directly when `REC_CARD` is set
  to a concrete ALSA PCM. The default config text still describes PulseAudio.
- Web controls issue direct `sudo systemctl`, reboot, shutdown, and data-delete
  commands. They require sudoers support to work; this variant does not grant it.
- `scripts/common.php` opens the SQLite database read-only in the common read
  path, which is compatible with a reduced web privilege model.

Main risks found:

- Full `apt upgrade` is not acceptable on an already used Debian host.
- Hostname, `/etc/hosts`, getty autologin, and web terminal changes assume the
  installer controls the machine.
- `caddy ALL=(ALL) NOPASSWD: ALL` gives the web server complete root command
  execution.
- Raspberry Pi assumptions are mixed into the legacy install path.
- Existing uninstall removes broad paths and packages/services derived from
  upstream script parsing rather than from an install manifest.

## Plan

1. Keep the upstream Raspberry Pi installer path unchanged.
2. Add `platforms/orange-pi-zero-3/` with a read-only preflight, safe install,
   safe uninstall, config templates, systemd templates, and audio test helper.
3. Use a dedicated service user with home-based layout so existing project code
   that expects `/home/$BIRDNET_USER/BirdNET-Pi` continues to work.
4. Require explicit ALSA device configuration through `/etc/birdnet/birdnet.conf`.
5. Install only missing packages and never run `apt upgrade` or `dist-upgrade`.
6. Bind the bundled Caddy configuration to localhost by default and document
   reverse proxy integration.
7. Use a constrained admin helper allowlist instead of full web-server sudo.
8. Write a manifest and backup map so uninstall removes only installed files and
   restores edited system configuration.
9. Add repository tests that guard the platform scripts against the forbidden
   operations.

## Critical review follow-up

Issues found and fixed after the first implementation:

- Existing non-empty `--prefix` directories were too easy to replace. The
  installer now refuses unmarked non-empty prefixes and writes a platform marker
  before any future managed removal.
- `uninstall.sh` sourced `install.env` as shell code. It now parses known keys
  only and rejects manifest or backup paths outside the managed roots.
- Rollback restored backups before deleting manifest files, which could remove
  restored configuration again. Uninstall now removes managed files first and
  restores backups last.
- The sudo helper used a wildcard systemd instance and targeted users that do
  not run PHP in this variant. It now grants the dedicated service user only an
  exact helper-command allowlist.
- `--web-bind` could bind a non-loopback address without a second explicit
  confirmation flag. Non-loopback binds now require `--allow-external-web-bind`.
- `livestream.service` was enabled even though this variant does not overwrite
  Icecast configuration. The unit is installed but not enabled or started
  automatically.
- Adminer was reachable through the local Caddy/PHP surface. The Caddy fragment
  now returns 403 for bundled Adminer paths so SQLite is not exposed through a
  write-capable database UI by default.
