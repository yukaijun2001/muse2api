#!/usr/bin/env bash
# 一键安装 / 更新：sudo bash deploy.sh
set -Eeuo pipefail

REPO_URL=${MUSE2API_REPO_URL:-https://github.com/yukaijun2001/muse2api.git}
BRANCH=${MUSE2API_BRANCH:-main}
INSTALL_DIR=${MUSE2API_INSTALL_DIR:-}
DOCKER=(docker)

log() { printf '\n[muse2api] %s\n' "$*"; }
die() { printf '\n[muse2api] 错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
用法：sudo bash deploy.sh

自动安装依赖与 Docker、更新 GitHub 代码、生成并保存密钥，然后构建启动服务。
默认仓库：https://github.com/yukaijun2001/muse2api.git，分支：main
默认目录：已有项目内运行时使用当前项目，否则 root 使用 /opt/muse2api，普通用户使用 ~/muse2api。
默认端口：10002。首次使用仍需在管理面板导入 Muse 账号。

可选环境变量（无需修改 .env）：
  MUSE2API_INSTALL_DIR   自定义安装目录
  MUSE2API_REPO_URL      自定义 Git 仓库
  MUSE2API_BRANCH        自定义分支
  MUSE2API_PORT          对外端口，默认 10002
  MUSE2API_KEY           指定密钥；默认自动生成，后续更新保留
  MUSE2API_PUBLIC_BASE   对外地址，如 https://api.example.com
HELP
}

as_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        die "安装系统依赖需要 root 权限，请使用 root 运行此脚本或安装 sudo。"
    fi
}

install_dependencies() {
    local missing=0 tool
    for tool in git curl python3; do
        command -v "$tool" >/dev/null 2>&1 || missing=1
    done
    [[ $missing -eq 1 ]] || return 0
    [[ $PLATFORM == Linux ]] || die "请先安装 Git、curl 和 Python 3，再重新运行。"

    log "安装 Git、curl、Python 3 与 CA 证书"
    if command -v apt-get >/dev/null 2>&1; then
        as_root apt-get update
        as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl git python3
    elif command -v dnf >/dev/null 2>&1; then
        as_root dnf install -y ca-certificates curl git python3
    elif command -v yum >/dev/null 2>&1; then
        as_root yum install -y ca-certificates curl git python3
    else
        die "未找到 apt-get / dnf / yum，请先安装 Git、curl 与 Python 3。"
    fi
}

install_docker_plugin() {
    local plugin=$1 installer url
    [[ $PLATFORM == Linux ]] || die "请更新 Docker Desktop，以启用 Docker $plugin。"
    log "安装 Docker $plugin 插件"
    case $plugin in
        compose) url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" ;;
        buildx)
            url=$(curl -fsSL --retry 3 https://api.github.com/repos/docker/buildx/releases/latest | \
                python3 -c 'import json,sys; release=json.load(sys.stdin); arch={"x86_64":"amd64","aarch64":"arm64","arm64":"arm64"}.get(sys.argv[1],sys.argv[1]); print(next(a["browser_download_url"] for a in release["assets"] if a["name"].endswith(".linux-"+arch)))' "$(uname -m)")
            ;;
    esac
    installer=$(mktemp)
    if ! curl -fsSL --retry 3 "$url" -o "$installer"; then
        rm -f "$installer"
        die "下载 Docker $plugin 失败，请检查服务器到 GitHub 的网络。"
    fi
    as_root install -d -m 755 /usr/local/lib/docker/cli-plugins
    as_root install -m 755 "$installer" "/usr/local/lib/docker/cli-plugins/docker-$plugin"
    rm -f "$installer"
    "${DOCKER[@]}" "$plugin" version >/dev/null 2>&1 || die "Docker $plugin 插件不可用。"
}

