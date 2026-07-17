#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO="EasyTier/EasyTier"
readonly INSTALL_DIR="/opt/easytier"
readonly BIN_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/easytier"
readonly ARGS_FILE="${CONFIG_DIR}/config.args"
readonly VERSION_FILE="${INSTALL_DIR}/VERSION"
readonly SERVICE_FILE="/etc/systemd/system/easytier.service"
readonly UPDATE_SERVICE="/etc/systemd/system/easytier-update.service"
readonly UPDATE_TIMER="/etc/systemd/system/easytier-update.timer"
readonly SELF_PATH="/usr/local/sbin/easytier-installer"
readonly API_URL="https://api.github.com/repos/${REPO}/releases/latest"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "${CYAN}[信息]${NC} %s\n" "$*"; }
ok() { printf "${GREEN}[完成]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[注意]${NC} %s\n" "$*"; }
die() { printf "${RED}[错误]${NC} %s\n" "$*" >&2; exit 1; }
trap 'printf "\n${RED}[错误]${NC} 第 %s 行执行失败。请保留上方输出以便排查。\n" "$LINENO" >&2' ERR

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd。本脚本适用于使用 systemd 的 Linux。"
}

install_tools() {
  local missing=() c
  for c in curl unzip sha256sum; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) && return
  info "正在安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip coreutils ca-certificates
  elif command -v dnf >/dev/null; then dnf install -y curl unzip coreutils ca-certificates
  elif command -v yum >/dev/null; then yum install -y curl unzip coreutils ca-certificates
  elif command -v apk >/dev/null; then apk add --no-cache curl unzip coreutils ca-certificates
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm curl unzip coreutils ca-certificates
  else die "无法识别包管理器，请先安装 curl、unzip、sha256sum。"; fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64;;
    aarch64|arm64) echo aarch64;;
    armv7l) echo armv7hf;;
    armv6l) echo armhf;;
    riscv64) echo riscv64;;
    loongarch64) echo loongarch64;;
    mips) echo mips;;
    mipsel) echo mipsel;;
    *) die "暂不支持 CPU 架构：$(uname -m)。可在脚本中补充官方 Release 的架构映射。";;
  esac
}

fetch_release_json() {
  local prefix candidate
  local -a prefixes=()
  [[ -n ${EASYTIER_GITHUB_PROXY:-} ]] && prefixes+=("${EASYTIER_GITHUB_PROXY%/}/")
  prefixes+=("" "https://ghfast.top/" "https://ghproxy.net/")
  for prefix in "${prefixes[@]}"; do
    candidate="${prefix}${API_URL}"
    if curl -fsSL --connect-timeout 8 --retry 1 -H 'Accept: application/vnd.github+json' \
      -H 'User-Agent: easytier-oneclick-installer' "$candidate" 2>/dev/null; then return 0; fi
  done
  return 1
}

json_value() {
  local key=$1
  sed -nE 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}

