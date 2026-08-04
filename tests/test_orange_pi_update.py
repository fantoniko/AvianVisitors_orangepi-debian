from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "platforms" / "orange-pi-zero-3" / "install.sh").read_text(encoding="utf-8")
DEPLOY = (ROOT / "platforms" / "deploy.sh").read_text(encoding="utf-8")
README = (ROOT / "platforms" / "orange-pi-zero-3" / "README.md").read_text(encoding="utf-8")
UPDATE = (ROOT / "platforms" / "orange-pi-zero-3" / "update.sh").read_text(encoding="utf-8")


def test_update_mode_is_available_through_deploy_wrapper():
    assert '--update)' in DEPLOY
    assert 'args+=(--update)' in DEPLOY
    assert '--update)' in INSTALL
    assert 'RUN_PREFLIGHT=0' in INSTALL
    assert 'systemctl restart birdnet-recording.service' in INSTALL
    assert 'exec bash "$SCRIPT_DIR/install.sh"' in UPDATE
    assert '--web-bind 0.0.0.0:8079' in UPDATE
    assert '--allow-external-web-bind' in UPDATE


def test_unchanged_python_dependencies_do_not_use_network():
    assert '.avian-python-dependencies.sha256' in INSTALL
    assert 'Python dependencies unchanged; skipping venv and pip' in INSTALL
    assert 'tflite-runtime==$tflite_version' in INSTALL
    assert '--no-index -r "$offline_requirements"' in INSTALL
    assert 'if [ ! -s "$PREFIX/$whl" ]' in INSTALL
    assert INSTALL.index('--no-index -r "$offline_requirements"') < INSTALL.index('if [ ! -s "$PREFIX/$whl" ]')
    assert 'pip3" install --upgrade pip wheel' not in INSTALL


def test_update_copy_does_not_recursively_chown_venv():
    assert 'git -C "$REPO_ROOT" archive' not in INSTALL
    assert "--exclude='./birdnet'" in INSTALL
    assert "--exclude='./.venv'" in INSTALL
    assert 'runuser -u "$APP_USER" -- tar -C "$PREFIX" -xf -' in INSTALL
    assert 'chown -R "$APP_USER:$APP_USER" "$PREFIX"' not in INSTALL


def test_update_workflow_is_documented():
    assert 'platforms/orange-pi-zero-3/update.sh' in README
    assert '--force-python-deps' in README
