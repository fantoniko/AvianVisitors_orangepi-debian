from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOCKER = ROOT / "platforms" / "split-web-host" / "docker"


def read(name: str) -> str:
    return (DOCKER / name).read_text(encoding="utf-8")


def test_caddy_compresses_and_keeps_php_private():
    source = read("Caddyfile")
    assert "encode zstd gzip" in source
    assert "php_fastcgi avian-php:9000" in source
    assert "handle /avian/api/*.php" in source
    assert "9000:" not in (ROOT / "portainer-compose.yaml").read_text(encoding="utf-8")


def test_caddy_caches_versioned_mask_manifests():
    source = read("Caddyfile")
    assert "@maskManifests path /dims.json /masks.json" in source
    assert 'header @maskManifests Cache-Control "public, max-age=31536000, immutable"' in source


def test_caddy_spa_fallback_does_not_capture_api_or_assets():
    source = read("Caddyfile")
    api = source.index("handle /avian/api/*.php")
    assets = source.index("handle /avian/*")
    fallback = source.index("try_files {path} /index.html")
    assert api < fallback
    assert assets < fallback


def test_docker_build_contexts_are_narrow():
    assert read("web.Dockerfile.dockerignore").splitlines()[0] == "*"
    assert read("php.Dockerfile.dockerignore").strip() == "*"

    worker_ignore = read("worker.Dockerfile.dockerignore")
    assert worker_ignore.startswith("*\n")
    assert "!avian/scripts/requirements.txt" in worker_ignore
    assert "!avian/assets/" not in worker_ignore

    app_ignore = read("app.Dockerfile.dockerignore")
    assert app_ignore.startswith("*\n")
    assert "!avian/**" in app_ignore


def test_worker_runtime_bounds_native_thread_pools():
    source = read("worker-loop.sh")
    for variable in (
        "OMP_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "MKL_NUM_THREADS",
        "NUMEXPR_NUM_THREADS",
        "MALLOC_ARENA_MAX",
    ):
        assert f"export {variable}=" in source


def test_php_image_is_small_and_fpm_releases_idle_workers():
    source = read("php.Dockerfile")
    assert "FROM php:8.3-fpm-alpine" in source
    assert "php.ini-production" in source
    assert "pm = ondemand" in source
    assert "pm.max_children = 2" in source
    assert "pm.process_idle_timeout = 10s" in source
    assert "pm.max_requests = 500" in source
    assert "apt-get" not in source
    assert "docker-php-ext-install" not in source