latest_version() {
  local json tag
  if json=$(fetch_release_json 2>/dev/null); then
    tag=$(printf '%s' "$json" | json_value tag_name)
  else
    warn "GitHub API 暂时不可达，尝试从 Release 跳转地址获取版本。" >&2
    tag=$(curl -fsSIL --connect-timeout 8 --retry 2 -o /dev/null -w '%{url_effective}' \
      "https://github.com/${REPO}/releases/latest" | sed -nE 's#.*/tag/([^/?]+).*#\1#p')
  fi
  [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || die "无法取得可信的最新版本号。请检查网络后重试。"
  printf '%s\n' "$tag"
}

asset_digest() {
  local asset=$1 json block
  json=$(fetch_release_json 2>/dev/null) || return 0
  block=$(printf '%s' "$json" | tr '\n' ' ' | grep -oE '\{[^{}]*"name"[[:space:]]*:[[:space:]]*"'"$asset"'"[^{}]*\}' | head -n1 || true)
  printf '%s' "$block" | sed -nE 's/.*"digest"[[:space:]]*:[[:space:]]*"sha256:([0-9a-fA-F]{64})".*/\1/p'
}

download_asset() {
  local version=$1 arch=$2 dest=$3 asset url prefix candidate
  asset="easytier-linux-${arch}-${version}.zip"
  url="https://github.com/${REPO}/releases/download/${version}/${asset}"
  local -a prefixes=()
  [[ -n ${EASYTIER_GITHUB_PROXY:-} ]] && prefixes+=("${EASYTIER_GITHUB_PROXY%/}/")
  prefixes+=("" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/")
  for prefix in "${prefixes[@]}"; do
    candidate="${prefix}${url}"
    info "尝试下载：${candidate}"
    if curl -fL --connect-timeout 10 --retry 2 --speed-time 30 --speed-limit 1024 \
      --progress-bar "$candidate" -o "$dest" && unzip -tqq "$dest"; then return 0; fi
    rm -f "$dest"
    warn "此线路失败，自动尝试下一条。"
  done
  die "所有下载线路均失败。可设置国内代理后重试：EASYTIER_GITHUB_PROXY=https://你的代理地址 sudo -E bash $0"
}

install_binary() {
  local requested=${1:-latest} arch version tmp zip digest got core cli
  arch=$(detect_arch)
  [[ $requested == latest ]] && version=$(latest_version) || version=$requested
  [[ $version == v* ]] || version="v${version}"
  if [[ -f $VERSION_FILE && $(<"$VERSION_FILE") == "$version" && -x ${BIN_DIR}/easytier-core ]]; then
    ok "已是最新版 ${version}，无需重复下载。"
    return 0
  fi
  tmp=$(mktemp -d)
  zip="${tmp}/easytier.zip"
  download_asset "$version" "$arch" "$zip"
  digest=$(asset_digest "easytier-linux-${arch}-${version}.zip")
  if [[ -n $digest ]]; then
    got=$(sha256sum "$zip" | awk '{print $1}')
    [[ $got == "$digest" ]] || die "SHA-256 校验失败，文件已拒绝安装。"
    ok "SHA-256 校验通过。"
  else
    warn "官方 API 未返回 SHA-256；已通过 ZIP 完整性检查，但无法做来源摘要校验。"
  fi
  unzip -q "$zip" -d "$tmp/out"
  core=$(find "$tmp/out" -type f -name easytier-core -print -quit)
  cli=$(find "$tmp/out" -type f -name easytier-cli -print -quit)
  [[ -n $core && -n $cli ]] || die "压缩包内缺少 easytier-core/easytier-cli。"
  install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR"
  install -m 0755 "$core" "${INSTALL_DIR}/easytier-core.new"
  install -m 0755 "$cli" "${INSTALL_DIR}/easytier-cli.new"
  mv -f "${INSTALL_DIR}/easytier-core.new" "${INSTALL_DIR}/easytier-core"
  mv -f "${INSTALL_DIR}/easytier-cli.new" "${INSTALL_DIR}/easytier-cli"
  ln -sfn "${INSTALL_DIR}/easytier-core" "${BIN_DIR}/easytier-core"
  ln -sfn "${INSTALL_DIR}/easytier-cli" "${BIN_DIR}/easytier-cli"
  printf '%s\n' "$version" > "$VERSION_FILE"
  rm -rf -- "$tmp"
  ok "EasyTier ${version} 安装完成（${arch}）。"
}

ask() {
  local __var=$1 prompt=$2 default=${3-} answer
  if [[ -n $default ]]; then read -r -p "$prompt [$default]: " answer || true
  else read -r -p "$prompt: " answer || true; fi
  printf -v "$__var" '%s' "${answer:-$default}"
}

yesno() {
  local prompt=$1 default=${2:-n} answer suffix='y/N'
  [[ $default == y ]] && suffix='Y/n'
  read -r -p "$prompt [$suffix]: " answer || true
  answer=${answer:-$default}; [[ ${answer,,} == y || ${answer,,} == yes ]]
}

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_ipv4_or_empty() { [[ -z $1 || $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

append_csv_args() {
  local flag=$1 input=$2 item
  IFS=',' read -ra items <<< "$input"
  for item in "${items[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"; item="${item%"${item##*[![:space:]]}"}"
    [[ -n $item ]] && CONFIG_ARGS+=("$flag" "$item")
  done
}

configure() {
  local network secret mode ipv4 hostname listen_port protocols peers external proxy_nets rpc_port
  local vpn_portal socks5 compression extra answer
  printf '\n%s\n' "========== EasyTier 小白配置向导 =========="
  echo "同一个网络里的所有设备：网络名称和网络密钥必须完全相同，虚拟 IP 不能重复。"
  ask network "1/12 网络名称（建议英文、数字、短横线）" "my-easytier"
  while [[ ! $network =~ ^[A-Za-z0-9._-]{1,64}$ ]]; do warn "只能使用英文、数字、点、下划线、短横线。"; ask network "请重新输入网络名称"; done
  while :; do
    read -r -s -p "2/12 网络密钥（输入时不显示；建议至少 16 位）: " secret; echo
    ((${#secret} >= 8)) && break
    warn "密钥至少 8 位；为安全起见建议 16 位以上。"
  done
  echo "3/12 虚拟 IP：自动分配最省心；固定 IP 便于长期访问服务器。"
  if yesno "使用自动分配 IP（DHCP）？" y; then mode=dhcp; ipv4=''
  else
    mode=fixed; ask ipv4 "请输入此设备的虚拟 IPv4（例如 10.126.126.2）"
    valid_ipv4_or_empty "$ipv4" && [[ -n $ipv4 ]] || die "IPv4 格式不正确。"
  fi
  ask hostname "4/12 设备名称" "$(hostname | tr -cd 'A-Za-z0-9._-')"
  ask listen_port "5/12 基础监听端口（TCP/UDP；1-65535）" "11010"
  valid_port "$listen_port" || die "端口不合法。"
  ask protocols "6/12 监听协议，逗号分隔（tcp,udp,ws,wss,wg,quic）" "tcp,udp"
  ask peers "7/12 主动连接的节点，逗号分隔；没有可留空（例 tcp://1.2.3.4:11010）" ""
  echo "公共共享节点可帮助发现与中继。请只使用你信任的节点；不知道可留空。"
  ask external "8/12 公共共享节点 URL（可留空）" ""
  ask proxy_nets "9/12 要共享给其他设备的本地网段，逗号分隔（可留空，如 192.168.1.0/24）" ""
  ask rpc_port "10/12 本机管理 RPC 端口（仅监听 127.0.0.1）" "15888"
  valid_port "$rpc_port" || die "RPC 端口不合法。"
  ask socks5 "11/12 SOCKS5 端口（留空表示不开启）" ""
  [[ -z $socks5 ]] || valid_port "$socks5" || die "SOCKS5 端口不合法。"
  ask compression "12/12 压缩方式（none/zstd）" "none"
  [[ $compression == none || $compression == zstd ]] || die "压缩方式只能是 none 或 zstd。"

  CONFIG_ARGS=(--network-name "$network" --network-secret "$secret" --hostname "$hostname")
  [[ $mode == dhcp ]] && CONFIG_ARGS+=(--dhcp) || CONFIG_ARGS+=(--ipv4 "$ipv4")
  IFS=',' read -ra proto_items <<< "$protocols"
  for answer in "${proto_items[@]}"; do
    answer=${answer//[[:space:]]/}; [[ $answer =~ ^(tcp|udp|ws|wss|wg|quic|faketcp)$ ]] || die "不支持的监听协议：$answer"
    CONFIG_ARGS+=(--listeners "${answer}://0.0.0.0:${listen_port}")
  done
  append_csv_args --peers "$peers"
  [[ -n $external ]] && CONFIG_ARGS+=(--external-node "$external")
  append_csv_args --proxy-networks "$proxy_nets"
  CONFIG_ARGS+=(--rpc-portal "127.0.0.1:${rpc_port}" --compression "$compression")
  [[ -n $socks5 ]] && CONFIG_ARGS+=(--socks5 "$socks5")

  if yesno "是否配置 WireGuard 入口？" n; then
    ask vpn_portal "格式 wg://0.0.0.0:端口/客户端网段" "wg://0.0.0.0:11013/10.14.14.0/24"
    CONFIG_ARGS+=(--vpn-portal "$vpn_portal")
  fi
  if yesno "是否启用多线程（服务器/多连接设备建议开启）？" y; then CONFIG_ARGS+=(--multi-thread); fi
  if yesno "是否启用延迟优先选路？" y; then CONFIG_ARGS+=(--latency-first); fi
  if yesno "是否禁用 IPv6？" n; then CONFIG_ARGS+=(--disable-ipv6); fi

  echo "高级用户可继续逐个加入 EasyTier 原生参数；每行只填一个参数或一个值，直接回车结束。"
  echo "例：先输入 --mtu，下一行输入 1360。不要输入 shell 命令。"
  while :; do
    ask extra "附加参数（回车结束）" ""
    [[ -z $extra ]] && break
    [[ $extra != *$'\n'* && $extra != *$'\r'* ]] || die "参数不能包含换行。"
    CONFIG_ARGS+=("$extra")
  done

  install -d -m 0700 "$CONFIG_DIR"
  : > "${ARGS_FILE}.new"; chmod 0600 "${ARGS_FILE}.new"
  printf '%s\n' "${CONFIG_ARGS[@]}" > "${ARGS_FILE}.new"
  "${INSTALL_DIR}/easytier-core" --config-file /dev/null --check-config >/dev/null 2>&1 || true
  mv -f "${ARGS_FILE}.new" "$ARGS_FILE"
  ok "配置已保存到 ${ARGS_FILE}（仅 root 可读）。"
}

write_units() {
  install -d -m 0755 /usr/local/lib/easytier /usr/local/sbin
  cat > /usr/local/lib/easytier/run <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
mapfile -t args < /etc/easytier/config.args
exec /opt/easytier/easytier-core "${args[@]}"
EOF
  chmod 0755 /usr/local/lib/easytier/run
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=EasyTier mesh VPN
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/lib/easytier/run
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  install -m 0755 "$0" "$SELF_PATH"
  cat > "$UPDATE_SERVICE" <<'EOF'
[Unit]
Description=Update EasyTier to latest stable release
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/easytier-installer --update
EOF
  cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Weekly EasyTier update check

[Timer]
OnBootSec=15min
OnCalendar=weekly
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

start_service() {
  systemctl enable --now easytier.service
  sleep 2
  if systemctl is-active --quiet easytier.service; then ok "EasyTier 服务正在运行。"
  else systemctl status easytier.service --no-pager -l || true; die "服务启动失败，请查看上方信息。"; fi
}

enable_updates() {
  if yesno "是否每周自动检查并更新 EasyTier？" y; then
    systemctl enable --now easytier-update.timer
    ok "已开启每周自动更新；发现新版本后会自动重启服务。"
  else systemctl disable --now easytier-update.timer >/dev/null 2>&1 || true; fi
}

do_install() {
  need_root; need_systemd; install_tools; install_binary latest; configure; write_units; start_service; enable_updates
  printf '\n常用命令：\n  查看节点：easytier-cli peer\n  查看日志：journalctl -u easytier -f\n  再次配置：sudo easytier-installer --configure\n  手动更新：sudo easytier-installer --update\n'
}

do_update() {
  need_root; need_systemd; install_tools
  local before='' after=''; [[ -f $VERSION_FILE ]] && before=$(<"$VERSION_FILE")
  install_binary latest; [[ -f $VERSION_FILE ]] && after=$(<"$VERSION_FILE")
  if [[ $before != "$after" ]] && systemctl list-unit-files easytier.service >/dev/null 2>&1; then
    systemctl restart easytier.service; ok "已从 ${before:-未安装} 更新到 ${after} 并重启服务。"
  fi
}

do_uninstall() {
  need_root
  warn "将停止服务并删除程序、服务文件和自动更新任务。"
  if ! yesno "保留 ${CONFIG_DIR} 中的配置吗？" y; then rm -rf -- "$CONFIG_DIR"; fi
  systemctl disable --now easytier.service easytier-update.timer >/dev/null 2>&1 || true
  rm -f -- "$SERVICE_FILE" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$SELF_PATH" /usr/local/lib/easytier/run \
    "${BIN_DIR}/easytier-core" "${BIN_DIR}/easytier-cli"
  rm -rf -- "$INSTALL_DIR" /usr/local/lib/easytier
  systemctl daemon-reload; ok "EasyTier 已卸载。"
}

menu() {
  printf '\n%s\n' "========== EasyTier 一键管理脚本 =========="
  echo "1) 安装 / 重新安装并配置"
  echo "2) 仅更新到最新版"
  echo "3) 重新配置"
  echo "4) 查看状态"
  echo "5) 实时日志"
  echo "6) 卸载"
  echo "0) 退出"
  local choice; read -r -p "请选择 [0-6]: " choice
  case $choice in
    1) do_install;; 2) do_update;;
    3) need_root; [[ -x ${INSTALL_DIR}/easytier-core ]] || die "请先安装。"; configure; write_units; start_service;;
    4) systemctl status easytier.service --no-pager -l;;
    5) journalctl -u easytier.service -f;;
    6) do_uninstall;; 0) exit 0;; *) die "无效选择。";;
  esac
}

case ${1:-} in
  --install) do_install;;
  --update) do_update;;
  --configure) need_root; need_systemd; [[ -x ${INSTALL_DIR}/easytier-core ]] || die "请先安装。"; configure; write_units; start_service;;
  --uninstall) do_uninstall;;
  --status) systemctl status easytier.service --no-pager -l;;
  --logs) journalctl -u easytier.service -f;;
  -h|--help) echo "用法：sudo bash $0 [--install|--update|--configure|--status|--logs|--uninstall]";;
  '') menu;;
  *) die "未知参数：$1（使用 --help 查看帮助）";;
esac
