# Docker split web host

This is an alternative to the systemd/Caddy/PHP-FPM web-host installer. It is
intended for a LAN Docker host managed by Portainer.

The Orange Pi still records audio, runs BirdNET, owns SQLite, and exposes:

```text
http://op3.lc:8079/avian/api
```

The Docker host runs:

- `avian-app-init`: copies the Git checkout from the build context into the
  shared `avian-app` Docker volume;
- `avian-web`: Caddy, exposed on `AV_WEB_PORT` (default `8080`);
- `avian-php`: PHP-FPM for `/avian/api/*.php`;
- `avian-worker`: periodic OpenClaw generation, background removal, and mask
  rebuilds.

`avian-web` bakes the Caddyfile into its image. The repository checkout is
copied into a named Docker volume instead of bind-mounted from Portainer's
internal `/data/compose/...` directory. This avoids Portainer Git stack path
issues and lets the worker update generated assets in the same `/srv/app` tree
that Caddy and PHP read.

## Portainer stack

Use this compose path from the repo:

```text
platforms/split-web-host/docker/compose.yaml
```

Set these environment variables in Portainer:

```sh
AV_WEB_PORT=8080
AV_BIRDNET_API_BASE=http://op3.lc:8079/avian/api
OPENCLAW_BASE_URL=http://oc.lc:8088
OPENCLAW_API_KEY=your-token
OPENCLAW_MODEL=openclaw-image
AV_IMAGE_WORKER_INTERVAL_SECONDS=3600
AV_IMAGE_WORKER_LIMIT=20
AV_IMAGE_WORKER_SIZE=1536x1024
AV_IMAGE_WORKER_CUTOUT_MODEL=birefnet-general
AV_HOST_UID=1000
AV_HOST_GID=1000
```

Set `AV_HOST_UID` and `AV_HOST_GID` to the Linux owner of the checkout on the
Docker host. On the host:

```sh
id -u
id -g
```

## Local compose

From this directory:

```sh
cp .env.example .env
nano .env
docker compose up -d --build
```

Open:

```text
http://hs.lc:8080/
```

Smoke tests:

```sh
curl 'http://hs.lc:8080/avian/api/birdnet-api.php?action=stats'
curl 'http://hs.lc:8080/avian/api/birdnet-api.php?action=recent&hours=24'
docker compose logs -f avian-worker
```

## Worker behavior

The worker loops forever. Each run:

1. reads recent species from `AV_RECENT_API_URL` or the internal web URL;
2. renders only missing illustrations through OpenClaw;
3. runs `cutout.py` for generated non-transparent images;
4. runs `build_masks.py`;
5. bumps frontend cache versions if masks changed;
6. sleeps `AV_IMAGE_WORKER_INTERVAL_SECONDS`.

If rembg runs out of memory, switch to the lighter model:

```sh
AV_IMAGE_WORKER_CUTOUT_MODEL=u2netp
```

## Updating the stack

When Portainer redeploys the stack, `avian-app-init` refreshes the `avian-app`
volume from the current Git revision while preserving generated
`avian/assets/illustrations/` PNGs and cached `avian/assets/references/`.
New bundled files from Git remain in place; preserved runtime files are copied
back over them when names overlap.
Tracked files such as `apt.js` are refreshed from Git. If a preserved
transparent PNG is no longer present in `apt.js` after that refresh, the worker
rebuilds masks without re-running background removal.

## Stop only automatic generation

In Portainer, stop the `avian-worker` container, or locally:

```sh
docker compose stop avian-worker
```

The web UI can keep running without the worker.
