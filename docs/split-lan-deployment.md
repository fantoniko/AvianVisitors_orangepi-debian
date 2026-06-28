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

sudo ./platforms/orange-pi-zero-3/install.sh \
  --web-bind 0.0.0.0:8079 \
  --allow-external-web-bind
```

Then verify from the web host:

```sh
curl 'http://orange-pi.local:8079/avian/api/birdnet-api.php?action=stats'
```

Use the Orange Pi host name or a static LAN IP if mDNS names are unreliable.

If the Orange Pi has a firewall, allow only LAN clients to reach TCP 8079.

## Web host package setup

On a Debian/Ubuntu web host:

```sh
sudo apt update
sudo apt install -y caddy git php-fpm php-curl php-sqlite3
```

Clone the same branch:

```sh
sudo install -d -o "$USER" -g "$USER" /opt/avian-visitors
git clone --branch orange-pi-zero-3-debian \
  https://github.com/fantoniko/AvianVisitors_orangepi-debian.git \
  /opt/avian-visitors/src
cd /opt/avian-visitors/src
```

Create a web root that matches the normal BirdNET-Pi install layout. The
frontend files live at the web root, while `./avian/api/...` remains available
under the same origin:

```sh
sudo install -d -o root -g root /srv/avian-visitors
sudo ln -sfn /opt/avian-visitors/src/avian/frontend/index.html /srv/avian-visitors/index.html
sudo ln -sfn /opt/avian-visitors/src/avian/frontend/styles.css /srv/avian-visitors/styles.css
sudo ln -sfn /opt/avian-visitors/src/avian/frontend/apt.js /srv/avian-visitors/apt.js
sudo ln -sfn /opt/avian-visitors/src/avian/frontend/masks.json /srv/avian-visitors/masks.json
sudo ln -sfn /opt/avian-visitors/src/avian/frontend/dims.json /srv/avian-visitors/dims.json
sudo ln -sfn /opt/avian-visitors/src/avian /srv/avian-visitors/avian
sudo ln -sfn /opt/avian-visitors/src/avian/assets/favicon.png /srv/avian-visitors/favicon.png
sudo ln -sfn /opt/avian-visitors/src/avian/assets/favicon.png /srv/avian-visitors/favicon.ico
```

## Web host PHP-FPM

Find the installed PHP-FPM version:

```sh
php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION.PHP_EOL;'
```

Create `/etc/php/<version>/fpm/pool.d/avian-visitors-web.conf`:

```ini
[avian-visitors-web]
user = www-data
group = www-data
listen = /run/php/avian-visitors-web.sock
listen.owner = caddy
listen.group = caddy
listen.mode = 0660
pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 20s
chdir = /srv/avian-visitors
env[AV_BIRDNET_API_BASE] = http://orange-pi.local:8079/avian/api
```

Change `orange-pi.local` to the Orange Pi IP address if needed.

Reload PHP-FPM:

```sh
sudo systemctl restart php*-fpm
```

## Web host Caddy

Create `/etc/caddy/Caddyfile.avian-visitors-web`:

```caddyfile
http://0.0.0.0:8080 {
  root * /srv/avian-visitors
  php_fastcgi unix//run/php/avian-visitors-web.sock
  file_server
}
```

Import it from `/etc/caddy/Caddyfile`:

```caddyfile
import Caddyfile.avian-visitors-web
```

Validate and reload:

```sh
sudo caddy fmt --overwrite /etc/caddy/Caddyfile.avian-visitors-web
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

## Web host smoke tests

The web host should proxy BirdNET data from the Orange Pi:

```text
http://web-pc.local:8080/avian/api/birdnet-api.php?action=stats
```

Or from the web host shell:

```sh
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