ensure_docker() {
    local installer attempt
    if ! command -v docker >/dev/null 2>&1; then
        [[ $PLATFORM == Linux ]] || die "macOS 请先安装 Docker Desktop：https://www.docker.com/products/docker-desktop/"
        log "通过 Docker 官方安装脚本安装 Docker Engine 与 Compose"
        installer=$(mktemp)
        if ! curl -fsSL --retry 3 https://get.docker.com -o "$installer"; then
            rm -f "$installer"
            die "下载 Docker 官方安装脚本失败，请检查服务器网络。"
        fi
        if ! as_root sh "$installer"; then
            rm -f "$installer"
            die "Docker 安装失败，请查看上方安装日志。"
        fi
        rm -f "$installer"
    fi

    if docker info >/dev/null 2>&1; then
        DOCKER=(docker)
    elif [[ $PLATFORM == Linux ]]; then
        if ! as_root docker info >/dev/null 2>&1; then
            log "启动 Docker，并设置开机启动"
            if command -v systemctl >/dev/null 2>&1; then
                as_root systemctl enable --now docker
            elif command -v service >/dev/null 2>&1; then
                as_root service docker start
            else
                die "无法自动启动 Docker，请启动 Docker 后重新运行。"
            fi
        fi
        if [[ $EUID -eq 0 ]]; then DOCKER=(docker); else DOCKER=(sudo docker); fi
    else
        log "启动 Docker Desktop"
        open -a Docker || die "无法启动 Docker Desktop。"
        for ((attempt = 0; attempt < 60; attempt++)); do
            docker info >/dev/null 2>&1 && break
            sleep 2
        done
    fi
    "${DOCKER[@]}" info >/dev/null 2>&1 || die "Docker 未就绪，请检查 Docker 服务。"

    if ! "${DOCKER[@]}" compose version >/dev/null 2>&1; then
        install_docker_plugin compose
    fi
    if ! "${DOCKER[@]}" buildx version >/dev/null 2>&1; then
        install_docker_plugin buildx
    fi
}

