#!/usr/bin/env bash
set -Eeuo pipefail

RAW_BASE_URL="${FRP_TUNNEL_RAW_BASE_URL:-https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main}"
TARGET_DIR="${FRP_TUNNEL_HELPER_DIR:-scripts}"
SERVER_ADDR=""
SERVER_PORT=""
AUTH_TOKEN=""
PUBLIC_DOMAIN=""
PUBLIC_SCHEME="http"
FRP_VERSION="0.67.0"
PREFIX="demo"
SKIP_INSTALL_FRPC="0"
SKIP_DOCTOR="0"

usage() {
  cat <<'EOF'
Usage:
  frp-client-bootstrap.sh --server-addr <host> --server-port <port> --token <token> --public-domain <domain> [options]

Options:
  --public-scheme <http|https>  Default: http.
  --target-dir <dir>            Helper install dir in the current project. Default: scripts.
  --frp-version <version>       Default: 0.67.0.
  --prefix <name>               Suggested start-auto prefix. Default: demo.
  --skip-install-frpc           Do not install frpc when it is missing.
  --skip-doctor                 Do not run doctor after bootstrapping.
  -h, --help                    Show this help.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

download() {
  local url="$1"
  local path="$2"
  if have curl; then
    curl -fsSL "$url" -o "$path"
  elif have python3; then
    python3 - "$url" "$path" <<'PY'
import pathlib
import sys
import urllib.request

url = sys.argv[1]
path = pathlib.Path(sys.argv[2])
path.write_bytes(urllib.request.urlopen(url, timeout=20).read())
PY
  else
    fail "需要 curl 或 python3 下载安装 helper"
  fi
}

python_runner() {
  if have python3 && python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
  then
    printf 'python3'
    return
  fi

  if have python && python - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 8) else 1)
PY
  then
    printf 'python'
    return
  fi

  fail "需要 Python 3.8+。请先安装 Python，再重新运行 bootstrap"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-addr)
        SERVER_ADDR="${2:-}"
        shift 2
        ;;
      --server-port)
        SERVER_PORT="${2:-}"
        shift 2
        ;;
      --token)
        AUTH_TOKEN="${2:-}"
        shift 2
        ;;
      --public-domain)
        PUBLIC_DOMAIN="${2:-}"
        shift 2
        ;;
      --public-scheme)
        PUBLIC_SCHEME="${2:-}"
        shift 2
        ;;
      --target-dir)
        TARGET_DIR="${2:-}"
        shift 2
        ;;
      --frp-version)
        FRP_VERSION="${2:-}"
        shift 2
        ;;
      --prefix)
        PREFIX="${2:-}"
        shift 2
        ;;
      --skip-install-frpc)
        SKIP_INSTALL_FRPC="1"
        shift
        ;;
      --skip-doctor)
        SKIP_DOCTOR="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "未知参数: $1"
        ;;
    esac
  done
}

parse_args "$@"

[[ -n "$SERVER_ADDR" ]] || fail "缺少 --server-addr"
[[ -n "$SERVER_PORT" ]] || fail "缺少 --server-port"
[[ -n "$AUTH_TOKEN" ]] || fail "缺少 --token"
[[ -n "$PUBLIC_DOMAIN" ]] || fail "缺少 --public-domain"
[[ "$PUBLIC_SCHEME" == "http" || "$PUBLIC_SCHEME" == "https" ]] || fail "--public-scheme 只能是 http 或 https"

PYTHON_BIN="$(python_runner)"
mkdir -p "$TARGET_DIR"

download "${RAW_BASE_URL}/scripts/frp-dev-tunnel.sh" "${TARGET_DIR}/frp-dev-tunnel.sh"
download "${RAW_BASE_URL}/scripts/frp_dev_tunnel.py" "${TARGET_DIR}/frp_dev_tunnel.py"
download "${RAW_BASE_URL}/scripts/frp-dev-tunnel.cmd" "${TARGET_DIR}/frp-dev-tunnel.cmd"
chmod +x "${TARGET_DIR}/frp-dev-tunnel.sh" "${TARGET_DIR}/frp_dev_tunnel.py"

bootstrap_args=(
  bootstrap
  --server-addr "$SERVER_ADDR"
  --server-port "$SERVER_PORT"
  --token "$AUTH_TOKEN"
  --public-domain "$PUBLIC_DOMAIN"
  --public-scheme "$PUBLIC_SCHEME"
  --frp-version "$FRP_VERSION"
  --prefix "$PREFIX"
)

if [[ "$SKIP_INSTALL_FRPC" == "1" ]]; then
  bootstrap_args+=(--skip-install-frpc)
fi
if [[ "$SKIP_DOCTOR" == "1" ]]; then
  bootstrap_args+=(--skip-doctor)
fi

"${PYTHON_BIN}" "${TARGET_DIR}/frp_dev_tunnel.py" "${bootstrap_args[@]}"

printf '\nHelper ready in %s\n' "$TARGET_DIR"
