#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

REPORT_FILE=""
CHECK_NETWORK=1
ERRORS=0
WARNINGS=0
JSON_ITEMS=()

usage() {
  cat <<'EOF'
Usage: preflight.sh [--report PATH] [--no-network]

Reads host state only. It does not require privilege escalation or modify files.
Returns non-zero when a critical incompatibility is found.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      REPORT_FILE="${2:?missing path after --report}"
      shift 2
      ;;
    --no-network)
      CHECK_NETWORK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

json_escape() {
  local value
  value="$(cat)"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  printf '"%s"' "$value"
}

record() {
  local level="$1"
  local key="$2"
  local message="$3"
  printf '%s: [%s] %s\n' "$level" "$key" "$message"
  case "$level" in
    ERROR) ERRORS=$((ERRORS + 1)) ;;
    WARNING) WARNINGS=$((WARNINGS + 1)) ;;
  esac
  JSON_ITEMS+=("{\"level\":\"$level\",\"key\":\"$key\",\"message\":$(printf '%s' "$message" | json_escape)}")
}

check_cmd() {
  local cmd="$1"
  if has_command "$cmd"; then
    record INFO "cmd.$cmd" "found $(command -v "$cmd")"
  else
    record WARNING "cmd.$cmd" "not found"
  fi
}

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  record INFO "os" "${PRETTY_NAME:-unknown}"
  if [ "${ID:-}" != "debian" ] && [ "${ID_LIKE:-}" != "debian" ]; then
    record WARNING "os.debian" "This installer is intended for Debian or Debian-like systems."
  fi
else
  record ERROR "os-release" "/etc/os-release is not readable"
fi

arch="$(uname -m)"
case "$arch" in
  aarch64|arm64)
    record INFO "arch" "$arch"
    ;;
  *)
    record ERROR "arch" "Expected aarch64/arm64 for Orange Pi Zero 3, got $arch"
    ;;
esac

record INFO "kernel" "$(uname -r)"

if has_command python3; then
  py_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  record INFO "python" "$py_version"
  case "$py_version" in
    3.11|3.12|3.13) ;;
    *) record ERROR "python.support" "Python 3.11, 3.12, or 3.13 is required." ;;
  esac
else
  record ERROR "python" "python3 is not installed"
fi

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || printf 0)"
if [ "$mem_kb" -lt 400000 ]; then
  record WARNING "ram" "Low RAM detected: ${mem_kb} KiB"
else
  record INFO "ram" "${mem_kb} KiB"
fi

root_avail="$(df -Pk / | awk 'NR == 2 {print $4}')"
if [ "${root_avail:-0}" -lt 2000000 ]; then
  record WARNING "disk.root" "Less than 2 GB free on /: ${root_avail:-0} KiB"
else
  record INFO "disk.root" "${root_avail} KiB free"
fi

root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
record INFO "filesystem.root" "${root_fstype:-unknown}"

if [ -d /run/systemd/system ] && has_command systemctl; then
  record INFO "systemd" "available"
else
  record ERROR "systemd" "systemd is required"
fi

for cmd in arecord aplay ffmpeg sox sqlite3 curl git jq ss; do
  check_cmd "$cmd"
done

if has_command arecord; then
  arecord_l="$(arecord -l 2>&1)" && arecord_l_status=0 || arecord_l_status=$?
  if [ "$arecord_l_status" -eq 0 ]; then
    record INFO "alsa.cards" "$(printf '%s' "$arecord_l" | tr '\n' ';' | cut -c1-400)"
    if printf '%s' "$arecord_l" | grep -qi 'HDMI' &&
       ! printf '%s' "$arecord_l" | grep -Eqi 'USB|Microphone|Mic|Audio'; then
      record WARNING "alsa.capture" "Only HDMI-like capture hardware was detected. Plug in the USB microphone and choose a stable REC_CARD from arecord -L before starting services."
    fi
  else
    record ERROR "alsa.cards" "arecord -l failed: $(printf '%s' "$arecord_l" | tr '\n' ';' | cut -c1-240)"
  fi
  arecord_L="$(arecord -L 2>&1)" && arecord_L_status=0 || arecord_L_status=$?
  if [ "$arecord_L_status" -eq 0 ]; then
    record INFO "alsa.pcms" "$(printf '%s' "$arecord_L" | tr '\n' ';' | cut -c1-400)"
  else
    record WARNING "alsa.pcms" "arecord -L failed"
  fi
fi

if [ -e /dev/snd ]; then
  if [ -r /dev/snd ] && [ -x /dev/snd ]; then
    record INFO "dev.snd" "current user can traverse /dev/snd"
  else
    record WARNING "dev.snd" "current user may not have access to /dev/snd; add the service user to audio"
  fi
else
  record ERROR "dev.snd" "/dev/snd does not exist"
fi

if has_command dpkg-query; then
  for pkg in caddy nginx apache2 php-fpm docker.io ttyd pulseaudio pipewire; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      record INFO "package.$pkg" "installed"
    else
      record INFO "package.$pkg" "not installed"
    fi
  done
fi

if has_command ss; then
  ports="$(ss -H -ltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -nu | tr '\n' ' ')"
  record INFO "ports.tcp" "${ports:-none}"
  for port in 80 443 8000 8079 8501; do
    if printf ' %s ' "$ports" | grep -q " $port "; then
      record WARNING "port.$port" "TCP port $port is already listening"
    fi
  done
fi

for path in "$HOME/BirdNET-Pi" "$HOME/BirdSongs" /etc/birdnet /var/lib/avian-visitors; do
  if [ -e "$path" ]; then
    record WARNING "previous.$path" "$path already exists"
  else
    record INFO "previous.$path" "not present"
  fi
done

if has_command python3; then
  tflite_probe="$(python3 - <<'PY' 2>&1
import importlib.util
import sys
mods = ["tflite_runtime.interpreter", "tensorflow.lite"]
for mod in mods:
    try:
        if importlib.util.find_spec(mod):
            print(mod)
            sys.exit(0)
    except ModuleNotFoundError:
        pass
print("no tflite runtime import found")
sys.exit(1)
PY
)" && tflite_status=0 || tflite_status=$?
  if [ "$tflite_status" -eq 0 ]; then
    record INFO "tflite.import" "$tflite_probe"
  else
    record WARNING "tflite.import" "$tflite_probe"
  fi
fi

if [ "$CHECK_NETWORK" = "1" ] && has_command curl; then
  for url in https://github.com https://pypi.org; do
    if curl -fsSI --max-time 8 "$url" >/dev/null; then
      record INFO "network.$url" "reachable"
    else
      record WARNING "network.$url" "not reachable from this host"
    fi
  done
fi

if [ -n "$REPORT_FILE" ]; then
  {
    printf '{\n'
    printf '  "platform": "%s",\n' "$AV_PLATFORM_NAME"
    printf '  "errors": %s,\n' "$ERRORS"
    printf '  "warnings": %s,\n' "$WARNINGS"
    printf '  "items": [\n'
    for i in "${!JSON_ITEMS[@]}"; do
      [ "$i" -gt 0 ] && printf ',\n'
      printf '    %s' "${JSON_ITEMS[$i]}"
    done
    printf '\n  ]\n}\n'
  } > "$REPORT_FILE"
  record INFO "report" "wrote $REPORT_FILE"
fi

[ "$ERRORS" -eq 0 ]