update_source() {
    local script_dir repo_root
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
    if [[ -z $INSTALL_DIR ]]; then
        if [[ -e $script_dir/.git && -f $script_dir/docker-compose.yml ]]; then
            INSTALL_DIR=$script_dir
        elif [[ $EUID -eq 0 ]]; then
            INSTALL_DIR=/opt/muse2api
        else
            INSTALL_DIR=$HOME/muse2api
        fi
    fi
    [[ $INSTALL_DIR == /* ]] || INSTALL_DIR=$PWD/$INSTALL_DIR

    if [[ -e $INSTALL_DIR/.git ]]; then
        repo_root=$(git -C "$INSTALL_DIR" rev-parse --show-toplevel)
        [[ $(cd -- "$INSTALL_DIR" && pwd -P) == "$(cd -- "$repo_root" && pwd -P)" ]] || die "安装目录必须是 Git 仓库根目录。"
        [[ $(git -C "$INSTALL_DIR" branch --show-current) == "$BRANCH" ]] || die "当前分支不是 $BRANCH，请先切换分支或设置 MUSE2API_BRANCH。"
        if ! git -C "$INSTALL_DIR" diff --quiet || ! git -C "$INSTALL_DIR" diff --cached --quiet; then
            die "安装目录存在未提交的代码修改，请先提交或保存后重试；不会覆盖本地代码、.env 或 data/。"
        fi
        log "从 origin 更新 $BRANCH 分支（仅允许快进合并）"
        git -C "$INSTALL_DIR" fetch --prune origin "$BRANCH"
        git -C "$INSTALL_DIR" merge --ff-only FETCH_HEAD
    else
        log "克隆 $REPO_URL 的 $BRANCH 分支到 $INSTALL_DIR"
        mkdir -p -- "$(dirname -- "$INSTALL_DIR")"
        git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$INSTALL_DIR"
    fi
    INSTALL_DIR=$(cd -- "$INSTALL_DIR" && pwd -P)
    [[ -f $INSTALL_DIR/docker-compose.yml && -f $INSTALL_DIR/.env.example ]] || die "仓库缺少 docker-compose.yml 或 .env.example。"
}

compose() {
    "${DOCKER[@]}" compose --project-name muse2api --project-directory "$INSTALL_DIR" \
        --env-file "$INSTALL_DIR/.env" -f "$INSTALL_DIR/docker-compose.yml" "$@"
}

configure_environment() {
    local settings
    log "配置环境变量（已有密钥与数据会保留）"
    settings=$(python3 - "$INSTALL_DIR" "${DOCKER[@]}" <<'PY'
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

root = Path(sys.argv[1])
target = root / ".env"

def save(text):
    fd, name = tempfile.mkstemp(prefix=".env.deploy-", dir=root)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(name, 0o600)
        os.replace(name, target)
    finally:
        if os.path.exists(name):
            os.unlink(name)

if not target.exists():
    save((root / ".env.example").read_text(encoding="utf-8"))
os.chmod(target, 0o600)

# 用 Compose 自身解析 .env，支持引号、注释与变量插值，避免执行配置内容。
result = subprocess.run(
    [*sys.argv[2:], "compose", "--project-directory", str(root),
     "--env-file", str(target), "-f", str(root / "docker-compose.yml"),
     "config", "--environment"],
    capture_output=True, text=True,
)
if result.returncode:
    sys.exit("无法读取 Compose 环境配置，请检查 .env 格式与 Docker Compose 版本。")
values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

def setting(name, default=""):
    # sudo docker 不一定继承当前环境，显式传入的部署参数在这里优先处理。
    return os.environ.get(name) or values.get(name) or default

key = setting("MUSE2API_KEY").strip()
if key in ("", "m2a_your_secret_admin_key_here", "changeme", "change_me"):
    key = "m2a_" + secrets.token_hex(24)
if any(c in key for c in "\r\n\x00"):
    sys.exit("MUSE2API_KEY 不允许包含换行或 NUL 字符。")
port = setting("MUSE2API_PORT", "10002").strip()
if not port.isascii() or not port.isdigit() or not 1 <= int(port) <= 65535:
    sys.exit("MUSE2API_PORT 必须是 1 到 65535 之间的整数。")
port = str(int(port))
base = setting("MUSE2API_PUBLIC_BASE").strip().rstrip("/")
if base:
    parsed = urlsplit(base)
    if parsed.scheme not in ("http", "https") or not parsed.netloc or any(c.isspace() for c in base):
        sys.exit("MUSE2API_PUBLIC_BASE 必须是完整的 http:// 或 https:// 地址。")

updates = {"MUSE2API_KEY": key, "MUSE2API_PORT": port, "MUSE2API_PUBLIC_BASE": base}

def dotenv(value):
    # 双引号转义保留反斜杠 / 引号，$$ 防止 Compose 展开密钥中的美元符号。
    return json.dumps(value.replace("$", "$$"), ensure_ascii=False)

lines = target.read_text(encoding="utf-8").splitlines()
output = []
seen = set()
for line in lines:
    match = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
    name = match.group(1) if match else ""
    if name in updates:
        if name in seen:
            continue
        seen.add(name)
        output.append(f"{name}={dotenv(updates[name])}")
    else:
        output.append(line)
for name, value in updates.items():
    if name not in seen:
        output.append(f"{name}={dotenv(value)}")
save("\n".join(output) + "\n")
print(json.dumps({"key": key, "port": port, "base": base}))
PY
    )
    MUSE2API_KEY=$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
    MUSE2API_PORT=$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.load(sys.stdin)["port"])')
    MUSE2API_PUBLIC_BASE=$(printf '%s' "$settings" | python3 -c 'import json,sys; print(json.load(sys.stdin)["base"])')
    export MUSE2API_KEY MUSE2API_PORT MUSE2API_PUBLIC_BASE
    mkdir -p -- "$INSTALL_DIR/data/media" "$INSTALL_DIR/data/downloads"
    compose config --quiet
}

configure_firewall() {
    [[ $PLATFORM == Linux ]] || return 0
    if command -v ufw >/dev/null 2>&1 && as_root env LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        log "为 UFW 放行 TCP $MUSE2API_PORT"
        as_root ufw allow "$MUSE2API_PORT/tcp"
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && as_root firewall-cmd --state >/dev/null 2>&1; then
        log "为 firewalld 放行 TCP $MUSE2API_PORT"
        as_root firewall-cmd --permanent --add-port="$MUSE2API_PORT/tcp"
        as_root firewall-cmd --add-port="$MUSE2API_PORT/tcp"
    fi
}

wait_for_service() {
    local deadline=$((SECONDS + 120))
    log "等待服务启动，并验证健康接口和 API 密钥"
    while ((SECONDS < deadline)); do
        if curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 \
            "http://127.0.0.1:$MUSE2API_PORT/healthz" >/dev/null 2>&1; then
            # 通过 stdin 传递鉴权头，避免将密钥放到 curl 的进程参数中。
            if printf 'Authorization: Bearer %s\n' "$MUSE2API_KEY" | \
                curl --noproxy '*' -fsS --connect-timeout 2 --max-time 3 --header @- \
                "http://127.0.0.1:$MUSE2API_PORT/v1/models" >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 2
    done
    compose ps
    die "服务未在 120 秒内通过健康与鉴权检查。请在 $INSTALL_DIR 执行 docker compose logs --tail=80 排查。"
}

print_result() {
    local base=$MUSE2API_PUBLIC_BASE address encoded_key
    if [[ -z $base ]]; then
        address=$(curl -4fsS --connect-timeout 2 --max-time 5 https://api.ipify.org 2>/dev/null || true)
        address=$(python3 - "$address" <<'PY'
import ipaddress
import socket
import sys
try:
    address = ipaddress.IPv4Address(sys.argv[1].strip())
    if not address.is_global:
        raise ValueError("not public")
    print(address)
except ValueError:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("1.1.1.1", 80))
            print(sock.getsockname()[0])
    except OSError:
        print("127.0.0.1")
PY
        )
        base=http://$address:$MUSE2API_PORT
    fi
    encoded_key=$(printf '%s' "$MUSE2API_KEY" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""))')
    printf '\n部署完成！\n\n'
    printf '管理面板：%s/admin?key=%s\n' "$base" "$encoded_key"
    printf 'API 地址：%s/v1\n' "$base"
    printf 'API 密钥：%s\n' "$MUSE2API_KEY"
    printf '配置文件：%s/.env（权限 600，后续更新沿用此密钥）\n' "$INSTALL_DIR"
    printf '数据目录：%s/data\n' "$INSTALL_DIR"
    printf '更新命令：cd %q && bash deploy.sh\n' "$INSTALL_DIR"
    printf '\n首次使用：打开管理面板，导入 Muse 账号后即可调用生成接口。\n'
    printf '公网访问：请确保云服务器安全组已放行 TCP %s。\n' "$MUSE2API_PORT"
}

main() {
    case ${1:-} in
        -h|--help) usage; return 0 ;;
        '') ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
    PLATFORM=$(uname -s)
    [[ $PLATFORM == Linux || $PLATFORM == Darwin ]] || die "此脚本仅支持 Linux 服务器和 macOS（Docker Desktop）。"
    install_dependencies
    update_source
    ensure_docker
    configure_environment
    configure_firewall
    log "从本地最新源码构建镜像并启动服务（首次构建需要下载依赖）"
    compose up -d --build
    wait_for_service
    print_result
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap 'printf "\n[muse2api] 部署失败（第 %s 行），请检查上方错误后重新运行。\n" "$LINENO" >&2' ERR
    main "$@"
fi
