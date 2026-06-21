#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

is_python_compatible() {
  "$1" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
}

if command -v python3 >/dev/null 2>&1 && is_python_compatible python3; then
  exec python3 "$SCRIPT_DIR/frp_dev_tunnel.py" "$@"
fi

if command -v python >/dev/null 2>&1 && is_python_compatible python; then
  exec python "$SCRIPT_DIR/frp_dev_tunnel.py" "$@"
fi

echo "error: Python 3.8+ is required." >&2
if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
  echo "Install with: brew install python" >&2
elif command -v apt-get >/dev/null 2>&1; then
  echo "Install with: sudo apt-get update && sudo apt-get install -y python3" >&2
elif command -v dnf >/dev/null 2>&1; then
  echo "Install with: sudo dnf install -y python3" >&2
elif command -v pacman >/dev/null 2>&1; then
  echo "Install with: sudo pacman -S --needed python" >&2
elif command -v apk >/dev/null 2>&1; then
  echo "Install with: sudo apk add python3" >&2
else
  echo "Install Python 3.8+ first, then rerun this command." >&2
fi
exit 1
