<p align="right">
  <a href="./README.md">English</a> | 简体中文
</p>

# GT FRP Dev Tunnel

通过你自己的 `frps` 网关和泛域名，把本地开发服务器临时暴露到公网，并把可访问 URL 交给编码 Agent 做手机端或外部验证。

`gt-frp-dev-tunnel` 面向临时开发验证，不面向生产流量。它会把 FRP 配置放在用户级目录里，在输出中隐藏 token，并避免把隧道脚本、配置或日志复制进正在测试的项目仓库。

## 为什么需要它

当本地 Web 应用需要在手机、另一台机器或远程审查流程里验证时，常见选择要么是过早部署，要么是暴露太多本机状态。这个项目给开发者和 Agent 一个可重复的中间路径：

- 在你自己的 Linux VPS 上启动一个轻量 `frps` 网关。
- 在本机一次性配置网关地址、端口、token 和泛域名。
- 为真实本地 dev server 启动高熵临时 HTTP 子域名隧道。
- 用命令行完成验证、查看日志和停止隧道。

## 包含内容

- `scripts/frps-server-setup.sh`：Linux VPS 服务端启动脚本，支持 Docker 或 systemd 运行 `frps`，输出泛域名 DNS 指引、防火墙检查命令和客户端交接提示词。
- `scripts/frp-client-bootstrap.sh`：用户级客户端安装脚本，下载 helper，把配置写到当前项目之外，必要时安装 `frpc`，并运行 `doctor`。
- `scripts/frp_dev_tunnel.py`：跨平台 helper，提供 `config`、`doctor`、`install-frpc`、`smoke-test`、`start-auto`、`verify`、`logs`、`stop`、`stop-all` 等命令。
- `SKILL.md`：给 Codex、Claude Code、OpenCode、OpenCloud 或类似编码 Agent 使用的技能说明。
- `agents/openai.yaml`：OpenAI/Codex 侧元数据。

## 环境要求

服务端：

- 一台有 root 权限的 Linux VPS。
- 一个可以设置泛域名解析的域名或子域名，例如 `*.tunnel.example.com`。
- 一个给 `frps` 客户端连接的入站 TCP 端口，默认是 `7111`。

客户端：

- Python 3.8+。
- 用于 bootstrap 下载的 `curl` 或 Python。
- 本地 `frpc` 二进制，或在你明确选择 Docker 模式时使用 Docker。helper 可以为当前用户安装轻量 `frpc`。

## 服务端安装

在专用 Linux VPS 上执行。建议这台服务器只作为 FRP 网关使用。

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup
```

如果已经知道泛域名：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

指定自定义客户端连接端口：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --server-port 7443
```

更稳妥的先审查再执行流程：

```bash
curl -fsSLO https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh
less frps-server-setup.sh
sudo bash frps-server-setup.sh setup --domain tunnel.example.com
```

当仓库开始发布 release 后，类生产使用建议改用 tag URL，而不是直接使用 `main`：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/v0.1.0/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com
```

服务端脚本会：

- 安装并配置 `frps`。
- Docker 可用时自动使用 Docker，否则回退到 systemd 服务。
- 生成或接收 `auth.token`。
- 在可能的情况下处理 Nginx、OpenResty 或 Apache 的 80/443 端口冲突。
- 输出泛域名 DNS 指引和外部端口检查命令。
- 输出一段包含客户端 bootstrap 命令的本地 Agent 提示词。

需要时可以强制指定运行方式：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime docker
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | sudo bash -s -- setup --domain tunnel.example.com --runtime systemd
```

Docker 模式默认使用 `snowdreamtech/frps:<frp-version>`。如果服务器需要镜像源或私有镜像仓库，可以用 `--frps-image <image>` 覆盖。

## 防火墙和 DNS

安装后，需要在云服务器厂商防火墙或安全组里放行 frps 客户端连接端口：

```text
Inbound TCP 7111
```

如果使用了自定义 `--server-port`，就放行对应端口。如果 HTTP/HTTPS 流量没有由已有网关或 CDN 接管，也要确认 TCP `80` 和 `443` 可以访问。

