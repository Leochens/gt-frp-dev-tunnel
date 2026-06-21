#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="gt-frp-dev-tunnel"
REPO_URL="https://github.com/Leochens/gt-frp-dev-tunnel"
DEFAULT_FRP_VERSION="0.67.0"

FRP_DIR="/opt/frp"
FRPS_BIN="${FRP_DIR}/frps"
CONFIG_DIR="/etc/frp"
FRPS_CONFIG="${CONFIG_DIR}/frps.toml"
SERVICE_FILE="/etc/systemd/system/frps.service"
CLIENT_PROMPT_FILE="/root/gt-frp-dev-tunnel-client-prompt.txt"
DOCKER_CONTAINER_NAME="gt-frp-frps"

COMMAND="setup"
DOMAIN=""
SERVER_ADDR=""
SERVER_PORT="7111"
CHECK_HOST=""
CHECK_PORT=""
AUTH_TOKEN=""
FRP_VERSION="${DEFAULT_FRP_VERSION}"
RUNTIME="auto"
FRPS_IMAGE=""
VHOST_HTTP_PORT="80"
VHOST_HTTPS_PORT="443"
INTERNAL_HTTP_PORT="18080"
INTERNAL_HTTPS_PORT="18443"
GATEWAY="auto"
PUBLIC_SCHEME=""
TLS_CERT=""
TLS_KEY=""
ASSUME_YES="0"
DRY_RUN="0"

usage() {
  cat <<'EOF'
Usage:
  frps-server-setup.sh setup [options]
  frps-server-setup.sh doctor
  frps-server-setup.sh check-port --host <host> --port <port>

One-line install:
  curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup

Options:
  --domain <domain>              Public subdomain host, for example tunnel.example.com.
  --server-addr <host>           FRPS connection host for clients. Defaults to --domain.
  --server-port <port>           FRPS bind/client port. Default: 7111.
  --token <token|auto>           FRPS auth token. Default: auto.
  --frp-version <version>        frp release version. Default: 0.67.0.
  --runtime <auto|docker|systemd>
                                  Default: auto. Use Docker when available.
  --frps-image <image>           Docker image for frps. Default: snowdreamtech/frps:<version>.
  --vhost-http-port <port>       Desired frps HTTP vhost port. Default: 80.
  --vhost-https-port <port>      Desired frps HTTPS vhost port. Default: 443.
  --internal-http-port <port>    First fallback HTTP vhost port behind a gateway. Default: 18080.
  --internal-https-port <port>   First fallback HTTPS vhost port behind a gateway. Default: 18443.
  --gateway <auto|none|nginx|openresty|apache|manual>
  --public-scheme <http|https>   URL scheme local agents should print. Default: https.
  --tls-cert <path>              Existing wildcard certificate for gateway HTTPS.
  --tls-key <path>               Existing wildcard private key for gateway HTTPS.
  -y, --yes                      Do not ask for confirmation.
  --dry-run                      Print planned actions without changing files.
  -h, --help                     Show this help.
EOF
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

is_tty() {
  [[ -t 0 && -t 1 ]]
}

require_root() {
  [[ "${DRY_RUN}" == "1" ]] && return 0
  [[ "$(id -u)" == "0" ]] || fail "请使用 root 执行，推荐: curl ... | sudo bash -s -- setup"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

docker_available() {
  have docker || return 1
  docker info >/dev/null 2>&1
}

frps_image() {
  if [[ -n "${FRPS_IMAGE}" ]]; then
    printf '%s' "${FRPS_IMAGE}"
  else
    printf 'snowdreamtech/frps:%s' "${FRP_VERSION}"
  fi
}

choose_runtime() {
  case "${RUNTIME}" in
    auto)
      if docker_available; then
        printf 'docker'
      else
        printf 'systemd'
      fi
      ;;
    docker)
      [[ "${DRY_RUN}" == "1" ]] || docker_available || fail "Docker 不可用；请先安装/启动 Docker，或使用 --runtime systemd"
      printf 'docker'
      ;;
    systemd)
      printf 'systemd'
      ;;
    *)
      fail "--runtime 只能是 auto、docker 或 systemd"
      ;;
  esac
}

