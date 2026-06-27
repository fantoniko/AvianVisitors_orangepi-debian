from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLATFORM = ROOT / "platforms" / "orange-pi-zero-3"


def read(name: str) -> str:
    return (PLATFORM / name).read_text(encoding="utf-8")


def test_platform_files_exist():
    expected = [
        "README.md",
        "preflight.sh",
        "install.sh",
        "uninstall.sh",
        "test-audio.sh",
        "lib/common.sh",
        "lib/admin-helper.sh",
        "config/birdnet.conf.template",
        "config/caddy.loopback.Caddyfile.template",
        "systemd/birdnet-recording.service.in",
        "systemd/birdnet-analysis.service.in",
    ]
    for rel in expected:
        assert (PLATFORM / rel).is_file(), rel


def test_installer_avoids_forbidden_system_changes():
    combined = "\n".join(
        path.read_text(encoding="utf-8")
        for path in PLATFORM.rglob("*")
        if path.is_file() and path.suffix in {"", ".sh", ".template", ".in"}
    )
    forbidden = [
        "dist-upgrade",
        "apt-get upgrade",
        "apt upgrade",
        "hostnamectl set-hostname",
        "--autologin",
        "raspi-config",
        "vcgencmd",
        "NOPASSWD: ALL",
        "gotty",
        "pulseaudio --start",
    ]
    for token in forbidden:
        assert token not in combined


def test_preflight_is_read_only():
    preflight = read("preflight.sh")
    forbidden = [
        "sudo ",
        "apt-get install",
        "systemctl enable",
        "systemctl start",
        "rm -rf",
        "sed -i",
    ]
    for token in forbidden:
        assert token not in preflight


def test_uninstall_does_not_execute_manifest_env_as_shell():
    uninstall = read("uninstall.sh")
    assert '. "$MANIFEST_ROOT/install.env"' not in uninstall
    assert "source \"$MANIFEST_ROOT/install.env\"" not in uninstall
    assert "load_install_env" in uninstall
    assert "is_manifest_path_allowed" in uninstall


def test_admin_helper_sudoers_is_exact_allowlist():
    install = read("install.sh")
    assert "avian-visitors-admin-helper@*.service" not in install
    assert "NOPASSWD: ALL" not in install
    assert "www-data ALL=" not in install
    assert "caddy ALL=" not in install
    assert "avian-visitors-admin-helper@restart-recording.service" in install
    assert "avian-visitors-admin-helper@status.service" in install


def test_managed_prefix_requires_marker_for_removal():
    install = read("install.sh")
    uninstall = read("uninstall.sh")
    common = read("lib/common.sh")
    assert 'AV_PREFIX_MARKER=".avian-visitors-orange-pi-zero-3"' in common
    assert 'Refusing to replace non-empty unmarked prefix' in install
    assert '[ -f "$PREFIX/$AV_PREFIX_MARKER" ]' in uninstall
    assert 'find "$PREFIX" -xdev -mindepth 1 -delete' in uninstall


def test_start_services_requires_explicit_audio_or_override():
    install = read("install.sh")
    assert "ALLOW_DEFAULT_AUDIO=0" in install
    assert "--allow-default-audio" in install
    assert "Refusing to start services with REC_CARD=default" in install


def test_external_web_bind_requires_explicit_override():
    install = read("install.sh")
    assert "ALLOW_EXTERNAL_WEB_BIND=0" in install
    assert "--allow-external-web-bind" in install
    assert "Refusing non-loopback --web-bind" in install


def test_livestream_is_not_enabled_by_default():
    install = read("install.sh")
    assert "systemctl enable birdnet-stats.service livestream.service" not in install
    assert "systemctl start birdnet-stats.service livestream.service" not in install
    assert "livestream.service" in install


def test_caddy_blocks_write_capable_sqlite_ui():
    caddy = read("config/caddy.loopback.Caddyfile.template")
    assert "respond /scripts/adminer* 403" in caddy
    assert "php_fastcgi" in caddy


def test_systemd_units_have_required_safety_properties():
    for unit in (PLATFORM / "systemd").glob("*.service.in"):
        text = unit.read_text(encoding="utf-8")
        if unit.name == "avian-visitors-admin-helper.service.in":
            continue
        assert "ExecStart=__AV_PREFIX__/" in text
        assert "Restart=on-failure" in text
        assert "TimeoutStopSec=" in text
        assert "User=__AV_USER__" in text
        assert "NoNewPrivileges=true" in text
        assert "ProtectSystem=strict" in text
        assert "StandardOutput" not in text
