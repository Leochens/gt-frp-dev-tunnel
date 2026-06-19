#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${FRP_DEV_DOMAIN:-dev.guantou.site}"
SOURCE_CONFIG="${FRPC_SOURCE_CONFIG:-/opt/1panel/apps/frpc/frpc/data/frpc.toml}"
IMAGE="${FRPC_IMAGE:-snowdreamtech/frpc:0.67.0}"
WORK_DIR="${FRP_TUNNEL_WORK_DIR:-/tmp/gt-frp-dev-tunnel}"
CONTAINER_PREFIX="${FRP_CONTAINER_PREFIX:-gt-frpc}"

usage() {
  cat <<'EOF'
Usage:
  frp-dev-tunnel.sh start <subdomain> <local-port> [local-ip]
  frp-dev-tunnel.sh start-auto <prefix> <local-port> [local-ip]
  frp-dev-tunnel.sh stop <subdomain>
  frp-dev-tunnel.sh logs <subdomain>
  frp-dev-tunnel.sh verify <subdomain> [path]
  frp-dev-tunnel.sh status

Environment:
  FRP_DEV_DOMAIN          Default: dev.guantou.site
  FRPC_SOURCE_CONFIG      Default: /opt/1panel/apps/frpc/frpc/data/frpc.toml
  FRPC_IMAGE              Default: snowdreamtech/frpc:0.67.0
  FRP_HTTP_USER           Optional HTTP Basic Auth username. Do not set for default phone validation.
  FRP_HTTP_PASSWORD       Optional HTTP Basic Auth password. Do not set for default phone validation.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

docker_cmd() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo -n docker info >/dev/null 2>&1; then
    sudo -n docker "$@"
  else
    die "docker is not accessible; run as a user with docker access or passwordless sudo"
  fi
}

read_source_config() {
  if [[ -r "$SOURCE_CONFIG" ]]; then
    cat "$SOURCE_CONFIG"
  elif sudo -n test -r "$SOURCE_CONFIG" 2>/dev/null; then
    sudo -n cat "$SOURCE_CONFIG"
  else
    die "cannot read frpc source config: $SOURCE_CONFIG"
  fi
}