run_cmd() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] $*"
    return 0
  fi
  "$@"
}

backup_path() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    local backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "${path}" "${backup}"
    log "已备份: ${backup}"
  fi
}

write_file() {
  local path="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] write ${path}"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "${path}")"
  backup_path "${path}"
  cat >"${path}"
}

write_secret_file() {
  local path="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] write secret ${path}"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "${path}")"
  backup_path "${path}"
  local old_umask
  old_umask="$(umask)"
  umask 077
  cat >"${path}"
  umask "${old_umask}"
  chmod 600 "${path}"
}

validate_domain() {
  local raw="$1"
  if [[ "${raw}" == \*.* ]]; then
    raw="${raw#\*.}"
  fi
  [[ -n "${raw}" ]] || fail "域名不能为空"
  [[ "${raw}" != *"/"* && "${raw}" != *" "* ]] || fail "域名不能包含斜杠或空格: ${raw}"
  [[ "${raw}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail "域名格式不正确: ${raw}"
}

validate_port() {
  local value="$1"
  local label="$2"
  [[ "${value}" =~ ^[0-9]+$ ]] || fail "${label}必须是数字"
  (( value >= 1 && value <= 65535 )) || fail "${label}必须在 1-65535 之间"
}

prompt_text() {
  local label="$1"
  local default_value="${2:-}"
  local value=""
  if [[ -n "${default_value}" ]]; then
    read -r -p "${label} [${default_value}]: " value
    printf '%s' "${value:-${default_value}}"
  else
    read -r -p "${label}: " value
    printf '%s' "${value}"
  fi
}

generate_token() {
  if have openssl; then
    openssl rand -hex 32
    return
  fi
  set +o pipefail
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  set -o pipefail
  printf '\n'
}

public_ip() {
  if have curl; then
    curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true
  fi
}

parse_args() {
  if [[ $# -gt 0 && "$1" != --* ]]; then
    COMMAND="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        DOMAIN="${2:-}"
        shift 2
        ;;
      --server-addr)
        SERVER_ADDR="${2:-}"
        shift 2
        ;;
      --server-port)
        SERVER_PORT="${2:-}"
        shift 2
        ;;
      --host)
        CHECK_HOST="${2:-}"
        shift 2
        ;;
      --port)
        CHECK_PORT="${2:-}"
        shift 2
        ;;
      --token)
        AUTH_TOKEN="${2:-}"
        shift 2
        ;;
      --frp-version)
        FRP_VERSION="${2:-}"
        shift 2
        ;;
      --runtime)
        RUNTIME="${2:-}"
        shift 2
        ;;
      --frps-image)
        FRPS_IMAGE="${2:-}"
        shift 2
        ;;
      --vhost-http-port)
        VHOST_HTTP_PORT="${2:-}"
        shift 2
        ;;
      --vhost-https-port)
        VHOST_HTTPS_PORT="${2:-}"
        shift 2
        ;;
      --internal-http-port)
        INTERNAL_HTTP_PORT="${2:-}"
        shift 2
        ;;
      --internal-https-port)
        INTERNAL_HTTPS_PORT="${2:-}"
        shift 2
        ;;
      --gateway)
        GATEWAY="${2:-}"
        shift 2
        ;;
      --public-scheme)
        PUBLIC_SCHEME="${2:-}"
        shift 2
        ;;
      --tls-cert)
        TLS_CERT="${2:-}"
        shift 2
        ;;
      --tls-key)
        TLS_KEY="${2:-}"
        shift 2
        ;;
      -y|--yes)
        ASSUME_YES="1"
        shift
        ;;
      --dry-run)
        DRY_RUN="1"
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

normalize_arch() {
  local machine
  machine="$(uname -m)"
  case "${machine}" in
    x86_64|amd64) printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    i386|i686|x86) printf '386' ;;
    armv7*|armv6*) printf 'arm' ;;
    *) fail "暂不支持当前 CPU 架构: ${machine}" ;;
  esac
}

frp_release_url() {
  local arch="$1"
  local base="frp_${FRP_VERSION}_linux_${arch}"
  printf 'https://github.com/fatedier/frp/releases/download/v%s/%s.tar.gz' "${FRP_VERSION}" "${base}"
}

