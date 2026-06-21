#!/usr/bin/env python3
from __future__ import annotations

import argparse
import getpass
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path
from typing import Any

APP_NAME = "gt-frp-dev-tunnel"
DEFAULT_FRP_VERSION = "0.67.0"
DEFAULT_IMAGE = "snowdreamtech/frpc:0.67.0"
CONTAINER_CONFIG_PATH = "/etc/frp/frpc.toml"
MIN_PYTHON = (3, 8)
MIN_NODE_MAJOR = 18


class TunnelError(RuntimeError):
    pass


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def die(message: str) -> None:
    raise TunnelError(message)


def env_first(*names: str) -> str | None:
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return None


def tunnel_command() -> str:
    override = os.environ.get("FRP_TUNNEL_COMMAND")
    if override:
        return override
    return "frp-dev-tunnel.cmd" if platform.system() == "Windows" else "frp-dev-tunnel"


def shell_quote(value: str) -> str:
    if platform.system() == "Windows":
        return subprocess.list2cmdline([value])
    return shlex.quote(value)


def command_example(*parts: str) -> str:
    return " ".join([shell_quote(tunnel_command()), *parts])


def config_path() -> Path:
    override = os.environ.get("FRP_TUNNEL_CONFIG")
    if override:
        return Path(override).expanduser()

    if platform.system() == "Windows" and os.environ.get("APPDATA"):
        return Path(os.environ["APPDATA"]) / APP_NAME / "config.json"

    config_home = os.environ.get("XDG_CONFIG_HOME")
    if config_home:
        return Path(config_home).expanduser() / APP_NAME / "config.json"

    return Path.home() / ".config" / APP_NAME / "config.json"


def work_dir() -> Path:
    override = os.environ.get("FRP_TUNNEL_WORK_DIR")
    if override:
        return Path(override).expanduser()
    return Path(tempfile.gettempdir()) / APP_NAME


def default_bin_dir() -> Path:
    override = os.environ.get("FRP_TUNNEL_BIN_DIR")
    if override:
        return Path(override).expanduser()

    if platform.system() == "Windows":
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        if base:
            return Path(base) / APP_NAME / "bin"

    xdg_bin_home = os.environ.get("XDG_BIN_HOME")
    if xdg_bin_home:
        return Path(xdg_bin_home).expanduser()

    return Path.home() / ".local" / "bin"


