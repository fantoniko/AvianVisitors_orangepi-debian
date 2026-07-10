# Orange Pi Zero 3 Debian installer

This platform variant is for Orange Pi Zero 3, Allwinner H618, aarch64 Debian,
USB audio capture through ALSA, and SSH-managed systems that may already run
other services.

It intentionally does not run the upstream Raspberry Pi installer. The upstream
path currently performs broad system changes such as `apt upgrade`, hostname and
TTY changes, gotty installation, and unrestricted sudo for the web server. This
variant installs a separate service-user based deployment and keeps system
changes scoped and reversible.

## Supported and unconfirmed

Supported target:

- Orange Pi Zero 3 / Allwinner H618.
- Debian aarch64 with systemd.
- Python 3.11, 3.12, or 3.13.
- USB microphone visible to ALSA.

Unconfirmed:

- Non-Debian distributions.
- PulseAudio or PipeWire capture.
- Raspberry Pi OS specific tooling.
- Hardware without `/dev/snd`.

## Preflight

Run this first. It only reads host state and writes a report if requested.

```bash
bash platforms/orange-pi-zero-3/preflight.sh --report /tmp/avian-preflight.json
```

It checks OS, architecture, kernel, Python, RAM, disk, filesystem, systemd, ALSA,
`arecord -l`, `arecord -L`, `/dev/snd` access, relevant packages, existing web
servers, listening ports, previous installations, network reachability, and
TFLite import compatibility.

## Install

Preview:

```bash
sudo bash platforms/orange-pi-zero-3/install.sh --dry-run
```

Install without starting services:

```bash
sudo bash platforms/orange-pi-zero-3/install.sh
```

Then edit:

```bash
sudoedit /etc/birdnet/birdnet.conf
```

Set at least:

- `REC_CARD` to a stable ALSA PCM from `arecord -L`, for example
  `hw:CARD=Device,DEV=0`.
- `LATITUDE` and `LONGITUDE`.
- Optional model, thresholds, notification, and web settings.

Start services after configuration:

```bash
sudo systemctl start birdnet-recording.service
sudo systemctl start birdnet-analysis.service
sudo systemctl start spectrogram-viewer.service
```

The default web listener is local only:

```text
http://127.0.0.1:8079
```

Expose it through an existing reverse proxy only after reviewing the generated
Caddy import at `/etc/caddy/Caddyfile.avian-visitors`.

Binding Caddy to a non-loopback address requires both `--web-bind` and
`--allow-external-web-bind`.

`livestream.service` is installed but not enabled automatically. Install and
configure Icecast deliberately before enabling it:

```bash
sudo apt-get install icecast2
```

## Audio test

```bash
bash platforms/orange-pi-zero-3/test-audio.sh
```

The script records a short WAV through ALSA and validates it with `ffprobe` or
`soxi` when available.

## Noise filtering

The original WAV is retained unchanged while it is analysed.  Optional settings
in `/etc/birdnet/birdnet.conf` apply a light, zero-phase high/low-pass filter
only in memory before BirdNET inference:

```ini
# Start with this only for wind or low-frequency electrical rumble.
ANALYSIS_HIGHPASS_HZ=180
ANALYSIS_LOWPASS_HZ=0
```

Leave either value at `0` to disable that cutoff. Do not use aggressive noise
reduction before recognition without comparing its false positives and missed
calls against raw recordings.

The extracted clips served by the web interface are a separate output. They
use `PLAYBACK_HIGHPASS_HZ=100` and `PLAYBACK_LOWPASS_HZ=16000` by default. For
strong, stable background noise, create a SoX profile from a quiet recording
and set its absolute path in `PLAYBACK_DENOISE_PROFILE`; `PLAYBACK_DENOISE_AMOUNT`
defaults to the deliberately gentle value `0.21`.

## Service checks

```bash
systemctl status birdnet-recording.service
systemctl status birdnet-analysis.service
journalctl -u birdnet-recording.service -u birdnet-analysis.service -n 100 --no-pager
```

## Web and sudo model

The web server is not granted unrestricted sudo. The installer writes only an
optional allowlist for starting one constrained template unit:

```text
/bin/systemctl start avian-visitors-admin-helper@*.service
```

Existing upstream web buttons that call `sudo systemctl ...` directly are
therefore disabled unless an administrator explicitly adds separate rules. Do
not add `caddy ALL=(ALL) NOPASSWD: ALL`.

The PHP API opens SQLite read-only where the upstream code already does so.
The local Caddy fragment also blocks bundled Adminer entry points so the local
database is not exposed through a write-capable database UI by default. The PHP
FPM pool runs as the dedicated service user and is bound to the local listener.

## Uninstall and rollback

Preview:

```bash
sudo bash platforms/orange-pi-zero-3/uninstall.sh --dry-run
```

Remove installed files and restore backups:

```bash
sudo bash platforms/orange-pi-zero-3/uninstall.sh
```

Recordings and the local database are kept by default. Delete them only with:

```bash
sudo bash platforms/orange-pi-zero-3/uninstall.sh --purge-data
```

Packages are not removed because they may have existed before this variant was
installed. Rollback restores backed-up configuration files from
`/var/backups/avian-visitors/...`; it is not a substitute for a full SD-card
image backup.

## Difference from the Raspberry Pi installer

This variant:

- Does not change hostname.
- Does not configure TTY autologin.
- Does not install gotty or a web terminal.
- Does not run `apt upgrade` or `dist-upgrade`.
- Does not assume Raspberry Pi OS, `raspi-config`, `vcgencmd`, or Pi paths.
- Uses ALSA directly and documents stable capture device selection.
- Writes manifest and backups for uninstall.
- Installs systemd units with absolute paths, a dedicated user, audio group
  access, restart policy, journal logging, and limited hardening.