port_listeners() {
  local port="$1"
  if have ss; then
    ss -ltnp 2>/dev/null | awk -v port=":${port}" '$4 ~ port "$" {print}'
  elif have lsof; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
  else
    return 1
  fi
}

port_busy() {
  [[ -n "$(port_listeners "$1")" ]]
}

port_busy_by_non_frps() {
  local text
  text="$(port_listeners "$1")"
  [[ -n "${text}" ]] && ! grep -qi 'frps' <<<"${text}"
}

find_free_port() {
  local port="$1"
  while port_busy "${port}"; do
    port=$((port + 1))
    (( port <= 65535 )) || fail "找不到空闲端口"
  done
  printf '%s' "${port}"
}

detect_gateway() {
  local selected="$1"
  if [[ "${selected}" != "auto" ]]; then
    printf '%s' "${selected}"
    return
  fi

  local text
  text="$(port_listeners "${VHOST_HTTP_PORT}" || true; port_listeners "${VHOST_HTTPS_PORT}" || true)"
  if grep -qi 'openresty' <<<"${text}"; then
    printf 'openresty'
  elif grep -qi 'nginx' <<<"${text}"; then
    printf 'nginx'
  elif grep -Eqi 'apache2|httpd' <<<"${text}"; then
    printf 'apache'
  elif grep -qi 'caddy' <<<"${text}"; then
    printf 'manual'
  elif grep -qi 'traefik' <<<"${text}"; then
    printf 'manual'
  elif [[ -n "${text}" ]]; then
    printf 'manual'
  else
    printf 'none'
  fi
}

nginx_conf_dir() {
  for dir in /etc/nginx/conf.d /usr/local/openresty/nginx/conf/conf.d; do
    if [[ -d "${dir}" ]]; then
      printf '%s' "${dir}"
      return 0
    fi
  done
  return 1
}

nginx_bin() {
  if [[ "$1" == "openresty" ]] && have openresty; then
    printf 'openresty'
  elif have nginx; then
    printf 'nginx'
  elif have openresty; then
    printf 'openresty'
  else
    return 1
  fi
}

reload_unit_if_present() {
  local unit="$1"
  if have systemctl && systemctl list-unit-files "${unit}.service" >/dev/null 2>&1; then
    run_cmd systemctl reload "${unit}" || warn "无法 reload ${unit}，请手动检查服务状态"
  fi
}

write_nginx_gateway() {
  local kind="$1"
  local http_port="$2"
  local conf_dir
  local bin
  conf_dir="$(nginx_conf_dir)" || fail "未找到 Nginx/OpenResty conf.d 目录，请使用 --gateway manual"
  bin="$(nginx_bin "${kind}")" || fail "未找到 nginx/openresty 命令"

  local conf_path="${conf_dir}/${APP_NAME}.conf"
  write_file "${conf_path}" <<EOF
server {
    listen 80;
    server_name *.${DOMAIN} ${DOMAIN};

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:${http_port};
    }
}
EOF

  if [[ -n "${TLS_CERT}" || -n "${TLS_KEY}" ]]; then
    [[ -f "${TLS_CERT}" ]] || fail "--tls-cert 文件不存在: ${TLS_CERT}"
    [[ -f "${TLS_KEY}" ]] || fail "--tls-key 文件不存在: ${TLS_KEY}"
    write_file "${conf_path}" <<EOF
server {
    listen 80;
    server_name *.${DOMAIN} ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name *.${DOMAIN} ${DOMAIN};

    ssl_certificate ${TLS_CERT};
    ssl_certificate_key ${TLS_KEY};

    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:${http_port};
    }
}
EOF
    PUBLIC_SCHEME="https"
  fi

  run_cmd "${bin}" -t
  if [[ "${kind}" == "openresty" ]]; then
    reload_unit_if_present openresty
  fi
  reload_unit_if_present nginx
  log "已写入 ${kind} 泛域名反向代理: ${conf_path}"
}