def load_json_config() -> dict[str, Any]:
    path = config_path()
    if not path.exists():
        return {}
    if not path.read_text(encoding="utf-8", errors="ignore").strip():
        return {}
    try:
        with path.open("r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        die(f"配置文件不是合法 JSON: {path} ({exc})")
    if not isinstance(data, dict):
        die(f"配置文件格式不正确: {path}")
    return data


def save_json_config(config: dict[str, Any]) -> None:
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def strip_inline_comment(line: str) -> str:
    in_quote = False
    escaped = False
    result = []
    for char in line:
        if escaped:
            result.append(char)
            escaped = False
            continue
        if char == "\\":
            result.append(char)
            escaped = True
            continue
        if char == '"':
            in_quote = not in_quote
            result.append(char)
            continue
        if char == "#" and not in_quote:
            break
        result.append(char)
    return "".join(result).strip()


def unquote_toml_value(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        return value[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return value


def parse_source_config() -> dict[str, Any]:
    source = os.environ.get("FRPC_SOURCE_CONFIG")
    if not source:
        return {}

    path = Path(source).expanduser()
    if not path.exists() or not path.is_file():
        eprint(f"warning: FRPC_SOURCE_CONFIG 不存在，已忽略: {path}")
        return {}

    text: str | None = None
    if os.access(path, os.R_OK):
        text = path.read_text(encoding="utf-8", errors="ignore")
    elif platform.system() != "Windows" and shutil.which("sudo"):
        result = subprocess.run(
            ["sudo", "-n", "cat", str(path)],
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if result.returncode == 0:
            text = result.stdout

    if text is None:
        eprint(f"warning: FRPC_SOURCE_CONFIG 不可读，已忽略: {path}")
        return {}

    parsed: dict[str, Any] = {}
    for raw in text.splitlines():
        line = strip_inline_comment(raw)
        match = re.match(r"^([A-Za-z0-9_.-]+)\s*=\s*(.+)$", line)
        if not match:
            continue
        key, value = match.groups()
        value = unquote_toml_value(value)
        if key == "serverAddr":
            parsed["server_addr"] = value
        elif key == "serverPort":
            parsed["server_port"] = value
        elif key in {"auth.token", "token"}:
            parsed["auth_token"] = value
        elif key == "auth.method":
            parsed["auth_method"] = value
        elif key.startswith("transport."):
            parsed[key.replace(".", "_")] = value
    return parsed


def split_host_port(raw: str) -> tuple[str, str | None]:
    value = raw.strip()
    if not value:
        return "", None
    if "://" in value:
        parsed = urllib.parse.urlparse(value)
    else:
        parsed = urllib.parse.urlparse(f"//{value}")
    host = parsed.hostname or value.split("/", 1)[0]
    port = str(parsed.port) if parsed.port else None
    host = host.strip().strip(".")
    if host.startswith("*."):
        host = host[2:]
    return host, port


def normalize_domain(raw: str) -> str:
    host, _ = split_host_port(raw)
    host = host.lower()
    if not host:
        die("域名不能为空")
    if "/" in host or " " in host:
        die(f"域名格式不正确: {raw}")
    return host


def normalize_server_addr(raw: str) -> tuple[str, str | None]:
    host, port = split_host_port(raw)
    if not host:
        die("FRPS 连接域名不能为空")
    if "/" in host or " " in host:
        die(f"FRPS 连接域名格式不正确: {raw}")
    return host, port


def validate_port(raw: Any, label: str = "端口") -> int:
    text = str(raw).strip()
    if not re.fullmatch(r"\d+", text):
        die(f"{label}必须是数字")
    port = int(text)
    if port < 1 or port > 65535:
        die(f"{label}必须在 1-65535 之间")
    return port


def validate_subdomain(subdomain: str) -> None:
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", subdomain):
        die("subdomain 必须是 1-63 位小写字母/数字/连字符，不能包含点号")


def slug_prefix(raw: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")
    slug = re.sub(r"-+", "-", slug)
    return slug or "demo"


def generate_subdomain(prefix: str) -> str:
    suffix = secrets.token_hex(12)
    clean_prefix = slug_prefix(prefix)
    max_prefix_len = 63 - 1 - len(suffix)
    clean_prefix = clean_prefix[:max_prefix_len].rstrip("-") or "demo"
    return f"{clean_prefix}-{suffix}"


def merge_config(args: argparse.Namespace | None = None) -> dict[str, Any]:
    config: dict[str, Any] = {}
    config.update(parse_source_config())
    config.update(load_json_config())

    env_config = {
        "server_addr": env_first("FRP_SERVER_ADDR", "FRPS_SERVER_ADDR"),
        "server_port": env_first("FRP_SERVER_PORT", "FRPS_SERVER_PORT"),
        "auth_token": env_first("FRP_AUTH_TOKEN", "FRPS_TOKEN", "FRP_TOKEN"),
        "public_domain": env_first("FRP_DEV_DOMAIN", "FRP_PUBLIC_DOMAIN"),
        "public_scheme": env_first("FRP_PUBLIC_SCHEME", "FRP_DEV_SCHEME"),
    }
    config.update({k: v for k, v in env_config.items() if v})

    if args:
        for key in ("server_addr", "server_port", "auth_token", "public_domain", "public_scheme"):
            value = getattr(args, key, None)
            if value:
                config[key] = value

    if config.get("server_addr"):
        server_addr, port_from_addr = normalize_server_addr(str(config["server_addr"]))
        config["server_addr"] = server_addr
        if port_from_addr and not config.get("server_port"):
            config["server_port"] = port_from_addr
    if config.get("public_domain"):
        config["public_domain"] = normalize_domain(str(config["public_domain"]))
    if config.get("server_port"):
        config["server_port"] = validate_port(config["server_port"], "FRPS 端口")
    if config.get("public_scheme"):
        public_scheme = str(config["public_scheme"]).lower()
        if public_scheme not in {"http", "https"}:
            die("public_scheme 只能是 http 或 https")
        config["public_scheme"] = public_scheme

    return config


def missing_config_keys(config: dict[str, Any]) -> list[str]:
    keys = []
    for key in ("server_addr", "server_port", "auth_token"):
        if not config.get(key):
            keys.append(key)
    return keys


def prompt_text(label: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{label}{suffix}: ").strip()
    return value or (default or "")


def prompt_secret(label: str, default: str | None = None) -> str:
    suffix = " [保留已有值]" if default else ""
    try:
        value = getpass.getpass(f"{label}{suffix}: ").strip()
    except (EOFError, getpass.GetPassWarning):
        value = input(f"{label}{suffix}: ").strip()
    return value or (default or "")


def ensure_config(config: dict[str, Any], allow_prompt: bool) -> dict[str, Any]:
    if not config.get("public_domain") and config.get("server_addr"):
        config["public_domain"] = config["server_addr"]

    if not missing_config_keys(config):
        return config

    if not allow_prompt or not sys.stdin.isatty():
        config_cmd = (
            command_example(
                "config "
                "--server-addr <frps-domain-or-ip> "
                "--server-port <frps-port> "
                "--token <frps-token>"
            )
        )
        die(
            "缺少 FRPS 连接信息。请先运行交互配置，或设置环境变量 "
            "FRP_SERVER_ADDR / FRP_SERVER_PORT / FRP_AUTH_TOKEN。\n"
            f"示例: {config_cmd}"
        )

    eprint("首次使用需要配置 FRPS 连接信息。Token 会保存到本机配置文件并尽量设置为 0600 权限。")

    if not config.get("server_addr"):
        raw_addr = prompt_text("FRPS 连接域名或 IP（serverAddr，可带端口）")
        server_addr, port_from_addr = normalize_server_addr(raw_addr)
        config["server_addr"] = server_addr
        if port_from_addr and not config.get("server_port"):
            config["server_port"] = port_from_addr

    if not config.get("server_port"):
        config["server_port"] = validate_port(prompt_text("FRPS 连接端口（serverPort）"), "FRPS 端口")
    else:
        config["server_port"] = validate_port(config["server_port"], "FRPS 端口")

    if not config.get("auth_token"):
        config["auth_token"] = prompt_secret("FRPS Token（auth.token）")
        if not config["auth_token"]:
            die("FRPS Token 不能为空")

    if not config.get("public_domain"):
        config["public_domain"] = config["server_addr"]

    save_json_config(config)
    eprint(f"配置已保存: {config_path()}")
    return config


def redacted_config(config: dict[str, Any]) -> dict[str, Any]:
    result = dict(config)
    if result.get("auth_token"):
        result["auth_token"] = "<redacted>"
    return result


def public_scheme(config: dict[str, Any]) -> str:
    return str(config.get("public_scheme") or "http")


def toml_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_frpc_config(config: dict[str, Any], subdomain: str, local_port: int, local_ip: str, config_file: Path) -> None:
    lines = [
        f"serverAddr = {toml_quote(str(config['server_addr']))}",
        f"serverPort = {int(config['server_port'])}",
        'auth.method = "token"',
        f"auth.token = {toml_quote(str(config['auth_token']))}",
    ]

    for source_key, toml_key in (
        ("transport_protocol", "transport.protocol"),
        ("transport_tls_enable", "transport.tls.enable"),
        ("transport_tls_server_name", "transport.tls.serverName"),
    ):
        if source_key in config:
            value = config[source_key]
            if str(value).lower() in {"true", "false"}:
                lines.append(f"{toml_key} = {str(value).lower()}")
            else:
                lines.append(f"{toml_key} = {toml_quote(str(value))}")

    lines.extend(
        [
            "",
            "[[proxies]]",
            f"name = {toml_quote(subdomain)}",
            'type = "http"',
            f"localIP = {toml_quote(local_ip)}",
            f"localPort = {local_port}",
            f"subdomain = {toml_quote(subdomain)}",
        ]
    )

    http_user = os.environ.get("FRP_HTTP_USER")
    http_password = os.environ.get("FRP_HTTP_PASSWORD")
    if http_user and http_password:
        lines.append(f"httpUser = {toml_quote(http_user)}")
        lines.append(f"httpPassword = {toml_quote(http_password)}")

    config_file.parent.mkdir(parents=True, exist_ok=True)
    config_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    try:
        os.chmod(config_file, 0o600)
    except OSError:
        pass


def run_command(command: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def command_output(command: list[str]) -> str | None:
    try:
        result = run_command(command, check=False, capture=True)
    except OSError:
        return None
    output = (result.stdout or result.stderr or "").strip()
    return output or None


def parse_node_major(version: str | None) -> int | None:
    if not version:
        return None
    match = re.search(r"v?(\d+)", version)
    return int(match.group(1)) if match else None


def install_hint(packages: list[str]) -> list[str]:
    packages = sorted(set(packages))
    if not packages:
        return []

    system = platform.system()
    has_python = "python" in packages
    has_node = "node" in packages

    if system == "Darwin":
        names = []
        if has_python:
            names.append("python")
        if has_node:
            names.append("node")
        if shutil.which("brew"):
            return [f"brew install {' '.join(names)}"]
        return [f"先安装 Homebrew，然后运行: brew install {' '.join(names)}"]

    if system == "Windows":
        commands = []
        if has_python:
            commands.append("winget install -e --id Python.Python.3.12")
        if has_node:
            commands.append("winget install -e --id OpenJS.NodeJS.LTS")
        if shutil.which("winget"):
            return commands
        return ["安装 winget 后运行: " + " && ".join(commands)]

    if shutil.which("apt-get"):
        names = []
        if has_python:
            names.append("python3")
        if has_node:
            names.extend(["nodejs", "npm"])
        return [f"sudo apt-get update && sudo apt-get install -y {' '.join(names)}"]
    if shutil.which("dnf"):
        names = []
        if has_python:
            names.append("python3")
        if has_node:
            names.extend(["nodejs", "npm"])
        return [f"sudo dnf install -y {' '.join(names)}"]
    if shutil.which("pacman"):
        names = []
        if has_python:
            names.append("python")
        if has_node:
            names.extend(["nodejs", "npm"])
        return [f"sudo pacman -S --needed {' '.join(names)}"]
    if shutil.which("apk"):
        names = []
        if has_python:
            names.append("python3")
        if has_node:
            names.extend(["nodejs", "npm"])
        return [f"sudo apk add {' '.join(names)}"]
    if shutil.which("zypper"):
        names = []
        if has_python:
            names.append("python3")
        if has_node:
            names.extend(["nodejs", "npm"])
        return [f"sudo zypper install -y {' '.join(names)}"]

    return ["请安装 Python 3.8+ 和 Node.js 18+；安装完成后重新运行 doctor"]


def docker_base_command() -> list[str] | None:
    if not shutil.which("docker"):
        return None
    try:
        run_command(["docker", "info"], check=True, capture=True)
        return ["docker"]
    except (OSError, subprocess.CalledProcessError):
        if platform.system() != "Windows" and shutil.which("sudo"):
            try:
                run_command(["sudo", "-n", "docker", "info"], check=True, capture=True)
                return ["sudo", "-n", "docker"]
            except (OSError, subprocess.CalledProcessError):
                return None
    return None


def docker_run(args: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    base = docker_base_command()
    if not base:
        die("Docker 不可用；请安装 frpc 本地二进制，或让当前用户可访问 Docker")
    return run_command(base + args, check=check, capture=capture)


def frpc_binary() -> str | None:
    override = os.environ.get("FRPC_BIN")
    if override:
        path = Path(override).expanduser()
        if path.exists():
            return str(path)
        found = shutil.which(override)
        if found:
            return found
        die(f"FRPC_BIN 指向的 frpc 不存在: {override}")
    found = shutil.which("frpc")
    if found:
        return found

    bundled_name = "frpc.exe" if platform.system() == "Windows" else "frpc"
    bundled = default_bin_dir() / bundled_name
    if bundled.exists():
        return str(bundled)
    return None


def choose_runner(requested: str | None = None) -> str:
    runner = (requested or os.environ.get("FRP_RUNNER") or "auto").lower()
    if runner not in {"auto", "local", "docker"}:
        die("FRP_RUNNER 只能是 auto、local 或 docker")
    if runner == "local":
        if not frpc_binary():
            die(f"未找到 frpc；请运行 {command_example('install-frpc')}，或在已有 Docker 时使用 FRP_RUNNER=docker")
        return "local"
    if runner == "docker":
        if not docker_base_command():
            die(f"Docker 不可用。请不要为了此 skill 安装 Docker；运行 {command_example('install-frpc')} 后使用本地 frpc")
        return "docker"
    if frpc_binary():
        return "local"
    if docker_base_command():
        return "docker"
    die(f"未找到 frpc，也没有可复用的 Docker。请运行 {command_example('install-frpc')} 安装轻量 frpc 客户端")


def normalize_arch(raw: str) -> str:
    machine = raw.lower()
    if machine in {"x86_64", "amd64"}:
        return "amd64"
    if machine in {"aarch64", "arm64"}:
        return "arm64"
    if machine in {"i386", "i686", "x86"}:
        return "386"
    if machine.startswith("armv7"):
        return "arm"
    die(f"暂不支持当前 CPU 架构: {raw}")


def frp_release_asset(version: str) -> tuple[str, str]:
    system = platform.system()
    if system == "Darwin":
        os_name = "darwin"
        ext = "tar.gz"
    elif system == "Linux":
        os_name = "linux"
        ext = "tar.gz"
    elif system == "Windows":
        os_name = "windows"
        ext = "zip"
    else:
        die(f"暂不支持当前系统自动安装 frpc: {system}")

    arch = normalize_arch(platform.machine())
    base = f"frp_{version}_{os_name}_{arch}"
    filename = f"{base}.{ext}"
    url = f"https://github.com/fatedier/frp/releases/download/v{version}/{filename}"
    return url, base


def extract_frpc(archive: Path, base_dir_name: str, target: Path) -> None:
    wanted = f"{base_dir_name}/frpc.exe" if platform.system() == "Windows" else f"{base_dir_name}/frpc"
    target.parent.mkdir(parents=True, exist_ok=True)

    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            member = next((name for name in zf.namelist() if name.replace("\\", "/") == wanted), None)
            if not member:
                die("下载包里没有找到 frpc")
            with zf.open(member) as src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)
    else:
        with tarfile.open(archive, "r:gz") as tf:
            member = next((item for item in tf.getmembers() if item.name == wanted), None)
            if not member:
                die("下载包里没有找到 frpc")
            src = tf.extractfile(member)
            if not src:
                die("无法读取 frpc 文件")
            with src, target.open("wb") as dst:
                shutil.copyfileobj(src, dst)

    if platform.system() != "Windows":
        current_mode = target.stat().st_mode
        target.chmod(current_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def install_frpc(args: argparse.Namespace) -> None:
    existing = frpc_binary()
    if existing and not args.force:
        print(f"frpc 已存在: {existing}")
        return

    version = args.version
    url, base_dir_name = frp_release_asset(version)
    target_dir = Path(args.bin_dir).expanduser() if args.bin_dir else default_bin_dir()
    target_name = "frpc.exe" if platform.system() == "Windows" else "frpc"
    target = target_dir / target_name

    print(f"Downloading frpc {version}: {url}")
    with tempfile.TemporaryDirectory(prefix=f"{APP_NAME}-") as tmp:
        archive = Path(tmp) / Path(urllib.parse.urlparse(url).path).name
        try:
            urllib.request.urlretrieve(url, archive)
        except Exception as exc:
            die(f"下载 frpc 失败: {exc}")
        extract_frpc(archive, base_dir_name, target)

    print(f"frpc installed: {target}")
    if shutil.which("frpc") or str(target.parent) in os.environ.get("PATH", "").split(os.pathsep):
        print("frpc is ready.")
    elif platform.system() == "Windows":
        print(f"当前终端可用: set FRPC_BIN={target}")
        print(f"持久添加 PATH: setx PATH \"%PATH%;{target.parent}\"")
    else:
        shell_rc = "~/.zshrc" if os.environ.get("SHELL", "").endswith("zsh") else "~/.bashrc"
        print(f"当前终端可用: export FRPC_BIN={target}")
        print(f"持久添加 PATH: echo 'export PATH=\"{target.parent}:$PATH\"' >> {shell_rc}")


def bootstrap_client(args: argparse.Namespace) -> None:
    configure(args)

    if not args.skip_install_frpc and not frpc_binary():
        install_args = argparse.Namespace(
            version=args.frp_version,
            bin_dir=args.bin_dir,
            force=False,
        )
        install_frpc(install_args)

    if not args.skip_doctor:
        check_environment(argparse.Namespace())

    print("")
    print("Next:")
    print("  1. Validate the tunnel with the tiny smoke project:")
    print(f"     {command_example('smoke-test')}")
    print("  2. If smoke-test works, start your real dev server on a known port.")
    print(f"  3. Run: {command_example('start-auto', args.prefix, '<local-port>')}")


def check_environment(_: argparse.Namespace) -> None:
    failures: list[str] = []
    missing_install_packages: list[str] = []
    warnings: list[str] = []

    py_version = sys.version_info
    if py_version < MIN_PYTHON:
        failures.append(f"Python 版本过低: {platform.python_version()}，需要 {MIN_PYTHON[0]}.{MIN_PYTHON[1]}+")
        missing_install_packages.append("python")
    else:
        print(f"OK Python: {platform.python_version()} ({sys.executable})")

    node_version = command_output(["node", "--version"])
    node_major = parse_node_major(node_version)
    if node_major is None:
        failures.append(f"Node.js 未安装，需要 {MIN_NODE_MAJOR}+，用于启动多数前端/Node 开发服务器")
        missing_install_packages.append("node")
    elif node_major < MIN_NODE_MAJOR:
        failures.append(f"Node.js 版本过低: {node_version}，需要 {MIN_NODE_MAJOR}+")
        missing_install_packages.append("node")
    else:
        npm_version = command_output(["npm", "--version"])
        suffix = f", npm {npm_version}" if npm_version else ""
        print(f"OK Node.js: {node_version}{suffix}")

    frpc = frpc_binary()
    docker = docker_base_command()
    if frpc:
        print(f"OK frpc: {frpc}")
    elif docker:
        print("OK Docker: 已存在，可作为临时 frpc 运行器")
        warnings.append("未找到本地 frpc；Docker 只作为已有环境的兼容 fallback，不建议为了此 skill 安装 Docker")
        warnings.append(f"更轻量的本地路径: {command_example('install-frpc')}")
    else:
        failures.append("未找到 frpc，也没有可复用的 Docker；请安装轻量 frpc 客户端，不要为了此 skill 安装 Docker")

    config = merge_config()
    missing = missing_config_keys(config)
    if missing:
        failures.append("FRPS 配置不完整，缺少: " + ", ".join(missing))
    else:
        print(f"OK FRPS: {config['server_addr']}:{config['server_port']} -> *.{config.get('public_domain') or config['server_addr']}")

    if warnings:
        print("\nWarnings:")
        for item in warnings:
            print(f"- {item}")

    hints = install_hint(missing_install_packages)
    if hints:
        print("\nInstall missing runtime dependencies:")
        for command in hints:
            print(f"  {command}")

    if not frpc and not docker:
        print("\nInstall frpc:")
        print(f"  {command_example('install-frpc')}")

    if missing:
        print("\nConfigure FRPS:")
        print(f"  {command_example('config')}")
        print("  # 无交互环境可用:")
        print(f"  {command_example('config --server-addr <frps-domain-or-ip> --server-port <frps-port> --token <frps-token>')}")

    if failures:
        print("\nFailures:")
        for item in failures:
            print(f"- {item}")
        raise TunnelError("环境检查未通过")

    print("\nEnvironment is ready.")


def default_local_ip(runner: str) -> str:
    if runner == "docker" and platform.system() in {"Darwin", "Windows"}:
        return "host.docker.internal"
    return "127.0.0.1"


def find_free_local_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def container_prefix() -> str:
    return os.environ.get("FRP_CONTAINER_PREFIX", "gt-frpc")


def container_name(subdomain: str) -> str:
    return f"{container_prefix()}-{subdomain}"


def state_file(subdomain: str) -> Path:
    return work_dir() / subdomain / "state.json"


def write_state(subdomain: str, state: dict[str, Any]) -> None:
    path = state_file(subdomain)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def read_state(subdomain: str) -> dict[str, Any]:
    path = state_file(subdomain)
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}


def pid_exists(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False


def start_local_frpc(subdomain: str, config_file: Path, log_file: Path) -> None:
    binary = frpc_binary()
    if not binary:
        die("未找到 frpc 本地二进制")

    log_file.parent.mkdir(parents=True, exist_ok=True)
    log = log_file.open("ab")
    creationflags = 0
    start_new_session = False
    if platform.system() == "Windows":
        creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        start_new_session = True

    process = subprocess.Popen(
        [binary, "-c", str(config_file)],
        stdout=log,
        stderr=subprocess.STDOUT,
        cwd=str(config_file.parent),
        start_new_session=start_new_session,
        creationflags=creationflags,
    )
    time.sleep(2)
    if process.poll() is not None:
        tail_log(log_file)
        die("frpc 进程已退出")

    write_state(
        subdomain,
        {
            "runner": "local",
            "pid": process.pid,
            "config_file": str(config_file),
            "log_file": str(log_file),
            "started_at": int(time.time()),
        },
    )


def start_docker_frpc(subdomain: str, config_file: Path) -> None:
    name = container_name(subdomain)
    image = os.environ.get("FRPC_IMAGE", DEFAULT_IMAGE)
    docker_run(["rm", "-f", name], check=False, capture=True)

    run_args = ["run", "-d", "--name", name]
    if platform.system() == "Linux":
        run_args.extend(["--network", "host"])
    run_args.extend(
        [
            "-v",
            f"{config_file}:{CONTAINER_CONFIG_PATH}:ro",
            "--entrypoint",
            "/usr/bin/frpc",
            image,
            "-c",
            CONTAINER_CONFIG_PATH,
        ]
    )
    docker_run(run_args, check=True, capture=True)
    time.sleep(2)

    result = docker_run(
        ["ps", "--filter", f"name=^/{name}$", "--filter", "status=running", "--format", "{{.Names}}"],
        check=True,
        capture=True,
    )
    if name not in result.stdout.splitlines():
        logs = docker_run(["logs", name], check=False, capture=True)
        eprint(redact_text(logs.stdout + logs.stderr))
        die("frpc 容器已退出")

    write_state(
        subdomain,
        {
            "runner": "docker",
            "container": name,
            "config_file": str(config_file),
            "started_at": int(time.time()),
        },
    )
    logs = docker_run(["logs", "--tail=40", name], check=False, capture=True)
    if logs.stdout or logs.stderr:
        eprint(redact_text(logs.stdout + logs.stderr))


def start_tunnel(args: argparse.Namespace, print_url: bool = True) -> str:
    subdomain = args.subdomain
    validate_subdomain(subdomain)
    local_port = validate_port(args.local_port, "本地端口")
    runner = choose_runner(args.runner)
    local_ip = args.local_ip or default_local_ip(runner)

    config = ensure_config(merge_config(), allow_prompt=True)
    directory = work_dir() / subdomain
    config_file = directory / "frpc.toml"
    log_file = directory / "frpc.log"

    stop_tunnel_by_subdomain(subdomain, quiet=True)
    write_frpc_config(config, subdomain, local_port, local_ip, config_file)

    if runner == "local":
        start_local_frpc(subdomain, config_file, log_file)
    else:
        start_docker_frpc(subdomain, config_file)

    url = f"{public_scheme(config)}://{subdomain}.{config['public_domain']}/"
    if print_url:
        print(url)
    return url


def start_auto_tunnel(args: argparse.Namespace) -> None:
    args.subdomain = generate_subdomain(args.prefix)
    start_tunnel(args)


def start_static_smoke_server(site_dir: Path, port: int, log_file: Path) -> subprocess.Popen[bytes]:
    site_dir.mkdir(parents=True, exist_ok=True)
    (site_dir / "index.html").write_text(
        """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>FRP smoke test</title>
</head>
<body>
  <main>
    <h1>FRP smoke test OK</h1>
    <p>This tiny page is served from your local machine through frp.</p>
  </main>
</body>
</html>
""",
        encoding="utf-8",
    )
    log_file.parent.mkdir(parents=True, exist_ok=True)
    log = log_file.open("ab")
    start_new_session = platform.system() != "Windows"
    creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) if platform.system() == "Windows" else 0
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "http.server",
            str(port),
            "--bind",
            "127.0.0.1",
            "--directory",
            str(site_dir),
        ],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=start_new_session,
        creationflags=creationflags,
    )
    time.sleep(1)
    if process.poll() is not None:
        tail_log(log_file)
        die("smoke-test 静态服务启动失败")
    return process


def smoke_test(args: argparse.Namespace) -> None:
    ensure_config(merge_config(), allow_prompt=True)
    port = validate_port(args.port, "smoke-test 端口") if args.port else find_free_local_port()
    subdomain = generate_subdomain(args.prefix)
    smoke_dir = work_dir() / f"{subdomain}-smoke-site"
    smoke_log = work_dir() / f"{subdomain}-smoke.log"

    process = start_static_smoke_server(smoke_dir, port, smoke_log)
    try:
        tunnel_args = argparse.Namespace(
            subdomain=subdomain,
            local_port=str(port),
            local_ip="127.0.0.1",
            runner=args.runner,
        )
        url = start_tunnel(tunnel_args, print_url=False)
    except Exception:
        stop_local_pid(process.pid)
        shutil.rmtree(smoke_dir, ignore_errors=True)
        raise

    state = read_state(subdomain)
    state.update(
        {
            "smoke_server_pid": process.pid,
            "smoke_site_dir": str(smoke_dir),
            "smoke_log_file": str(smoke_log),
            "smoke_local_port": port,
        }
    )
    write_state(subdomain, state)

    config = ensure_config(merge_config(), allow_prompt=False)
    print("")
    print("Smoke test project:")
    print(f"  local:  http://127.0.0.1:{port}/")
    print(f"  public: {url}")

    if not args.no_verify:
        print("")
        print("Verifying public URL...")
        try:
            verify_tunnel(argparse.Namespace(subdomain=subdomain, path="/"))
        except TunnelError as exc:
            eprint(f"warning: smoke-test verify failed: {exc}")
            eprint("warning: tunnel is still running; inspect the public URL or run logs/status.")

    print("")
    print("If the smoke page works, use this skill in any other project:")
    print("  1. Start that project's dev server on a known local port.")
    print(f"  2. Run: {command_example('start-auto <project-name> <local-port>')}")
    print(f"  3. Stop this smoke test when done: {command_example('stop', subdomain)}")


def stop_local_pid(pid: int) -> None:
    if platform.system() == "Windows":
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    try:
        os.killpg(pid, signal.SIGTERM)
    except OSError:
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
    time.sleep(1)
    if pid_exists(pid):
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass


def stop_tunnel_by_subdomain(subdomain: str, quiet: bool = False) -> None:
    validate_subdomain(subdomain)
    state = read_state(subdomain)
    if state.get("smoke_server_pid"):
        stop_local_pid(int(state["smoke_server_pid"]))
    if state.get("smoke_site_dir"):
        shutil.rmtree(str(state["smoke_site_dir"]), ignore_errors=True)
    if state.get("smoke_log_file"):
        try:
            Path(str(state["smoke_log_file"])).unlink()
        except FileNotFoundError:
            pass
    if state.get("runner") == "local" and state.get("pid"):
        stop_local_pid(int(state["pid"]))
    else:
        name = state.get("container") or container_name(subdomain)
        try:
            docker_run(["rm", "-f", str(name)], check=False, capture=True)
        except TunnelError:
            if not quiet:
                eprint("warning: Docker 不可用，跳过容器清理")
    directory = work_dir() / subdomain
    if directory.exists():
        shutil.rmtree(directory, ignore_errors=True)


def stop_tunnel(args: argparse.Namespace) -> None:
    stop_tunnel_by_subdomain(args.subdomain)


def redact_text(text: str) -> str:
    text = re.sub(r"(auth\.token\s*=\s*)\"[^\"]+\"", r'\1"<redacted>"', text, flags=re.I)
    text = re.sub(r"(httpPassword\s*=\s*)\"[^\"]+\"", r'\1"<redacted>"', text, flags=re.I)
    text = re.sub(r"(?i)(token|password)=\S+", r"\1=<redacted>", text)
    return text


def tail_log(path: Path, lines: int = 120) -> None:
    if not path.exists():
        return
    data = path.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in data[-lines:]:
        print(redact_text(line))


def logs_tunnel(args: argparse.Namespace) -> None:
    validate_subdomain(args.subdomain)
    state = read_state(args.subdomain)
    if state.get("runner") == "local" and state.get("log_file"):
        tail_log(Path(state["log_file"]))
        return
    name = state.get("container") or container_name(args.subdomain)
    logs = docker_run(["logs", "--tail=120", str(name)], check=False, capture=True)
    print(redact_text(logs.stdout + logs.stderr), end="")


def print_verify_hint(status: int, body: str, config: dict[str, Any]) -> None:
    lowered = body.lower()
    if status == 403 and ("allowedhosts" in lowered or "blocked request" in lowered):
        domain = config.get("public_domain") or "<public-domain>"
        print("")
        print("Hint: the request reached the local dev server, but the Host header was rejected.")
        print("For Vite, ask before changing the project, then add a narrow allowedHosts rule, for example:")
        print(f"  server: {{ allowedHosts: ['.{domain}'] }}")
    elif status in {502, 503, 504}:
        print("")
        print("Hint: the public gateway answered, but it could not reach the local service.")
        print("Check that the local dev server is running on the same port used by start/start-auto.")


def verify_tunnel(args: argparse.Namespace) -> None:
    validate_subdomain(args.subdomain)
    config = ensure_config(merge_config(), allow_prompt=False)
    path = args.path if args.path.startswith("/") else f"/{args.path}"
    url = f"{public_scheme(config)}://{args.subdomain}.{config['public_domain']}{path}"
    request = urllib.request.Request(url, method="GET", headers={"Cache-Control": "no-cache"})
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl._create_unverified_context()),
    )
    try:
        with opener.open(request, timeout=10) as response:
            print(f"HTTP {response.status} {response.reason}")
            for key, value in response.headers.items():
                print(f"{key}: {value}")
    except urllib.error.HTTPError as exc:
        print(f"HTTP {exc.code} {exc.reason}")
        for key, value in exc.headers.items():
            print(f"{key}: {value}")
        body = exc.read(2048).decode("utf-8", errors="replace")
        print_verify_hint(exc.code, body, config)
    except Exception as exc:
        die(f"验证失败: {exc}")


def status_tunnels(_: argparse.Namespace) -> None:
    base = work_dir()
    print(f"Work dir: {base}")
    if base.exists():
        for state_path in sorted(base.glob("*/state.json")):
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                continue
            subdomain = state_path.parent.name
            runner = state.get("runner", "?")
            detail = state.get("pid") or state.get("container") or ""
            print(f"{subdomain}\t{runner}\t{detail}")

    if docker_base_command():
        result = docker_run(
            ["ps", "-a", "--filter", f"name={container_prefix()}-", "--format", "table {{.Names}}\t{{.Status}}\t{{.Image}}"],
            check=False,
            capture=True,
        )
        if result.stdout.strip():
            print(result.stdout, end="")


def configure(args: argparse.Namespace) -> None:
    config = merge_config(args)

    if args.server_addr:
        server_addr, port_from_addr = normalize_server_addr(args.server_addr)
        config["server_addr"] = server_addr
        if port_from_addr and not args.server_port:
            config["server_port"] = validate_port(port_from_addr, "FRPS 端口")
    if args.public_domain:
        config["public_domain"] = normalize_domain(args.public_domain)
    elif config.get("server_addr") and not config.get("public_domain"):
        config["public_domain"] = config["server_addr"]
    if args.public_scheme:
        config["public_scheme"] = args.public_scheme

    config = ensure_config(config, allow_prompt=not args.no_prompt)
    save_json_config(config)
    print(f"配置已保存: {config_path()}")
    print(json.dumps(redacted_config(config), indent=2, ensure_ascii=False))


def show_config(_: argparse.Namespace) -> None:
    config = ensure_config(merge_config(), allow_prompt=False)
    print(json.dumps(redacted_config(config), indent=2, ensure_ascii=False))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Expose a local dev server through an frp HTTP subdomain tunnel.",
    )
    parser.add_argument("--runner", choices=["auto", "local", "docker"], help="Runner to use. Defaults to FRP_RUNNER or auto.")
    subparsers = parser.add_subparsers(dest="command")

    start = subparsers.add_parser("start", help="Start or replace a temporary tunnel.")
    start.add_argument("subdomain")
    start.add_argument("local_port")
    start.add_argument("local_ip", nargs="?")
    start.set_defaults(func=start_tunnel)

    start_auto = subparsers.add_parser("start-auto", help="Start with a generated high-entropy subdomain.")
    start_auto.add_argument("prefix")
    start_auto.add_argument("local_port")
    start_auto.add_argument("local_ip", nargs="?")
    start_auto.set_defaults(func=start_auto_tunnel)

    smoke = subparsers.add_parser("smoke-test", help="Run a tiny static test page through frp before exposing a real project.")
    smoke.add_argument("--prefix", default="smoke", help="Subdomain prefix. Default: smoke.")
    smoke.add_argument("--port", help="Optional local port for the tiny static test server.")
    smoke.add_argument("--no-verify", action="store_true", help="Skip public URL verification after starting.")
    smoke.set_defaults(func=smoke_test)

    stop = subparsers.add_parser("stop", help="Stop and remove one tunnel.")
    stop.add_argument("subdomain")
    stop.set_defaults(func=stop_tunnel)

    logs = subparsers.add_parser("logs", help="Print logs for one tunnel.")
    logs.add_argument("subdomain")
    logs.set_defaults(func=logs_tunnel)

    verify = subparsers.add_parser("verify", help="Verify the public URL without using proxy env vars.")
    verify.add_argument("subdomain")
    verify.add_argument("path", nargs="?", default="/")
    verify.set_defaults(func=verify_tunnel)

    status = subparsers.add_parser("status", help="Show managed temporary tunnels.")
    status.set_defaults(func=status_tunnels)

    doctor = subparsers.add_parser("doctor", help="Check Python, Node.js, frpc/Docker, and FRPS config.")
    doctor.set_defaults(func=check_environment)

    install = subparsers.add_parser("install-frpc", help="Install a lightweight frpc binary into the user bin directory.")
    install.add_argument("--version", default=DEFAULT_FRP_VERSION, help=f"frp release version. Default: {DEFAULT_FRP_VERSION}.")
    install.add_argument("--bin-dir", help="Install directory. Default: FRP_TUNNEL_BIN_DIR or user-local bin.")
    install.add_argument("--force", action="store_true", help="Reinstall even when frpc already exists.")
    install.set_defaults(func=install_frpc)

    config = subparsers.add_parser("config", help="Configure FRPS connection details.")
    config.add_argument("--server-addr", dest="server_addr", help="FRPS serverAddr domain or IP. May include :port.")
    config.add_argument("--server-port", dest="server_port", help="FRPS serverPort.")
    config.add_argument("--token", dest="auth_token", help="FRPS auth token.")
    config.add_argument("--public-domain", dest="public_domain", help="Wildcard/subdomain host used for printed URLs.")
    config.add_argument("--public-scheme", dest="public_scheme", choices=["http", "https"], help="Public URL scheme printed by start/verify.")
    config.add_argument("--no-prompt", action="store_true", help="Fail instead of prompting for missing values.")
    config.set_defaults(func=configure)

    bootstrap = subparsers.add_parser("bootstrap", help="Configure this client, install frpc if needed, and run doctor.")
    bootstrap.add_argument("--server-addr", dest="server_addr", required=True, help="FRPS serverAddr domain or IP. May include :port.")
    bootstrap.add_argument("--server-port", dest="server_port", required=True, help="FRPS serverPort.")
    bootstrap.add_argument("--token", dest="auth_token", required=True, help="FRPS auth token.")
    bootstrap.add_argument("--public-domain", dest="public_domain", required=True, help="Wildcard/subdomain host used for printed URLs.")
    bootstrap.add_argument("--public-scheme", dest="public_scheme", choices=["http", "https"], default="http", help="Public URL scheme printed by start/verify.")
    bootstrap.add_argument("--frp-version", default=DEFAULT_FRP_VERSION, help=f"frp release version for install-frpc. Default: {DEFAULT_FRP_VERSION}.")
    bootstrap.add_argument("--bin-dir", help="Install directory for frpc. Default: FRP_TUNNEL_BIN_DIR or user-local bin.")
    bootstrap.add_argument("--prefix", default="demo", help="Suggested start-auto prefix printed at the end.")
    bootstrap.add_argument("--skip-install-frpc", action="store_true", help="Do not install frpc even when missing.")
    bootstrap.add_argument("--skip-doctor", action="store_true", help="Do not run doctor after config/install.")
    bootstrap.add_argument("--no-prompt", action="store_true", default=True, help=argparse.SUPPRESS)
    bootstrap.set_defaults(func=bootstrap_client)

    show = subparsers.add_parser("show-config", help="Print the effective config with secrets redacted.")
    show.set_defaults(func=show_config)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.print_help()
        return 0
    try:
        args.func(args)
    except TunnelError as exc:
        eprint(f"error: {exc}")
        return 1
    except KeyboardInterrupt:
        eprint("aborted")
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
