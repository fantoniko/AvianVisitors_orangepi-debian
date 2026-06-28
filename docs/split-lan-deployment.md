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

sudo bash platforms/deploy.sh orange-pi --allow-from 192.168.1.8
```

Replace `192.168.1.8` with the web host IP address. The wrapper calls the
Orange Pi installer with the LAN bind and, when `ufw` is active, adds the
matching source-limited firewall rule.

Then verify from the web host:

```sh
curl 'http://orange-pi.local:8079/avian/api/birdnet-api.php?action=stats'
```

Use the Orange Pi host name or a static LAN IP if mDNS names are unreliable.

If the Orange Pi has a firewall, allow only the web host to reach TCP 8079. For
example, if the web host is `192.168.1.8`:

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
- Admin/control endpoints are not proxied by this mode. Use the Orange Pi URL
  directly for service restarts and BirdNET configuration changes.

## Safety notes

- Do not mount `birds.db` over SMB/NFS/sshfs for live reads.
- Keep the Orange Pi API limited to your LAN or protect `/avian/api/*` with
  authentication if it is exposed through a tunnel.
- Do not point `AV_BIRDNET_API_BASE` back at the same web host; it should point
  at the Orange Pi API.
