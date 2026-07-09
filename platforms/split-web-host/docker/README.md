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
internal `/data/compose/...` directory. Generated illustrations, reference
photos, and worker runtime state live in separate fixed-name volumes so they
survive service updates and stack re-creation.

## Portainer stack

Use this compose path from the repo:

```text
portainer-compose.yaml
```

The nested `platforms/split-web-host/docker/compose.yaml` remains available for
local `docker compose` runs from this directory. Portainer should use the
root-level file because some Portainer versions intermittently fail to read
nested stack files during Git redeploys.

Set these environment variables in Portainer:

```sh
AV_WEB_PORT=8080
AV_BIRDNET_API_BASE=http://op3.lc:8079/avian/api
TZ=Europe/Moscow
OPENCLAW_BASE_URL=http://oc.lc:8088
OPENCLAW_API_KEY=your-token
OPENCLAW_MODEL=openclaw-image
AV_IMAGE_WORKER_INTERVAL_SECONDS=3600
AV_IMAGE_WORKER_START_DELAY_SECONDS=300
AV_IMAGE_WORKER_RUN_ON_START=1
AV_IMAGE_WORKER_STATE=/srv/app/avian/runtime/image-worker-state.json
AV_IMAGE_WORKER_FAILURE_COOLDOWN_SECONDS=86400
AV_IMAGE_WORKER_LIMIT=20
AV_IMAGE_WORKER_SIZE=1536x1024
AV_IMAGE_WORKER_CUTOUT_MODEL=birefnet-general
AV_IMAGE_WORKER_CUTOUT_RETRIES=1
AV_IMAGE_WORKER_CUTOUT_RETRY_DELAY=15
AV_IMAGE_WORKER_CHOWN=0
AV_ONNX_THREADS=2
MALLOC_ARENA_MAX=2
AV_HOST_UID=1000
AV_HOST_GID=1000
AV_ILLUSTRATIONS_VOLUME_NAME=avian-visitors-illustrations
AV_REFERENCES_VOLUME_NAME=avian-visitors-references
AV_CUTOUTS_VOLUME_NAME=avian-visitors-cutouts
AV_RUNTIME_VOLUME_NAME=avian-visitors-runtime
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
2. renders only missing perched and in-flight illustrations through OpenClaw;
3. runs `cutout.py` for generated non-transparent images;
4. runs `build_masks.py`;
5. bumps frontend cache versions if masks changed;
6. sleeps `AV_IMAGE_WORKER_INTERVAL_SECONDS`.

By default the worker waits `AV_IMAGE_WORKER_START_DELAY_SECONDS=300` before
the first run. This keeps ordinary Portainer redeploys from immediately
competing with image rebuilds and web/PHP startup. Set
`AV_IMAGE_WORKER_RUN_ON_START=0` if the worker should wait a full interval
before its first run after container start.

If rembg runs out of memory, switch to the lighter model:

```sh
AV_IMAGE_WORKER_CUTOUT_MODEL=u2netp
```

The worker does not recursively `chown` generated assets by default because the
app uses Docker volumes and recursive ownership fixes are expensive on large
image sets. Set `AV_IMAGE_WORKER_CHOWN=1` only if you need host UID/GID ownership
fixes for copied-out files.

Failed species are written to `AV_IMAGE_WORKER_STATE` and are not retried until
`AV_IMAGE_WORKER_FAILURE_COOLDOWN_SECONDS` has elapsed. This prevents one bad
OpenClaw/rembg failure from consuming every worker cycle.

Inspect worker state:

```sh
docker exec avian-birds-web-host-avian-worker-1 \
  sh -lc 'cat /srv/app/avian/runtime/image-worker-state.json'
```

Container health:

```sh
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep avian
```

Expected steady state:

- `avian-app-init`: exited `0`;
- `avian-web`: running and healthy;
- `avian-php`: running and healthy;
- `avian-worker`: running and healthy.

## Updating the stack

When Portainer redeploys the stack, `avian-app-init` refreshes the `avian-app`
volume from the current Git revision. Generated `avian/assets/illustrations/`
PNGs, cached `avian/assets/references/`, legacy `avian/assets/cutouts/`, and
`avian/runtime/` state are mounted from fixed-name volumes and are preserved
across updates. On the first deploy after enabling these volumes,
`avian-app-init` migrates matching files from an older all-in-one `avian-app`
layout, then clears that legacy checkout. This avoids repeated copying of large
generated assets during normal redeploys.

New bundled files from Git are copied into their matching asset volume before
legacy files, so user-generated files keep precedence when names overlap.
Tracked files such as `apt.js` are refreshed from Git. If a preserved
transparent PNG is no longer present in `apt.js` after that refresh, the worker
rebuilds masks without re-running background removal.

## Stop only automatic generation

In Portainer, stop the `avian-worker` container, or locally:

```sh
docker compose stop avian-worker
```

The web UI can keep running without the worker.
