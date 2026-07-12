# Split web host installer

This installer prepares a Debian/Ubuntu LAN web host for AvianVisitors while
BirdNET-Pi keeps running on an Orange Pi.

It installs Caddy/PHP packages, creates the AvianVisitors web root, links the
frontend and `avian/api`, configures a dedicated PHP-FPM pool with
`AV_BIRDNET_API_BASE`, and imports a Caddy site.

## Install

```sh
git clone --branch orange-pi-zero-3-debian \
  https://github.com/fantoniko/AvianVisitors_orangepi-debian.git \
  /opt/avian-visitors/src

cd /opt/avian-visitors/src

sudo bash platforms/split-web-host/install.sh \
  --birdnet-api-base http://orange-pi.local:8079/avian/api
```

The default web URL is:

```text
http://127.0.0.1:8080/
```

Expose it on the LAN:

```sh
sudo bash platforms/split-web-host/install.sh \
  --birdnet-api-base http://orange-pi.local:8079/avian/api \
  --web-bind 0.0.0.0:8080 \
  --allow-external-web-bind
```

Install the optional illustration worker with its default quiet-night schedule
(work is allowed from 08:00 until 22:00 local time):

```sh
sudo bash platforms/split-web-host/install.sh \
  --birdnet-api-base http://orange-pi.local:8079/avian/api \
  --enable-image-worker
```

Choose another daytime window with `--image-worker-active-start HH:MM` and
`--image-worker-active-end HH:MM`. The worker checks the window between image
requests and cutouts, so remaining work is safely deferred rather than started
at night.

## Verify

```sh
curl 'http://127.0.0.1:8080/avian/api/birdnet-api.php?action=stats'
```

## Uninstall

```sh
sudo bash platforms/split-web-host/uninstall.sh
```

The uninstall keeps the source checkout under `/opt/avian-visitors/src` unless
you delete it yourself.