从客户端电脑或任意外部机器检查 frps 连接端口：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frps-server-setup.sh | bash -s -- check-port --host tunnel.example.com --port 7111
```

DNS 需要把根域名和泛域名都指向网关服务器，或指向它前面的网关/CDN：

```text
tunnel.example.com      A      <server-ip>
*.tunnel.example.com    A      <server-ip>
```

## 客户端 Bootstrap

服务端安装完成后，把脚本打印的提示词复制给本地开发 Agent，或手动运行 bootstrap 命令：

```bash
curl -fsSL https://raw.githubusercontent.com/Leochens/gt-frp-dev-tunnel/main/scripts/frp-client-bootstrap.sh | bash -s -- --server-addr tunnel.example.com --server-port 7111 --token '<token>' --public-domain tunnel.example.com --public-scheme http
```

这个 bootstrap 命令会把 helper 安装到用户级目录，把 FRP 配置写到用户配置目录，缺少 `frpc` 时自动安装，并运行 `doctor`。它不应该在当前项目中创建或修改文件。

下面示例使用 `frp-dev-tunnel`。如果 bootstrap 输出了完整的 `Tunnel command` 路径，请使用那条完整路径。

```bash
frp-dev-tunnel doctor
frp-dev-tunnel smoke-test
```

首次配置或不确定 FRP 链路是否打通时，使用 `smoke-test`。如果机器已经配置好，启动真实本地 dev server 后直接暴露端口：

```bash
frp-dev-tunnel start-auto demo 5173
frp-dev-tunnel verify <subdomain>
frp-dev-tunnel logs <subdomain>
frp-dev-tunnel stop <subdomain>
frp-dev-tunnel stop-all
```

## 手动配置客户端

如果你已经克隆了这个仓库，或用其他方式安装了 helper：

```bash
frp-dev-tunnel config \
  --server-addr <frps-domain-or-ip> \
  --server-port <frps-port> \
  --token '<frps-token>' \
  --public-domain <wildcard-domain> \
  --public-scheme <http-or-https>
```

常用环境变量：

```bash
FRP_SERVER_ADDR=<frps-domain-or-ip>
FRP_SERVER_PORT=<frps-port>
FRP_AUTH_TOKEN=<frps-token>
FRP_DEV_DOMAIN=<subdomain-host>
FRP_PUBLIC_SCHEME=http
FRPC_BIN=/path/to/frpc
FRPC_SOURCE_CONFIG=/path/to/frpc.toml
FRP_RUNNER=local
```

配置优先级：

1. `FRPC_SOURCE_CONFIG`，从已有 `frpc.toml` 解析。
2. 保存到 `FRP_TUNNEL_CONFIG` 或系统默认位置的本地配置。
3. 环境变量。
4. CLI 参数。

## Agent 输出模板

当 Agent 为项目启动隧道后，应该把公网 URL 放在最前面，并保留管理命令：

```text
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
```

## Vite Host 检查

如果外网访问 Vite 时返回 403，并提到 `allowedHosts` 或 blocked Host，说明隧道已经到达本地 dev server。只允许当前配置的泛域名，然后重启 dev server：

```ts
server: {
  allowedHosts: ['.tunnel.example.com'],
}
```

## 安全说明

- 把生成的 URL 当作临时验证链接，不要当作强访问控制。
- 不要通过便利隧道暴露私有数据、生产凭据、支付/管理操作或破坏性工具。
- FRPS token 只应出现在可信的本地 Agent 提示词和用户级配置里。
- 只有在你明确需要隧道 Basic Auth 时，才使用 `FRP_HTTP_USER` 和 `FRP_HTTP_PASSWORD`。
- 如果 FRPS token 被贴到了不可信渠道，请立即轮换。

漏洞报告流程见 [SECURITY.md](./SECURITY.md)。

## 贡献

欢迎提交 issue 和 pull request。较大的改动请先阅读 [CONTRIBUTING.md](./CONTRIBUTING.md)。社区互动遵循 [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)。

## 协议

MIT。详见 [LICENSE](./LICENSE)。