apache_conf_path() {
  if [[ -d /etc/apache2/sites-available ]]; then
    printf '/etc/apache2/sites-available/%s.conf' "${APP_NAME}"
  else
    printf '/etc/httpd/conf.d/%s.conf' "${APP_NAME}"
  fi
}

write_apache_gateway() {
  local http_port="$1"
  local conf_path
  conf_path="$(apache_conf_path)"

  if have a2enmod; then
    run_cmd a2enmod proxy proxy_http headers ssl >/dev/null
  fi

  write_file "${conf_path}" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias *.${DOMAIN}
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "http"
    ProxyPass / http://127.0.0.1:${http_port}/
    ProxyPassReverse / http://127.0.0.1:${http_port}/
</VirtualHost>
EOF

  if [[ -n "${TLS_CERT}" || -n "${TLS_KEY}" ]]; then
    [[ -f "${TLS_CERT}" ]] || fail "--tls-cert 文件不存在: ${TLS_CERT}"
    [[ -f "${TLS_KEY}" ]] || fail "--tls-key 文件不存在: ${TLS_KEY}"
    write_file "${conf_path}" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias *.${DOMAIN}
    Redirect permanent / https://${DOMAIN}/
</VirtualHost>

<VirtualHost *:443>
    ServerName ${DOMAIN}
    ServerAlias *.${DOMAIN}
    SSLEngine on
    SSLCertificateFile ${TLS_CERT}
    SSLCertificateKeyFile ${TLS_KEY}
    ProxyPreserveHost On
    RequestHeader set X-Forwarded-Proto "https"
    ProxyPass / http://127.0.0.1:${http_port}/
    ProxyPassReverse / http://127.0.0.1:${http_port}/
</VirtualHost>
EOF
    PUBLIC_SCHEME="https"
  fi

  if have a2ensite && [[ "${conf_path}" == /etc/apache2/* ]]; then
    run_cmd a2ensite "$(basename "${conf_path}")" >/dev/null
  fi
  if have apachectl; then
    run_cmd apachectl configtest
  fi
  reload_unit_if_present apache2
  reload_unit_if_present httpd
  log "已写入 Apache 泛域名反向代理: ${conf_path}"
}

write_manual_gateway_snippets() {
  local http_port="$1"
  local path="${CONFIG_DIR}/${APP_NAME}-gateway-snippets.txt"
  write_file "${path}" <<EOF
Manual gateway snippets for ${APP_NAME}

Nginx/OpenResty:

server {
    listen 80;
    server_name *.${DOMAIN} ${DOMAIN};
    location / {
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_pass http://127.0.0.1:${http_port};
    }
}

Apache:

<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias *.${DOMAIN}
    ProxyPreserveHost On
    ProxyPass / http://127.0.0.1:${http_port}/
    ProxyPassReverse / http://127.0.0.1:${http_port}/
</VirtualHost>

Caddy:

*.${DOMAIN}, ${DOMAIN} {
    reverse_proxy 127.0.0.1:${http_port} {
        header_up Host {host}
    }
}

Traefik dynamic config idea:

Route HostRegexp({subdomain:[a-z0-9-]+}.${DOMAIN}) to http://127.0.0.1:${http_port}, preserving the original Host header.
EOF
  warn "检测到端口冲突但未自动识别可修改的网关，已生成手动反代片段: ${path}"
}

install_frps() {
  have curl || fail "需要 curl 下载 frps"
  have tar || fail "需要 tar 解压 frps"

  local arch
  arch="$(normalize_arch)"
  local url
  url="$(frp_release_url "${arch}")"
  local base="frp_${FRP_VERSION}_linux_${arch}"

  log "下载 frps ${FRP_VERSION}: ${url}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "[dry-run] install ${FRPS_BIN}"
    return
  fi
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmp}/${base}.tar.gz"
  tar -xzf "${tmp}/${base}.tar.gz" -C "${tmp}"
  install -d -m 0755 "${FRP_DIR}"
  install -m 0755 "${tmp}/${base}/frps" "${FRPS_BIN}"
  rm -rf "${tmp}"
}

write_frps_config() {
  local http_port="$1"
  local https_port="$2"
  write_secret_file "${FRPS_CONFIG}" <<EOF
bindPort = ${SERVER_PORT}
auth.method = "token"
auth.token = "${AUTH_TOKEN}"
subDomainHost = "${DOMAIN}"
vhostHTTPPort = ${http_port}
vhostHTTPSPort = ${https_port}
EOF
  log "已写入 frps 配置: ${FRPS_CONFIG}"
}

write_systemd_service() {
  write_file "${SERVICE_FILE}" <<EOF
[Unit]
Description=frp server for ${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRPS_BIN} -c ${FRPS_CONFIG}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  if have systemctl; then
    run_cmd systemctl daemon-reload
    run_cmd systemctl enable --now frps
    run_cmd systemctl restart frps
  else
    warn "未找到 systemctl，请手动运行: ${FRPS_BIN} -c ${FRPS_CONFIG}"
  fi
}

managed_systemd_service() {
  [[ -f "${SERVICE_FILE}" ]] && grep -q "${APP_NAME}" "${SERVICE_FILE}"
}

stop_managed_systemd_service() {
  if have systemctl && managed_systemd_service; then
    run_cmd systemctl disable --now frps || warn "无法停止已有 frps.service，请手动检查端口占用"
  fi
}

stop_managed_docker_container() {
  if docker_available; then
    run_cmd docker rm -f "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1 || true
  elif [[ "${DRY_RUN}" == "1" ]]; then
    run_cmd docker rm -f "${DOCKER_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

start_docker_frps() {
  local image
  image="$(frps_image)"
  stop_managed_systemd_service
  stop_managed_docker_container
  log "使用 Docker 运行 frps: ${image}"
  run_cmd docker run -d \
    --name "${DOCKER_CONTAINER_NAME}" \
    --restart unless-stopped \
    --network host \
    -v "${FRPS_CONFIG}:${FRPS_CONFIG}:ro" \
    --entrypoint /usr/bin/frps \
    "${image}" \
    -c "${FRPS_CONFIG}"
}

start_systemd_frps() {
  stop_managed_docker_container
  install_frps
  write_systemd_service
}

print_dns_guide() {
  local ip
  ip="$(public_ip)"
  log ""
  log "DNS 泛域名解析指引"
  log "请在你的 DNS 服务商控制台添加："
  if [[ -n "${ip}" ]]; then
    log "  *.${DOMAIN}    A    ${ip}"
    log "  ${DOMAIN}      A    ${ip}"
  else
    log "  *.${DOMAIN}    A    <这台服务器的公网 IPv4>"
    log "  ${DOMAIN}      A    <这台服务器的公网 IPv4>"
  fi
  log ""
  log "解析验证命令："
  log "  dig +short gt-frp-test-$(date +%s).${DOMAIN}"
}

port_check_command() {
  local host="$1"
  local port="$2"
  printf "curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | bash -s -- check-port --host %q --port %q" "${host}" "${port}"
}

client_bootstrap_command() {
  printf "curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frp-client-bootstrap.sh | bash -s -- --server-addr %q --server-port %q --token %q --public-domain %q --public-scheme %q" \
    "${SERVER_ADDR}" \
    "${SERVER_PORT}" \
    "${AUTH_TOKEN}" \
    "${DOMAIN}" \
    "${PUBLIC_SCHEME}"
}

print_firewall_guide() {
  log ""
  log "服务器厂商防火墙 / 安全组"
  log "必须在云服务器厂商控制台放行入站 TCP ${SERVER_PORT}，这是客户端 frpc 连接 frps 的端口。"
  log "如果公网访问不是由已有网关/CDN接管，也请确认入站 TCP ${VHOST_HTTP_PORT}/${VHOST_HTTPS_PORT} 可访问。"
  log "如果脚本因端口冲突把 frps vhost 改成内部端口，不要把 ${INTERNAL_HTTP_PORT}/${INTERNAL_HTTPS_PORT} 这类内部端口暴露到公网。"
  log ""
  log "从客户端电脑或任意外部机器检查 FRPS 连接端口："
  log "  $(port_check_command "${SERVER_ADDR}" "${SERVER_PORT}")"
  log ""
  log "如果检查结果显示端口不通："
  log "  1. 到服务器厂商控制台的安全组/防火墙放行入站 TCP ${SERVER_PORT}。"
  log "  2. 如果系统里启用了 ufw/firewalld，也同步放行 TCP ${SERVER_PORT}。"
  log "  3. 等待规则生效后，重新执行上面的 check-port 命令。"
}

write_client_prompt() {
  local prompt
  prompt="$(cat <<EOF
请把下面这段话复制给你本地开发环境里的 Agent / 子 Agent：

---
服务端已经准备好。下面的命令包含 FRPS token，只发送给可信的本地开发 Agent。

第一步：先检查本地 Agent 是否已安装 gt-frp-dev-tunnel skill。
- 如果已安装：从 ${REPO_URL} 重新安装/刷新这个 skill。
- 如果未安装：先从 ${REPO_URL} 安装这个 skill。
- 如果当前 Agent 平台不支持 skill/plugin/connector，继续使用下面的 helper bootstrap 命令。

第二步：在配置客户端前，请先确认服务器厂商控制台的安全组/防火墙已经放行入站 TCP ${SERVER_PORT}。
如果不确定，请从客户端电脑或任意外部机器运行：

$(port_check_command "${SERVER_ADDR}" "${SERVER_PORT}")

如果端口不通，请先去服务器厂商控制台放行 TCP ${SERVER_PORT}，开启后再次运行同一条 check-port 命令确认成功。

第三步：端口确认可达后，在本机任意目录运行这一条命令。它会把 helper 安装到用户级目录，配置保存到用户配置目录，安装轻量 frpc（如缺失）并运行 doctor；不要把 helper 脚本复制进目标项目，也不要提交到项目仓库：

$(client_bootstrap_command)

下面示例里的 frp-dev-tunnel 指 bootstrap 输出的 Tunnel command；如果它打印的是完整路径，请使用那条完整路径。

第四步：如果这是首次配置，或不确定 FRP 链路是否打通，先跑一个极小 smoke 项目验证：

frp-dev-tunnel smoke-test

如果本机已经配置过、用户只是要一个公网访问链接，可以直接在真实项目里启动本地 dev server，并按实际端口启动临时隧道，例如：

frp-dev-tunnel start-auto demo 5173

如果外网访问 Vite 返回 403，说明隧道已到达本地 dev server；如果配置位置明确，请直接为目标项目添加仅允许 .${DOMAIN} 的 Host 放行，必要时重启 dev server 后再次验证。

最终回复必须把 URL 放在最前面，并使用这个模板：

公网访问已开启
URL: <public-url>
状态: <HTTP 200 OK | blocked: reason | unverified: reason>
本地服务: <local-ip>:<local-port>
隧道名: <subdomain>

管理:
- 查看全部: frp-dev-tunnel list
- 验证当前: frp-dev-tunnel verify <subdomain>
- 查看日志: frp-dev-tunnel logs <subdomain>
- 停止当前: frp-dev-tunnel stop <subdomain>
- 停止全部: frp-dev-tunnel stop-all
---
EOF
)"

  write_secret_file "${CLIENT_PROMPT_FILE}" <<<"${prompt}"
  log ""
  log "客户端 Agent 下一步提示词"
  log "${prompt}"
  log ""
  log "同一份提示词已保存到: ${CLIENT_PROMPT_FILE}"
}

preflight_prompts() {
  if [[ -z "${DOMAIN}" ]]; then
    if is_tty; then
      DOMAIN="$(prompt_text "请输入用于 FRP HTTP 子域名的根域名，例如 tunnel.example.com")"
    else
      fail "缺少 --domain。无交互环境请使用: setup --domain tunnel.example.com"
    fi
  fi
  if [[ "${DOMAIN}" == \*.* ]]; then
    DOMAIN="${DOMAIN#\*.}"
  fi
  validate_domain "${DOMAIN}"

  if [[ -z "${SERVER_ADDR}" ]]; then
    SERVER_ADDR="${DOMAIN}"
  fi

  if [[ -z "${AUTH_TOKEN}" || "${AUTH_TOKEN}" == "auto" ]]; then
    AUTH_TOKEN="$(generate_token)"
  fi

  if [[ -z "${PUBLIC_SCHEME}" ]]; then
    if [[ -n "${TLS_CERT}" && -n "${TLS_KEY}" ]]; then
      PUBLIC_SCHEME="https"
    else
      PUBLIC_SCHEME="http"
    fi
    if is_tty; then
      PUBLIC_SCHEME="$(prompt_text "客户端公开 URL scheme。已有 CDN/HTTPS 泛域名证书选 https；否则选 http" "${PUBLIC_SCHEME}")"
    fi
  fi

  [[ "${PUBLIC_SCHEME}" == "http" || "${PUBLIC_SCHEME}" == "https" ]] || fail "--public-scheme 只能是 http 或 https"
  [[ "${GATEWAY}" =~ ^(auto|none|nginx|openresty|apache|manual)$ ]] || fail "--gateway 参数不正确"
  [[ "${RUNTIME}" =~ ^(auto|docker|systemd)$ ]] || fail "--runtime 只能是 auto、docker 或 systemd"
  validate_port "${SERVER_PORT}" "server-port"
  validate_port "${VHOST_HTTP_PORT}" "vhost-http-port"
  validate_port "${VHOST_HTTPS_PORT}" "vhost-https-port"
  validate_port "${INTERNAL_HTTP_PORT}" "internal-http-port"
  validate_port "${INTERNAL_HTTPS_PORT}" "internal-https-port"

  log "提示：这台服务器最好专门作为 FRP 服务端服务器，避免和生产业务、数据库或复杂网关混跑。"
  log ""
  log "即将配置："
  log "  FRPS 连接地址: ${SERVER_ADDR}:${SERVER_PORT}"
  log "  公共泛域名: *.${DOMAIN}"
  log "  frps vhost 默认端口: HTTP ${VHOST_HTTP_PORT}, HTTPS ${VHOST_HTTPS_PORT}"
  log "  端口冲突时网关处理: ${GATEWAY}"
  log "  frps 运行方式: ${RUNTIME}（auto 会优先使用可用 Docker）"
  log "  客户端公开 URL scheme: ${PUBLIC_SCHEME}"

  if [[ "${ASSUME_YES}" != "1" && "${DRY_RUN}" != "1" && -t 0 ]]; then
    local answer
    read -r -p "继续安装/修改系统配置？[Y/n]: " answer
    [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]] || fail "已取消"
  fi
}

setup() {
  require_root
  preflight_prompts
  local selected_runtime
  selected_runtime="$(choose_runtime)"
  log "实际 frps 运行方式: ${selected_runtime}"

  if port_busy "${SERVER_PORT}"; then
    local bind_text
    bind_text="$(port_listeners "${SERVER_PORT}")"
    if ! grep -qi 'frps' <<<"${bind_text}"; then
      fail "FRPS 连接端口 ${SERVER_PORT} 已被占用，请换一个 --server-port。当前占用: ${bind_text}"
    fi
  fi

  local http_busy="0"
  local https_busy="0"
  port_busy_by_non_frps "${VHOST_HTTP_PORT}" && http_busy="1"
  port_busy_by_non_frps "${VHOST_HTTPS_PORT}" && https_busy="1"

  local effective_http_port="${VHOST_HTTP_PORT}"
  local effective_https_port="${VHOST_HTTPS_PORT}"
  local gateway_kind="none"

  if [[ "${http_busy}" == "1" || "${https_busy}" == "1" ]]; then
    gateway_kind="$(detect_gateway "${GATEWAY}")"
    effective_http_port="$(find_free_port "${INTERNAL_HTTP_PORT}")"
    effective_https_port="$(find_free_port "${INTERNAL_HTTPS_PORT}")"
    warn "检测到 ${VHOST_HTTP_PORT}/${VHOST_HTTPS_PORT} 端口冲突，frps vhost 将改用内部端口 ${effective_http_port}/${effective_https_port}"
  fi

  write_frps_config "${effective_http_port}" "${effective_https_port}"
  if [[ "${selected_runtime}" == "docker" ]]; then
    start_docker_frps
  else
    start_systemd_frps
  fi

  if [[ "${http_busy}" == "1" || "${https_busy}" == "1" ]]; then
    case "${gateway_kind}" in
      nginx|openresty)
        write_nginx_gateway "${gateway_kind}" "${effective_http_port}"
        ;;
      apache)
        write_apache_gateway "${effective_http_port}"
        ;;
      none)
        fail "端口冲突但 --gateway=none，无法暴露泛域名"
        ;;
      manual)
        write_manual_gateway_snippets "${effective_http_port}"
        ;;
    esac
  fi

  if [[ "${PUBLIC_SCHEME}" == "https" && ( -z "${TLS_CERT}" || -z "${TLS_KEY}" ) ]]; then
    warn "当前未提供 TLS 泛域名证书路径；请确认 CDN/网关已能处理 *.${DOMAIN} 的 HTTPS，否则客户端应使用 --public-scheme http。"
  fi

  print_dns_guide
  print_firewall_guide
  write_client_prompt

  if [[ "${selected_runtime}" == "docker" && "${DRY_RUN}" != "1" ]]; then
    log "frps 容器状态："
    docker ps --filter "name=^/${DOCKER_CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
  elif have systemctl && [[ "${DRY_RUN}" != "1" ]]; then
    log "frps 服务状态："
    systemctl --no-pager --full status frps || true
  fi
}

doctor() {
  log "System: $(uname -a)"
  if docker_available; then
    log "Docker: available"
    docker ps -a --filter "name=^/${DOCKER_CONTAINER_NAME}$" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" || true
  else
    log "Docker: unavailable"
  fi
  log "frps binary: $([[ -x "${FRPS_BIN}" ]] && printf '%s' "${FRPS_BIN}" || printf 'missing')"
  log "frps config: $([[ -f "${FRPS_CONFIG}" ]] && printf '%s' "${FRPS_CONFIG}" || printf 'missing')"
  if have systemctl; then
    systemctl --no-pager --full status frps || true
  fi
  log ""
  log "Ports:"
  for port in "${SERVER_PORT}" "${VHOST_HTTP_PORT}" "${VHOST_HTTPS_PORT}" "${INTERNAL_HTTP_PORT}" "${INTERNAL_HTTPS_PORT}"; do
    log "port ${port}:"
    port_listeners "${port}" || true
  done
}

check_tcp_port() {
  local host="$1"
  local port="$2"
  if have nc; then
    nc -z -w 5 "${host}" "${port}" >/dev/null 2>&1
    return $?
  fi
  if have python3; then
    python3 - "${host}" "${port}" <<'PY'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=5):
        pass
except OSError:
    raise SystemExit(1)
PY
    return $?
  fi
  if have timeout; then
    CHECK_HOST_ENV="${host}" CHECK_PORT_ENV="${port}" timeout 5 bash -c ': > "/dev/tcp/${CHECK_HOST_ENV}/${CHECK_PORT_ENV}"' >/dev/null 2>&1
    return $?
  fi
  fail "需要 nc、python3 或 timeout 之一来检查端口"
}

check_port() {
  [[ -n "${CHECK_HOST}" ]] || fail "缺少 --host"
  [[ -n "${CHECK_PORT}" ]] || fail "缺少 --port"
  validate_port "${CHECK_PORT}" "port"
  if check_tcp_port "${CHECK_HOST}" "${CHECK_PORT}"; then
    log "OK: ${CHECK_HOST}:${CHECK_PORT} 可以从当前机器访问。"
    return 0
  fi
  log "端口不通: ${CHECK_HOST}:${CHECK_PORT}"
  log "请到服务器厂商控制台的安全组/防火墙放行入站 TCP ${CHECK_PORT}。"
  log "如果服务器系统启用了 ufw/firewalld，也同步放行 TCP ${CHECK_PORT}。"
  log "开启后再次运行："
  log "  $(port_check_command "${CHECK_HOST}" "${CHECK_PORT}")"
  return 1
}

parse_args "$@"

case "${COMMAND}" in
  setup)
    setup
    ;;
  doctor)
    doctor
    ;;
  check-port)
    check_port
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    fail "未知命令: ${COMMAND}"
    ;;
esac
