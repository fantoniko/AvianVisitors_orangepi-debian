# Split LAN deployment

This mode keeps the microphone and BirdNET-Pi database on the Orange Pi, while
the AvianVisitors web UI and generated image assets run on another computer in
the same local network.

## Layout

```text
Orange Pi Zero 3
  BirdNET-Pi recording and analysis
  ~/BirdNET-Pi/scripts/birds.db
  /avian/api/birdnet-api.php, recording.php, spectrogram.php

LAN web host
  AvianVisitors frontend
  bundled bird images and generated image cache
  PHP endpoints that proxy read-only BirdNET data/media to the Orange Pi
```

The web host does not read SQLite over a network filesystem. It calls the
Orange Pi over HTTP instead, which avoids SQLite locking problems and keeps
database ownership on the machine that writes it.

## Before you start

Use the same Git branch on both machines. The Orange Pi Zero 3 installer lives
on the `orange-pi-zero-3-debian` branch of this fork. If you clone upstream or a
default branch, the `platforms/` directory may be missing.

Replace the examples below with your real names:

```text
Orange Pi host: orange-pi.local
Orange Pi API:  http://orange-pi.local:8079/avian/api
Web host URL:   http://web-pc.local:8080/
```

If mDNS names are unreliable, use static LAN IP addresses instead.

## Orange Pi

Install BirdNET-Pi and AvianVisitors normally on the Orange Pi. The API must be
reachable from the LAN web host. On the Orange Pi Zero 3 installer, bind the web
service to a LAN address instead of loopback-only:

```sh
git clone --branch orange-pi-zero-3-debian \
  https://github.com/fantoniko/AvianVisitors_orangepi-debian.git \
  ~/AvianVisitors
cd ~/AvianVisitors

bash platforms/orange-pi-zero-3/preflight.sh

sudo bash platforms/deploy.sh orange-pi
```

The wrapper calls the Orange Pi installer with the LAN bind
`0.0.0.0:8079`.

Then verify from the web host:

```sh
curl 'http://orange-pi.local:8079/avian/api/birdnet-api.php?action=stats'
```

Use the Orange Pi host name or a static LAN IP if mDNS names are unreliable.

If the Orange Pi has a firewall, allow the web host to reach TCP 8079 using
your firewall tool. For example, with `ufw` and a web host at `192.168.1.8`:

```sh
sudo ufw allow from 192.168.1.8 to any port 8079 proto tcp comment 'AvianVisitors API from web host'
sudo ufw status verbose
```

Use a subnet rule only when every LAN client should be able to call the API:

```sh
sudo ufw allow from 192.168.1.0/24 to any port 8079 proto tcp comment 'AvianVisitors API LAN'
```

## Web host install

On the Debian/Ubuntu web host, clone the same branch and run the split web host
installer:

```sh
sudo install -d -o "$USER" -g "$USER" /opt/avian-visitors
git clone --branch orange-pi-zero-3-debian \
  https://github.com/fantoniko/AvianVisitors_orangepi-debian.git \
  /opt/avian-visitors/src
cd /opt/avian-visitors/src

sudo bash platforms/deploy.sh web-host --orange-pi-host orange-pi.local
```

Use the Orange Pi IP address instead of `orange-pi.local` if mDNS names are
unreliable. The installer handles:

- installing `caddy`, `php-fpm`, `php-curl`, and `php-sqlite3`;
- creating `/srv/avian-visitors`;
- linking frontend files and `avian/api`;
- creating the dedicated PHP-FPM pool;
- setting `AV_BIRDNET_API_BASE`;
- importing `/etc/caddy/Caddyfile.avian-visitors-web`;
- validating and reloading Caddy.

Preview without changing the host:

```sh
sudo bash platforms/deploy.sh web-host \
  --orange-pi-host orange-pi.local \
  --dry-run
```

The lower-level installers remain available when you need custom paths or
advanced flags:

```sh
sudo bash platforms/orange-pi-zero-3/install.sh --help
sudo bash platforms/split-web-host/install.sh --help
```

If the web host is managed through Docker or Portainer, use the alternative
stack in [`platforms/split-web-host/docker/`](../platforms/split-web-host/docker/)
instead of this systemd installer. The Docker stack keeps Caddy, PHP-FPM, and
the automatic image worker inside containers while still talking to the same
Orange Pi API.

## Automatic illustration generation

The web host can also run the image pipeline automatically. This watches recent
BirdNET detections through the web-host API, renders only missing species with
OpenClaw, removes the flat generated background, rebuilds masks, and bumps the
frontend cache versions when masks changed.

Keep the OpenClaw credentials in the project, not globally:

```sh
cd /opt/avian-visitors/src
touch .env.openclaw
chmod 600 .env.openclaw
nano .env.openclaw
```

Example:

```sh
OPENCLAW_BASE_URL=http://oc.lc:8088
OPENCLAW_API_KEY=your-token
OPENCLAW_MODEL=openclaw-image
```

Then rerun the web-host deploy with the worker enabled:

```sh
cd /opt/avian-visitors/src
git pull
sudo bash platforms/deploy.sh web-host \
  --orange-pi-host orange-pi.local \
  --enable-image-worker
```

This creates `.venv-cutout`, installs the Python image dependencies there, and
enables:

```text
avian-visitors-image-worker.timer
avian-visitors-image-worker.service
```

Useful checks:

```sh
systemctl status avian-visitors-image-worker.timer --no-pager
systemctl list-timers avian-visitors-image-worker.timer --no-pager
sudo systemctl start avian-visitors-image-worker.service
journalctl -u avian-visitors-image-worker.service -n 120 --no-pager
```