validate_subdomain() {
  local subdomain="$1"
  [[ "$subdomain" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
    die "subdomain must be 1-63 chars, lowercase letters/digits/hyphens, no dots"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "local-port must be numeric"
  (( port >= 1 && port <= 65535 )) || die "local-port must be 1-65535"
}

slug_prefix() {
  local raw="${1:-demo}"
  local slug
  slug="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  [[ -n "$slug" ]] || slug="demo"
  printf '%s' "$slug"
}

generate_subdomain() {
  local prefix
  local suffix
  local max_prefix_len
  prefix="$(slug_prefix "${1:-demo}")"
  if command -v openssl >/dev/null 2>&1; then
    suffix="$(openssl rand -hex 12)"
  else
    suffix="$(printf '%s%s%s' "$(date +%s)" "$RANDOM" "$RANDOM" | sha256sum | cut -c1-24)"
  fi
  max_prefix_len=$((63 - 1 - ${#suffix}))
  prefix="${prefix:0:$max_prefix_len}"
  prefix="$(printf '%s' "$prefix" | sed -E 's/-+$//')"
  [[ -n "$prefix" ]] || prefix="demo"
  printf '%s-%s' "$prefix" "$suffix"
}

container_name() {
  printf '%s-%s' "$CONTAINER_PREFIX" "$1"
}

write_config() {
  local subdomain="$1"
  local local_port="$2"
  local local_ip="$3"
  local config_file="$4"

  read_source_config | awk '
    /^(serverAddr|serverPort|auth\.method|auth\.token|transport\.protocol|transport\.tls\.)[[:space:]]*=/ { print }
  ' > "$config_file"

  {
    printf '\n[[proxies]]\n'
    printf 'name = "%s"\n' "$subdomain"
    printf 'type = "http"\n'
    printf 'localIP = "%s"\n' "$local_ip"
    printf 'localPort = %s\n' "$local_port"
    printf 'subdomain = "%s"\n' "$subdomain"
    if [[ -n "${FRP_HTTP_USER:-}" && -n "${FRP_HTTP_PASSWORD:-}" ]]; then
      printf 'httpUser = "%s"\n' "$FRP_HTTP_USER"
      printf 'httpPassword = "%s"\n' "$FRP_HTTP_PASSWORD"
    fi
  } >> "$config_file"

  chmod 600 "$config_file"
}

start_tunnel() {
  local subdomain="${1:-}"
  local local_port="${2:-}"
  local local_ip="${3:-127.0.0.1}"

  [[ -n "$subdomain" && -n "$local_port" ]] || die "start requires <subdomain> <local-port> [local-ip]"
  validate_subdomain "$subdomain"
  validate_port "$local_port"

  local dir="$WORK_DIR/$subdomain"
  local config_file="$dir/frpc.toml"
  local name
  name="$(container_name "$subdomain")"

  mkdir -p "$dir"
  write_config "$subdomain" "$local_port" "$local_ip" "$config_file"

  docker_cmd rm -f "$name" >/dev/null 2>&1 || true
  docker_cmd run -d \
    --name "$name" \
    --network host \
    -v "$config_file:/etc/frp/frpc.toml:ro" \
    --entrypoint /usr/bin/frpc \
    "$IMAGE" -c /etc/frp/frpc.toml >/dev/null

  sleep 2
  if ! docker_cmd ps --filter "name=^/${name}$" --filter "status=running" --format '{{.Names}}' | grep -qx "$name"; then
    docker_cmd logs "$name" >&2 || true
    die "frpc container exited"
  fi

  docker_cmd logs --tail=40 "$name" | sed -E 's/(token|password|serverAddr|auth\.[^= ]+)=([^ ]+)/\1=<redacted>/Ig' >&2
  printf 'https://%s.%s/\n' "$subdomain" "$DOMAIN"
}

start_auto_tunnel() {
  local prefix="${1:-}"
  local local_port="${2:-}"
  local local_ip="${3:-127.0.0.1}"
  local subdomain

  [[ -n "$prefix" && -n "$local_port" ]] || die "start-auto requires <prefix> <local-port> [local-ip]"
  validate_port "$local_port"
  subdomain="$(generate_subdomain "$prefix")"
  start_tunnel "$subdomain" "$local_port" "$local_ip"
}

stop_tunnel() {
  local subdomain="${1:-}"
  [[ -n "$subdomain" ]] || die "stop requires <subdomain>"
  validate_subdomain "$subdomain"
  docker_cmd rm -f "$(container_name "$subdomain")" >/dev/null
  rm -rf "$WORK_DIR/$subdomain"
}

logs_tunnel() {
  local subdomain="${1:-}"
  [[ -n "$subdomain" ]] || die "logs requires <subdomain>"
  validate_subdomain "$subdomain"
  docker_cmd logs --tail=120 "$(container_name "$subdomain")"
}

verify_tunnel() {
  local subdomain="${1:-}"
  local path="${2:-/}"
  [[ -n "$subdomain" ]] || die "verify requires <subdomain> [path]"
  validate_subdomain "$subdomain"
  [[ "$path" == /* ]] || path="/$path"
  curl --noproxy '*' -k -sS -D - --max-time 10 "https://${subdomain}.${DOMAIN}${path}" | sed -n '1,80p'
}

status_tunnels() {
  docker_cmd ps -a \
    --filter "name=${CONTAINER_PREFIX}-" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
}

main() {
  local command="${1:-help}"
  shift || true

  case "$command" in
    start) start_tunnel "$@" ;;
    start-auto) start_auto_tunnel "$@" ;;
    stop) stop_tunnel "$@" ;;
    logs) logs_tunnel "$@" ;;
    verify) verify_tunnel "$@" ;;
    status) status_tunnels ;;
    help|-h|--help) usage ;;
    *) usage; die "unknown command: $command" ;;
  esac
}

main "$@"
