# Docker split web host

This is an alternative to the systemd/Caddy/PHP-FPM web-host installer. It is
intended for a LAN Docker host managed by Portainer.

The Orange Pi still records audio, runs BirdNET, owns SQLite, and exposes:

```text
http://op3.lc:8079/avian/api
```

The Docker host runs:

- `avian-web`: Caddy with the frontend and API routing files baked into its
  image, exposed on `AV_WEB_PORT` (default `8080`);
- `avian-php`: PHP-FPM with the API code baked into its image;
- `avian-worker`: periodic OpenClaw generation, background removal, and mask
  preparation.

Application code is immutable and lives in the service images. It is neither
bind-mounted from Portainer's internal `/data/compose/...` directory nor copied
through a shared application volume. Generated illustrations, reference photos,
cutouts, model data, and worker runtime state live in separate fixed-name
volumes so they survive service updates and stack re-creation.

For Portainer, the root stack pulls prebuilt multi-architecture images from
GitHub Container Registry instead of building them on the web host. The nested
compose file remains build-based for local development.

## Portainer stack

Use this compose path from the repo:

```text
portainer-compose.yaml
```

The nested `platforms/split-web-host/docker/compose.yaml` remains available for
local `docker compose` runs from this directory. Portainer should use the
root-level file because some Portainer versions intermittently fail to read
nested stack files during Git redeploys.

The `web-deploy` branch is generated automatically after matching source
changes. It contains only the Portainer stack file, license, and source commit
marker, keeping Portainer's Git checkout small. Application code and Docker
configuration are already inside the GHCR images. The workflow first pushes
the matching images and only then updates `web-deploy`.

If the GHCR packages are private, add a Portainer registry credential for
`ghcr.io` with a GitHub token that has `read:packages`, then select it for this
stack. Public packages need no registry credential.

Set these environment variables in Portainer:

```sh
AV_WEB_PORT=8080
AV_BIRDNET_API_BASE=http://op3.lc:8079/avian/api
AV_IMAGE_REGISTRY=ghcr.io/fantoniko
AV_IMAGE_TAG=web-deploy
TZ=Europe/Moscow
OPENCLAW_BASE_URL=http://oc.lc:8088
OPENCLAW_API_KEY=your-token
OPENCLAW_MODEL=openclaw-image
AV_IMAGE_WORKER_INTERVAL_SECONDS=3600
AV_IMAGE_WORKER_START_DELAY_SECONDS=300
AV_IMAGE_WORKER_RUN_ON_START=1
AV_IMAGE_WORKER_ACTIVE_START=08:00
AV_IMAGE_WORKER_ACTIVE_END=22:00
AV_IMAGE_WORKER_STATE=/srv/app/avian/runtime/image-worker-state.json
AV_IMAGE_WORKER_FAILURE_COOLDOWN_SECONDS=86400
AV_IMAGE_WORKER_LIMIT=20
AV_IMAGE_WORKER_SIZE=1536x1024
AV_IMAGE_WORKER_CUTOUT_MODEL=u2netp
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

The web container derives `http://op3.lc:8079` from
`AV_BIRDNET_API_BASE` and proxies `/stream` to the Orange Pi with streaming
flush enabled. No second host variable is required.

`AV_HOST_UID` and `AV_HOST_GID` are only used when
`AV_IMAGE_WORKER_CHOWN=1`. For that optional mode, set them to the desired
Linux owner of exported generated files:

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
curl --max-time 5 -D - 'http://hs.lc:8080/stream' -o /dev/null
docker compose logs -f avian-worker
```

## Worker behavior

The worker loops forever. Each run:

1. reads recent species from `AV_RECENT_API_URL` or the internal web URL;
2. renders only missing perched and in-flight illustrations through OpenClaw;
3. runs `cutout.py` for generated non-transparent images;
4. stores transparent PNGs in the persistent illustrations volume;
5. sleeps `AV_IMAGE_WORKER_INTERVAL_SECONDS`.

The worker does not modify frontend JavaScript or bundled mask manifests.
Those files belong to the immutable web image. For a newly generated PNG, the
browser derives the alpha mask at runtime; bundled `dims.json` and `masks.json`
can still be refreshed during a later source release with `build_masks.py`.

By default the worker waits `AV_IMAGE_WORKER_START_DELAY_SECONDS=300` before
the first run. This keeps ordinary Portainer redeploys from immediately
competing with image rebuilds and web/PHP startup. Set
`AV_IMAGE_WORKER_RUN_ON_START=0` if the worker should wait a full interval
before its first run after container start.

Expensive generation and cutout work is restricted to local time
`AV_IMAGE_WORKER_ACTIVE_START=08:00` through
`AV_IMAGE_WORKER_ACTIVE_END=22:00` (the container uses `TZ`, normally
`Europe/Moscow`). The window is checked before a run and between image requests
and cutouts, so unfinished work is deferred to the next daytime cycle. Set both
values equal (for example `00:00`) to allow work around the clock. An overnight
window such as `22:00`-`06:00` is also supported.

The worker defaults to the memory-friendly model:

```sh
AV_IMAGE_WORKER_CUTOUT_MODEL=u2netp
```

For potentially finer edges on a host with plenty of spare RAM, opt into
`birefnet-general`. It can create large transient memory and swap spikes.

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

- `avian-web`: running and healthy;
- `avian-php`: running and healthy;
- `avian-worker`: running and healthy.

## Updating the stack

Portainer pulls new immutable web, PHP, and worker images. Generated
`avian/assets/illustrations/` PNGs, cached `avian/assets/references/`,
`avian/assets/cutouts/`, model files, and `avian/runtime/` state remain in their
fixed-name volumes and are preserved across updates.

The PHP and worker containers mount only the persistent volumes they use under
`/srv/generated`. Their images contain application-facing symlinks such as
`/srv/app/avian/assets/illustrations -> /srv/generated/illustrations`. Keeping
the mounts outside `/srv/app` prevents a code refresh from replacing or
detaching an asset mount.

The obsolete stack-local `avian-app` volume is no longer used. After the first
successful deployment and after verifying that old generated files are present
in the fixed-name volumes, it may be removed manually. Do not remove the named
`avian-visitors-illustrations`, `avian-visitors-references`,
`avian-visitors-cutouts`, `avian-visitors-runtime`, or U2Net volumes.

## Stop only automatic generation

In Portainer, stop the `avian-worker` container, or locally:

```sh
docker compose stop avian-worker
```

The web UI can keep running without the worker.