By default the timer runs about once per hour, looks at the last 24 hours, and
generates up to 20 missing perched illustrations per run. Tune it during
install if needed:

```sh
sudo bash platforms/deploy.sh web-host \
  --orange-pi-host orange-pi.local \
  --enable-image-worker \
  --image-worker-interval 2h \
  --image-worker-hours 48 \
  --image-worker-limit 10 \
  --image-worker-size 1536x1024
```

The image worker defaults to the lighter `u2netp` model. To make that choice
explicit during installation:

```sh
sudo bash platforms/deploy.sh web-host \
  --orange-pi-host orange-pi.local \
  --enable-image-worker \
  --image-worker-cutout-model u2netp
```

Disable only the automatic image worker:

```sh
sudo systemctl disable --now avian-visitors-image-worker.timer
```

## Web host smoke tests

The web host should proxy BirdNET data from the Orange Pi:

```text
http://web-pc.local:8080/avian/api/birdnet-api.php?action=stats
```

Or from the web host shell:

```sh
curl -v --connect-timeout 3 --max-time 8 \
  'http://orange-pi.local:8079/avian/api/birdnet-api.php?action=stats'
curl 'http://127.0.0.1:8080/avian/api/birdnet-api.php?action=stats'
curl 'http://127.0.0.1:8080/avian/api/birdnet-api.php?action=recent&hours=24'
```

Then open:

```text
http://web-pc.local:8080/
```

With that variable present, these local endpoints become transparent read-only
proxies to the Orange Pi:

- `avian/api/birdnet-api.php`
- `avian/api/recording.php`
- `avian/api/spectrogram.php`

Caddy also proxies the continuous live-audio route directly, without passing
the unbounded response through PHP:

- `/stream` -> the Orange Pi origin's `/stream`

Verify it from the web host. A healthy stream returns `HTTP 200`,
`Content-Type: audio/mpeg`, and then keeps the request open:

```sh
curl --max-time 5 -D - 'http://127.0.0.1:8080/stream' -o /dev/null
```

This requires `icecast2.service` and `livestream.service` to be active on the
Orange Pi. Keep Icecast bound to loopback; the Orange Pi Caddy exposes its
`/stream` route on port 8079.

The browser still talks to the web host using same-origin URLs, so no CORS
configuration is needed. Bundled bird illustrations and cutouts are still
served locally by the web host.

## Testing without a microphone

You can seed a few temporary rows on the Orange Pi to prove that the split web
host sees live BirdNET data before a USB microphone is attached:

```sh
sudo -u avianvisitors mkdir -p /home/avianvisitors/BirdNET-Pi/scripts
sudo cp -a /home/avianvisitors/BirdNET-Pi/scripts/birds.db \
  "/home/avianvisitors/BirdNET-Pi/scripts/birds.db.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

sudo -u avianvisitors sqlite3 /home/avianvisitors/BirdNET-Pi/scripts/birds.db <<'SQL'
CREATE TABLE IF NOT EXISTS detections (
  Date TEXT,
  Time TEXT,
  Sci_Name TEXT,
  Com_Name TEXT,
  Confidence REAL,
  File_Name TEXT
);

INSERT INTO detections (Date, Time, Sci_Name, Com_Name, Confidence, File_Name) VALUES
  (DATE('now','localtime'), TIME('now','localtime'), 'Parus major', 'Great Tit', 0.91, 'test-great-tit.mp3'),
  (DATE('now','localtime'), TIME('now','localtime'), 'Turdus merula', 'Eurasian Blackbird', 0.88, 'test-blackbird.mp3'),
  (DATE('now','localtime'), TIME('now','localtime'), 'Cyanistes caeruleus', 'Eurasian Blue Tit', 0.86, 'test-blue-tit.mp3');
SQL
```

Then verify from the web host:

```sh
curl 'http://web-pc.local:8080/avian/api/birdnet-api.php?action=stats'
curl 'http://web-pc.local:8080/avian/api/birdnet-api.php?action=recent&hours=24'
```

Keep the backup until real detections are flowing.

## Updating both machines

After pushing a new commit:

```sh
# Orange Pi
cd ~/AvianVisitors
git pull
sudo systemctl reload caddy

# Web host
cd /opt/avian-visitors/src
git pull
sudo systemctl reload caddy
```

If PHP proxy files changed, restart PHP-FPM on the web host:

```sh
sudo systemctl restart php*-fpm
```

## Web host uninstall

```sh
cd /opt/avian-visitors/src
sudo bash platforms/split-web-host/uninstall.sh
```

This removes the Caddy import, PHP-FPM pool, and `/srv/avian-visitors`. It does
not remove the source checkout under `/opt/avian-visitors/src`.

## What stays local

- The live BirdNET database stays on the Orange Pi.
- Audio recordings and BirdNET-generated spectrogram PNGs stay on the Orange Pi.
- AvianVisitors bundled images, frontend files, and optional generated image
  cache stay on the web host.
- Admin/control endpoints are not proxied by this mode. The web-host menu hides
  `settings`, `system`, `logs`, and `tools` because those screens require local
  access to `birdnet.conf`, systemd, and the journal. Use the Orange Pi URL
  directly for service restarts, logs, diagnostics, and BirdNET configuration
  changes.

## Safety notes

- Do not mount `birds.db` over SMB/NFS/sshfs for live reads.
- Keep the Orange Pi API limited to your LAN or protect `/avian/api/*` with
  authentication if it is exposed through a tunnel.
- Do not point `AV_BIRDNET_API_BASE` back at the same web host; it should point
  at the Orange Pi API.
