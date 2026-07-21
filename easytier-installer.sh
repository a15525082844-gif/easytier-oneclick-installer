#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO="EasyTier/EasyTier"
INSTALL_DIR=/opt/easytier
BIN_DIR=/usr/local/bin
CONFIG_DIR=/etc/easytier
SYSTEMD_DIR=/etc/systemd/system
SELF_PATH=/usr/local/sbin/easytier-installer
RUNNER_PATH=/usr/local/lib/easytier/run
WEB_RUNNER_PATH=/usr/local/lib/easytier/run-web
MAX_ASSET_BYTES=268435456
if [[ ${EASYTIER_INSTALLER_TEST_MODE:-0} == 1 && ${BASH_SOURCE[0]} != "$0" ]]; then
  INSTALL_DIR=${EASYTIER_INSTALL_DIR:-$INSTALL_DIR}; BIN_DIR=${EASYTIER_BIN_DIR:-$BIN_DIR}
  CONFIG_DIR=${EASYTIER_CONFIG_DIR:-$CONFIG_DIR}; SYSTEMD_DIR=${EASYTIER_SYSTEMD_DIR:-$SYSTEMD_DIR}
  SELF_PATH=${EASYTIER_SELF_PATH:-$SELF_PATH}; RUNNER_PATH=${EASYTIER_RUNNER_PATH:-$RUNNER_PATH}
  WEB_RUNNER_PATH=${EASYTIER_WEB_RUNNER_PATH:-$WEB_RUNNER_PATH}
  MAX_ASSET_BYTES=${EASYTIER_MAX_ASSET_BYTES:-$MAX_ASSET_BYTES}
fi
readonly INSTALL_DIR BIN_DIR CONFIG_DIR SYSTEMD_DIR SELF_PATH RUNNER_PATH WEB_RUNNER_PATH MAX_ASSET_BYTES
readonly ARGS_FILE="${CONFIG_DIR}/config.args"
readonly WEB_ARGS_FILE="${CONFIG_DIR}/web.args"
readonly WEB_DB_FILE="${CONFIG_DIR}/web.db"
readonly VERSION_FILE="${INSTALL_DIR}/VERSION"
readonly INSTALLER_ENV_FILE="${CONFIG_DIR}/installer.env"
readonly SERVICE_FILE="${SYSTEMD_DIR}/easytier.service"
readonly WEB_SERVICE_FILE="${SYSTEMD_DIR}/easytier-web.service"
readonly UPDATE_SERVICE="${SYSTEMD_DIR}/easytier-update.service"
readonly UPDATE_TIMER="${SYSTEMD_DIR}/easytier-update.timer"
readonly API_ROOT="https://api.github.com/repos/${REPO}/releases"
readonly RELEASES_URL="https://github.com/${REPO}/releases"
readonly LOCK_DIR=/run/easytier-installer
readonly LOCK_FILE=${LOCK_DIR}/lock

declare -a CONFIG_ARGS=() WEB_ARGS=()
BINARY_CHANGED=false
BINARY_ROLLBACK_DIR=''
WORK_TMP=''
LOCK_HELD=false
WEB_ENABLED=false
WEB_ADMIN_PASSWORD=''
WEB_BOOTSTRAP_PID=''
ERROR_MESSAGE_SHOWN=false

umask 077

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { printf "%b[信息]%b %s\n" "$CYAN" "$NC" "$*"; }
ok() { printf "%b[完成]%b %s\n" "$GREEN" "$NC" "$*"; }
warn() { printf "%b[注意]%b %s\n" "$YELLOW" "$NC" "$*"; }
die() { ERROR_MESSAGE_SHOWN=true; printf "%b[错误]%b %s\n" "$RED" "$NC" "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行：sudo bash $0"
}

need_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemd。本脚本适用于使用 systemd 的 Linux。"
}

acquire_lock() {
  [[ $LOCK_HELD == true ]] && return 0
  command -v flock >/dev/null 2>&1 || die '缺少 flock（通常由 util-linux 提供），无法安全执行变更操作。'
  [[ ! -L $LOCK_DIR ]] || die "锁目录不能是符号链接：${LOCK_DIR}"
  install -d -o root -g root -m 0700 "$LOCK_DIR"
  [[ $(stat -c '%u' "$LOCK_DIR") == 0 ]] || die "锁目录不属于 root：${LOCK_DIR}"
  exec 9>"$LOCK_FILE" || die '无法创建安装器互斥锁。'
  flock -n 9 || die '另一个 EasyTier 安装、配置、更新或卸载任务正在运行，请稍后重试。'
  LOCK_HELD=true
}

begin_critical_section() { trap '' HUP INT TERM; }
end_critical_section() { trap - HUP INT TERM; }

validate_runtime_paths() {
  [[ $INSTALL_DIR == /opt/easytier && $BIN_DIR == /usr/local/bin && $CONFIG_DIR == /etc/easytier && \
     $SYSTEMD_DIR == /etc/systemd/system && $SELF_PATH == /usr/local/sbin/easytier-installer && \
     $RUNNER_PATH == /usr/local/lib/easytier/run && $WEB_RUNNER_PATH == /usr/local/lib/easytier/run-web ]] || \
    die '生产模式拒绝覆盖系统安装路径。'
}

install_tools() {
  local missing=() c
  for c in curl unzip sha256sum md5sum head wc stat flock; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) && return
  info "正在安装依赖：${missing[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl unzip coreutils ca-certificates util-linux
  elif command -v dnf >/dev/null 2>&1; then dnf install -y curl unzip coreutils ca-certificates util-linux
  elif command -v yum >/dev/null 2>&1; then yum install -y curl unzip coreutils ca-certificates util-linux
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl unzip coreutils ca-certificates flock
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm curl unzip coreutils ca-certificates util-linux
  else die "无法识别包管理器，请先安装 curl、unzip、sha256sum。"; fi
}

detect_arch() {
  local machine features=''
  machine=$(uname -m)
  [[ -r /proc/cpuinfo ]] && features=$(sed -nE '/^(Features|flags)[[:space:]]*:/ { s/^[^:]*:[[:space:]]*//; p; q; }' /proc/cpuinfo)
  case "$machine" in
    x86_64|amd64) echo x86_64;;
    aarch64|arm64) echo aarch64;;
    armv7l) [[ " $features " == *' half '* ]] && echo armv7hf || echo armv7;;
    armv6l|arm) [[ " $features " == *' half '* ]] && echo armhf || echo arm;;
    riscv64) echo riscv64;;
    loongarch64) echo loongarch64;;
    mips) echo mips;;
    mipsel) echo mipsel;;
    *) die "暂不支持 CPU 架构：${machine}。请检查 EasyTier 官方 Release。";;
  esac
}

release_arch_supports_web() { [[ $1 != mips && $1 != mipsel ]]; }

valid_version() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; }
valid_sha256() { [[ $1 =~ ^[0-9a-fA-F]{64}$ ]]; }

valid_proxy() {
  local value=$1 rest
  [[ $value == https://* && $value != *[[:space:]]* ]] || return 1
  [[ $value != *\"* && $value != *"'"* && $value != *\\* ]] || return 1
  rest=${value#https://}
  [[ -n $rest && $rest != /* ]]
}

curl_metadata() {
  curl --disable -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 30 \
    --retry 2 --speed-time 10 --speed-limit 1 -H 'User-Agent: easytier-oneclick-installer' "$@"
}

fetch_release_json() {
  local endpoint=$1
  curl_metadata -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${API_ROOT}/${endpoint}"
}

json_tag_name() {
  sed -nE 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n1
}

latest_version() {
  local json='' tag=''
  if [[ -n ${EASYTIER_VERSION:-} ]]; then
    tag=$EASYTIER_VERSION; [[ $tag == v* ]] || tag="v${tag}"
    valid_version "$tag" || die "EASYTIER_VERSION 格式无效。"
    printf '%s\n' "$tag"; return
  fi
  if json=$(fetch_release_json latest 2>/dev/null); then tag=$(printf '%s' "$json" | json_tag_name); fi
  if ! valid_version "${tag:-}"; then
    warn "GitHub API 暂时不可达，尝试从官方 Release 跳转地址取得版本。" >&2
    tag=$(curl --disable -fsSIL --proto '=https' --proto-redir '=https' --connect-timeout 8 --max-time 30 --retry 2 \
      -o /dev/null -w '%{url_effective}' "${RELEASES_URL}/latest" 2>/dev/null | sed -nE 's#.*/tag/([^/?]+).*#\1#p')
  fi
  valid_version "${tag:-}" || die "无法从 GitHub 官方站取得可信的最新版本号。可设置 EASYTIER_VERSION=vX.Y.Z 后重试。"
  printf '%s\n' "$tag"
}

extract_asset_digest_from_json() {
  local wanted=$1 token value current=0 assets=0 digests=0 digest=''
  while IFS= read -r token; do
    value=${token#*:}; value=${value#"${value%%[![:space:]]*}"}
    if [[ $value == null ]]; then value=''; else value=${value#\"}; value=${value%\"}; fi
    if [[ $token == \"name\"* ]]; then
      current=0
      if [[ $value == "$wanted" ]]; then current=1; ((assets+=1)); fi
    elif [[ $token == \"digest\"* ]] && ((current)); then
      ((digests+=1))
      [[ $value =~ ^sha256:([0-9a-fA-F]{64})$ ]] || return 1
      digest=${BASH_REMATCH[1],,}; current=0
    fi
  done < <(LC_ALL=C grep -oE '"(name|digest)"[[:space:]]*:[[:space:]]*(null|"[^"]*")' || true)
  ((assets == 1 && digests == 1)) || return 1
  printf '%s\n' "$digest"
}

extract_asset_digest_from_html() {
  local wanted=$1 tag count=0 digest=''
  while IFS= read -r tag; do
    [[ $tag == *"aria-label=\"Copy to clipboard digest for ${wanted}\""* ]] || continue
    ((count+=1))
    [[ $tag =~ value=\"sha256:([0-9a-fA-F]{64})\" ]] || return 1
    digest=${BASH_REMATCH[1],,}
  done < <(tr '\r\n' '  ' | LC_ALL=C grep -oE '<clipboard-copy[^>]*>' || true)
  ((count == 1)) || return 1
  printf '%s\n' "$digest"
}

asset_digest() {
  local version=$1 asset=$2 json='' html='' tag='' digest=''
  if [[ -n ${EASYTIER_SHA256:-} ]]; then
    [[ -n ${EASYTIER_VERSION:-} ]] || die "使用 EASYTIER_SHA256 时必须同时指定 EASYTIER_VERSION。"
    valid_sha256 "$EASYTIER_SHA256" || die "EASYTIER_SHA256 必须是 64 位十六进制。"
    printf '%s\n' "${EASYTIER_SHA256,,}"; return
  fi
  if json=$(fetch_release_json "tags/${version}" 2>/dev/null); then
    tag=$(printf '%s' "$json" | json_tag_name)
    if [[ $tag == "$version" ]]; then digest=$(printf '%s' "$json" | extract_asset_digest_from_json "$asset" || true); fi
  fi
  if [[ -z $digest ]]; then
    html=$(curl_metadata "${RELEASES_URL}/expanded_assets/${version}" 2>/dev/null || true)
    digest=$(printf '%s' "$html" | extract_asset_digest_from_html "$asset" || true)
  fi
  valid_sha256 "$digest" || die "无法从 GitHub 官方站取得 ${asset} 的 SHA-256；已拒绝以 root 安装未验证文件。"
  printf '%s\n' "$digest"
}

probe_download_candidate() {
  local candidate=$1 result_file=$2 stats='' code='' bytes='' speed='' extra=''
  printf '0\n' > "$result_file"
  if stats=$(LC_ALL=C curl --disable -fsSL --proto '=https' --proto-redir '=https' \
      --range 0-524287 --connect-timeout 4 --max-time 8 --speed-time 3 --speed-limit 8192 \
      --limit-rate 512K -o /dev/null -w '%{http_code} %{size_download} %{speed_download}' \
      -H 'User-Agent: easytier-oneclick-installer' "$candidate" 2>/dev/null); then
    read -r code bytes speed extra <<< "$stats"
    speed=${speed%%.*}
    if [[ -z $extra && ($code == 200 || $code == 206) && $bytes =~ ^[0-9]+$ && \
          $speed =~ ^[0-9]+$ ]] && ((10#$bytes >= 65536 && 10#$speed > 0)); then
      printf '%s\n' "$((10#$speed))" > "$result_file"
    fi
  fi
  return 0
}

try_verified_download() {
  local candidate=$1 label=$2 part=$3 expected=$4 max_time=$5 speed_limit=$6 size=0 got=''
  rm -f -- "$part"
  if ! curl --disable -fL --proto '=https' --proto-redir '=https' --connect-timeout 8 \
      --max-time "$max_time" --max-filesize "$MAX_ASSET_BYTES" --speed-time 20 \
      --speed-limit "$speed_limit" --progress-bar -H 'User-Agent: easytier-oneclick-installer' "$candidate" \
      | head -c "$((MAX_ASSET_BYTES + 1))" > "$part"; then
    [[ -f $part ]] && size=$(wc -c < "$part")
    if ((size > MAX_ASSET_BYTES)); then
      warn "${label} 返回的文件超过 256 MiB 安全上限，已丢弃。"
      return 20
    fi
    warn "${label} 速度过慢或连接失败，自动切换下一条。"
    return 10
  fi
  size=$(wc -c < "$part")
  if ((size > MAX_ASSET_BYTES)); then
    warn "${label} 返回的文件超过 256 MiB 安全上限，已丢弃。"
    return 20
  fi
  got=$(sha256sum "$part" | awk '{print tolower($1)}')
  if [[ $got != "$expected" ]]; then
    warn "${label} 返回的文件摘要不匹配，已丢弃。"
    return 21
  fi
  if ! unzip -tqq "$part"; then
    warn "${label} 返回的 ZIP 已损坏，已丢弃。"
    return 22
  fi
  return 0
}

download_verified_asset() {
  local version=$1 arch=$2 dest=$3 expected=$4 asset url prefix candidate label i part
  local count rank best_idx best_score score idx status rescue_idx
  asset="easytier-linux-${arch}-${version}.zip"
  url="https://github.com/${REPO}/releases/download/${version}/${asset}"
  part="${dest}.part"
  local -a prefixes=() labels=() candidates=() probe_files=() pids=() scores=() order=() used=() invalid=()
  if [[ -n ${EASYTIER_GITHUB_PROXY:-} ]]; then
    valid_proxy "$EASYTIER_GITHUB_PROXY" || die "EASYTIER_GITHUB_PROXY 必须是无空格的 https:// 地址。"
    prefixes+=("${EASYTIER_GITHUB_PROXY%/}/"); labels+=("自定义加速线路")
  fi
  prefixes+=("https://v4.gh-proxy.org/" "https://cdn.gh-proxy.org/" "https://gh-proxy.com/" \
    "https://ghfast.top/" "")
  labels+=("国内优选 v4.gh-proxy.org" "加速线路 cdn.gh-proxy.org" "加速线路 gh-proxy.com" \
    "备用线路 ghfast.top" "GitHub 官方线路")

  count=${#prefixes[@]}
  info "正在并行测速 ${count} 条下载线路，最多等待 8 秒……"
  for ((i=0; i<count; i++)); do
    prefix=${prefixes[i]}; candidates[i]="${prefix}${url}"
    probe_files[i]="${part}.probe.${i}"
    probe_download_candidate "${candidates[$i]}" "${probe_files[$i]}" &
    pids[i]=$!
  done
  for ((i=0; i<count; i++)); do wait "${pids[$i]}" || true; done
  for ((i=0; i<count; i++)); do
    score=0
    [[ -f ${probe_files[$i]} ]] && score=$(<"${probe_files[$i]}")
    [[ $score =~ ^[0-9]+$ ]] || score=0
    scores[i]=$((10#$score))
  done
  rm -f -- "${probe_files[@]}"

  for ((rank=0; rank<count; rank++)); do
    best_idx=-1; best_score=-1
    for ((i=0; i<count; i++)); do
      [[ ${used[$i]:-false} == true ]] && continue
      if ((scores[i] > best_score)); then best_idx=$i; best_score=${scores[$i]}; fi
    done
    order[rank]=$best_idx; used[best_idx]=true
  done
  if ((scores[order[0]] > 0)); then
    ok "测速完成，优先使用：${labels[${order[0]}]}"
  else
    warn "测速均未返回有效结果，将按国内加速优先顺序快速尝试。"
  fi

  for idx in "${order[@]}"; do
    candidate=${candidates[$idx]}; label=${labels[$idx]}
    info "尝试高速下载：${label}"
    if try_verified_download "$candidate" "$label" "$part" "$expected" 600 65536; then
      mv -f -- "$part" "$dest"
      ok "下载完成，官方 SHA-256 校验通过。"
      return 0
    else
      status=$?
      if ((status >= 20)); then invalid[idx]=true; fi
    fi
  done

  rescue_idx=-1
  for idx in "${order[@]}"; do
    if [[ ${invalid[$idx]:-false} != true ]]; then rescue_idx=$idx; break; fi
  done
  if ((rescue_idx >= 0)); then
    warn "高速线路均不可用，最后对测速最优线路进行一次低速兼容重试。"
    candidate=${candidates[$rescue_idx]}; label=${labels[$rescue_idx]}
    if try_verified_download "$candidate" "$label" "$part" "$expected" 1800 1024; then
      mv -f -- "$part" "$dest"
      ok "下载完成，官方 SHA-256 校验通过。"
      return 0
    fi
  fi
  rm -f -- "$part"
  die "所有下载线路均失败。可设置可信代理：EASYTIER_GITHUB_PROXY=https://你的代理地址"
}

begin_binary_transaction() {
  local name
  BINARY_ROLLBACK_DIR=$(mktemp -d)
  for name in easytier-core easytier-cli easytier-web-embed VERSION; do
    if [[ -e ${INSTALL_DIR}/${name} ]]; then
      cp -a -- "${INSTALL_DIR}/${name}" "${BINARY_ROLLBACK_DIR}/${name}"
      : > "${BINARY_ROLLBACK_DIR}/had-${name}"
    fi
  done
  BINARY_CHANGED=true
}

backup_web_database_for_transaction() {
  local suffix source backup_name
  [[ $BINARY_CHANGED == true && -n $BINARY_ROLLBACK_DIR ]] || return 1
  [[ ! -e ${BINARY_ROLLBACK_DIR}/web-db-backup-complete ]] || return 0
  for suffix in '' '-wal' '-shm' '-journal'; do
    source="${WEB_DB_FILE}${suffix}"
    backup_name="web-db${suffix}"
    if [[ -e $source ]]; then
      cp -a -- "$source" "${BINARY_ROLLBACK_DIR}/${backup_name}" || return 1
      : > "${BINARY_ROLLBACK_DIR}/had-${backup_name}"
    fi
  done
  : > "${BINARY_ROLLBACK_DIR}/web-db-backup-complete"
}

restore_web_database_from_transaction() {
  local suffix backup_name
  [[ -e ${BINARY_ROLLBACK_DIR}/web-db-backup-complete ]] || return 0
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop easytier-web.service >/dev/null 2>&1 || return 1
  fi
  for suffix in '' '-wal' '-shm' '-journal'; do
    backup_name="web-db${suffix}"
    rm -f -- "${WEB_DB_FILE}${suffix}" || return 1
    if [[ -e ${BINARY_ROLLBACK_DIR}/had-${backup_name} ]]; then
      cp -a -- "${BINARY_ROLLBACK_DIR}/${backup_name}" "${WEB_DB_FILE}${suffix}" || return 1
    fi
  done
}

rollback_binary() {
  local name committed_rollback
  [[ $BINARY_CHANGED == true && -n $BINARY_ROLLBACK_DIR ]] || return 0
  warn "正在恢复更新前的 EasyTier 文件。"
  restore_web_database_from_transaction || return 1
  for name in easytier-core easytier-cli easytier-web-embed VERSION; do
    rm -f -- "${INSTALL_DIR}/${name}" || return 1
    if [[ -e ${BINARY_ROLLBACK_DIR}/had-${name} ]]; then
      cp -a -- "${BINARY_ROLLBACK_DIR}/${name}" "${INSTALL_DIR}/${name}" || return 1
    fi
  done
  if [[ -x ${INSTALL_DIR}/easytier-core ]]; then ln -sfn "${INSTALL_DIR}/easytier-core" "${BIN_DIR}/easytier-core" || return 1; else rm -f -- "${BIN_DIR}/easytier-core" || return 1; fi
  if [[ -x ${INSTALL_DIR}/easytier-cli ]]; then ln -sfn "${INSTALL_DIR}/easytier-cli" "${BIN_DIR}/easytier-cli" || return 1; else rm -f -- "${BIN_DIR}/easytier-cli" || return 1; fi
  if [[ -x ${INSTALL_DIR}/easytier-web-embed ]]; then ln -sfn "${INSTALL_DIR}/easytier-web-embed" "${BIN_DIR}/easytier-web-embed" || return 1; else rm -f -- "${BIN_DIR}/easytier-web-embed" || return 1; fi
  committed_rollback=$BINARY_ROLLBACK_DIR
  BINARY_ROLLBACK_DIR=''; BINARY_CHANGED=false
  rm -rf -- "$committed_rollback" || warn "无法清理临时备份：${committed_rollback}"
}

finish_binary_transaction() {
  local committed_rollback=$BINARY_ROLLBACK_DIR
  BINARY_ROLLBACK_DIR=''; BINARY_CHANGED=false
  [[ -z $committed_rollback ]] || rm -rf -- "$committed_rollback" || warn "无法清理临时备份：${committed_rollback}"
}

install_binary() {
  local requested=${1:-latest} arch version zip digest core cli web web_required=true
  arch=$(detect_arch)
  release_arch_supports_web "$arch" || web_required=false
  if [[ $requested == latest ]]; then version=$(latest_version); else version=$requested; [[ $version == v* ]] || version="v${version}"; fi
  valid_version "$version" || die "版本号格式无效：${version}"
  if [[ -f $VERSION_FILE && $(<"$VERSION_FILE") == "$version" && -x ${INSTALL_DIR}/easytier-core && \
        -x ${INSTALL_DIR}/easytier-cli && -x ${BIN_DIR}/easytier-core && -x ${BIN_DIR}/easytier-cli ]] && \
     { [[ $web_required == false ]] || \
       [[ -x ${INSTALL_DIR}/easytier-web-embed && -x ${BIN_DIR}/easytier-web-embed ]]; }; then
    ok "已是最新版本 ${version}，无需重复下载。"; return 0
  fi
  WORK_TMP=$(mktemp -d); zip="${WORK_TMP}/easytier.zip"
  digest=$(asset_digest "$version" "easytier-linux-${arch}-${version}.zip")
  download_verified_asset "$version" "$arch" "$zip" "$digest"
  unzip -q "$zip" -d "${WORK_TMP}/out"
  core=$(find "${WORK_TMP}/out" -type f -name easytier-core -print -quit)
  cli=$(find "${WORK_TMP}/out" -type f -name easytier-cli -print -quit)
  web=$(find "${WORK_TMP}/out" -type f -name easytier-web-embed -print -quit)
  [[ -n $core && -n $cli ]] || die "压缩包内缺少 easytier-core 或 easytier-cli。"
  [[ $web_required == false || -n $web ]] || die "压缩包内缺少 easytier-web-embed。"
  chmod 0755 "$core" "$cli"
  [[ -z $web ]] || chmod 0755 "$web"
  "$core" --version >/dev/null 2>&1 || die '下载的 easytier-core 无法在当前系统运行。'
  "$cli" --version >/dev/null 2>&1 || die '下载的 easytier-cli 无法在当前系统运行。'
  [[ -z $web ]] || "$web" --version >/dev/null 2>&1 || die '下载的 easytier-web-embed 无法在当前系统运行。'
  install -d -m 0755 "$INSTALL_DIR" "$BIN_DIR"
  begin_binary_transaction
  install -m 0755 "$core" "${INSTALL_DIR}/easytier-core.new"
  install -m 0755 "$cli" "${INSTALL_DIR}/easytier-cli.new"
  [[ -z $web ]] || install -m 0755 "$web" "${INSTALL_DIR}/easytier-web-embed.new"
  mv -f -- "${INSTALL_DIR}/easytier-core.new" "${INSTALL_DIR}/easytier-core"
  mv -f -- "${INSTALL_DIR}/easytier-cli.new" "${INSTALL_DIR}/easytier-cli"
  [[ -z $web ]] || mv -f -- "${INSTALL_DIR}/easytier-web-embed.new" "${INSTALL_DIR}/easytier-web-embed"
  ln -sfn "${INSTALL_DIR}/easytier-core" "${BIN_DIR}/easytier-core"
  ln -sfn "${INSTALL_DIR}/easytier-cli" "${BIN_DIR}/easytier-cli"
  [[ -z $web ]] || ln -sfn "${INSTALL_DIR}/easytier-web-embed" "${BIN_DIR}/easytier-web-embed"
  printf '%s\n' "$version" > "${VERSION_FILE}.new"; chmod 0644 "${VERSION_FILE}.new"; mv -f -- "${VERSION_FILE}.new" "$VERSION_FILE"
  rm -rf -- "$WORK_TMP"; WORK_TMP=''
  ok "EasyTier ${version} 已准备完成（${arch}）。"
  [[ -n $web ]] || warn '上游当前未给此架构提供 easytier-web-embed，Core/CLI 仍可正常使用。'
}

ask() {
  local __var=$1 prompt=$2 default=${3-} answer=''
  if [[ -n $default ]]; then read -r -p "$prompt [$default]: " answer || true; else read -r -p "$prompt: " answer || true; fi
  printf -v "$__var" '%s' "${answer:-$default}"
}

yesno() {
  local prompt=$1 default=${2:-n} answer='' suffix='y/N'
  [[ $default == y ]] && suffix='Y/n'
  read -r -p "$prompt [$suffix]: " answer || true
  answer=${answer:-$default}; [[ ${answer,,} == y || ${answer,,} == yes ]]
}

generate_default_secret() {
  local random_value=''
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    IFS= read -r random_value < /proc/sys/kernel/random/uuid || random_value=''
    random_value=${random_value//-/}
  fi
  if [[ ! $random_value =~ ^[0-9a-fA-F]{20,}$ ]]; then
    random_value=$(printf '%s' "${RANDOM}-${RANDOM}-${RANDOM}-${PPID}-$(date +%s%N)" | sha256sum | awk '{print $1}')
  fi
  printf 'et-%s\n' "${random_value:0:20}"
}

valid_web_password() {
  ((${#1} >= 12 && ${#1} <= 128)) && [[ $1 =~ ^[-A-Za-z0-9._~!@%+=:/]+$ ]]
}

md5_hex() {
  printf '%s' "$1" | md5sum | awk '{print tolower($1)}'
}

arg_value_from_file() {
  local file=$1 wanted=$2 i; local -a args
  [[ -r $file ]] || return 1
  mapfile -t args < "$file" || return 1
  for ((i=0; i<${#args[@]}; i++)); do
    if [[ ${args[$i]} == "$wanted" ]]; then
      ((i+1 < ${#args[@]})) || return 1
      printf '%s\n' "${args[$((i+1))]}"
      return 0
    fi
  done
  return 1
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }

port_is_listening() {
  local family=$1 port=$2 output='' flag
  valid_port "$port" || return 1
  case $family in tcp) flag=t;; udp) flag=u;; *) return 1;; esac
  if command -v ss >/dev/null 2>&1; then
    output=$(ss -H "-ln${flag}" 2>/dev/null || true)
  elif command -v netstat >/dev/null 2>&1; then
    output=$(netstat "-ln${flag}" 2>/dev/null || true)
  else
    return 1
  fi
  awk -v suffix=":${port}" '
    {
      for (i = 1; i <= NF; i++) {
        if (length($i) >= length(suffix) && substr($i, length($i) - length(suffix) + 1) == suffix) found=1
      }
    }
    END { exit !found }
  ' <<< "$output"
}

existing_web_owns_port() {
  local family=$1 port=$2 old_api='' old_proto='' old_config='' old_family=''
  [[ -s $WEB_ARGS_FILE ]] || return 1
  old_api=$(arg_value_from_file "$WEB_ARGS_FILE" --api-server-port 2>/dev/null || true)
  [[ $family == tcp && $old_api == "$port" ]] && return 0
  old_proto=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-protocol 2>/dev/null || true)
  old_config=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-port 2>/dev/null || true)
  old_family=$(protocol_family "$old_proto" 2>/dev/null || true)
  [[ $old_family == "$family" && $old_config == "$port" ]]
}

next_free_port() {
  local family=$1 start=$2 port limit
  valid_port "$start" || return 1
  limit=$((10#$start + 200)); ((limit > 65535)) && limit=65535
  for ((port=10#$start; port<=limit; port++)); do
    if ! port_is_listening "$family" "$port"; then printf '%s\n' "$port"; return 0; fi
  done
  return 1
}

valid_ipv4() {
  local input=$1 octet; local -a parts
  IFS='.' read -r -a parts <<< "$input"
  ((${#parts[@]} == 4)) || return 1
  for octet in "${parts[@]}"; do
    [[ $octet =~ ^[0-9]{1,3}$ && ($octet == 0 || $octet != 0*) ]] && ((10#$octet <= 255)) || return 1
  done
}
valid_ipv4_or_empty() { [[ -z $1 ]] || valid_ipv4 "$1"; }
valid_ipv4_cidr() {
  local value=$1 ip prefix ip_number host_mask; local -a octets
  [[ $value == */* && $value != */*/* ]] || return 1
  ip=${value%/*}; prefix=${value##*/}
  valid_ipv4 "$ip" && [[ $prefix =~ ^(0|[1-9]|[12][0-9]|3[0-2])$ ]] || return 1
  IFS='.' read -r -a octets <<< "$ip"
  ip_number=$((10#${octets[0]} * 16777216 + 10#${octets[1]} * 65536 + 10#${octets[2]} * 256 + 10#${octets[3]}))
  host_mask=$(((1 << (32 - 10#$prefix)) - 1))
  (( (ip_number & host_mask) == 0 ))
}

protocol_family() {
  case $1 in tcp|ws|wss|faketcp) echo tcp;; udp|wg|quic) echo udp;; *) return 1;; esac
}
protocol_default_port() {
  case $1 in tcp|udp) echo 11010;; ws|wg) echo 11011;; wss|quic) echo 11012;; faketcp) echo 11013;; esac
}

append_csv_args() {
  local flag=$1 input=$2 item; local -a items
  IFS=',' read -r -a items <<< "$input"
  for item in "${items[@]}"; do
    item=${item#"${item%%[![:space:]]*}"}; item=${item%"${item##*[![:space:]]}"}
    [[ -n $item ]] && CONFIG_ARGS+=("$flag" "$item")
  done
}

validate_config_candidate() {
  local core=${1:-${INSTALL_DIR}/easytier-core} output='' rc=0; local -a args
  mapfile -t args < "${ARGS_FILE}.new" || return 1
  # v2.6.4 的 --check-config 只检查 TOML；使用 /dev/null 时合法 CLI 也返回 1。
  # 这里仅用 Clap 的退出码 2 拦截未知/缺值参数，真实语义由启动健康检查兜底。
  if output=$("$core" "${args[@]}" --config-file /dev/null --check-config 2>&1); then rc=0; else rc=$?; fi
  if ((rc > 1)); then
    warn "EasyTier 拒绝了参数（退出码 ${rc}）：${output:-无详细信息}"
    return 1
  fi
}

configure() {
  local network secret default_secret mode ipv4 hostname protocols peers external proxy_nets rpc_port socks5 compression extra answer
  local vpn_port vpn_cidr proto port family key default_port
  local web_access web_bind web_port web_config_proto web_config_port web_family web_default_password original_port candidate
  local -a proto_items=() normalized_protocols=()
  local -A used=() seen=()
  WEB_ENABLED=false; WEB_ADMIN_PASSWORD=''; WEB_ARGS=()
  rm -f -- "${WEB_ARGS_FILE}.new"
  printf '\n%s\n' '========== EasyTier 小白配置向导 =========='
  echo '同一网络里的设备：网络名称和网络密钥必须相同，固定虚拟 IP 不能重复。带 [默认值] 的项目直接回车即可。'
  ask network '网络名称（英文、数字、点、下划线、短横线）' 'my-easytier'
  while [[ ! $network =~ ^[A-Za-z0-9._-]{1,64}$ ]]; do warn '网络名称格式不正确。'; ask network '请重新输入网络名称' 'my-easytier'; done
  default_secret=$(generate_default_secret)
  while :; do
    ask secret '网络密钥（明文显示；直接回车使用自动生成值，至少 8 位）' "$default_secret"
    [[ $secret != *$'\n'* && $secret != *$'\r'* ]] && ((${#secret} >= 8)) && break
    warn '密钥至少 8 位且不能包含换行。'
  done
  if yesno '使用 DHCP 自动分配虚拟 IP？' y; then mode=dhcp; ipv4=''; else
    mode=fixed
    while :; do ask ipv4 '本设备的虚拟 IPv4（例如 10.126.126.2）' ''; valid_ipv4 "$ipv4" && break; warn 'IPv4 必须由 4 个 0-255 的数字组成。'; done
  fi
  ask hostname '设备名称' "$(hostname | tr -cd 'A-Za-z0-9._-')"
  [[ $hostname =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die '设备名称格式不正确。'
  ask protocols '监听协议，逗号分隔（tcp,udp,ws,wss,wg,quic,faketcp）' 'tcp,udp'
  IFS=',' read -r -a proto_items <<< "$protocols"
  for proto in "${proto_items[@]}"; do
    proto=${proto//[[:space:]]/}; [[ $proto =~ ^(tcp|udp|ws|wss|wg|quic|faketcp)$ ]] || die "不支持的监听协议：${proto}"
    [[ -z ${seen[$proto]+x} ]] || die "监听协议重复：${proto}"
    seen[$proto]=1; normalized_protocols+=("$proto")
  done
  ((${#normalized_protocols[@]} > 0)) || die '至少选择一个监听协议。'

  CONFIG_ARGS=("--network-name=${network}" "--network-secret=${secret}" "--hostname=${hostname}")
  [[ $mode == dhcp ]] && CONFIG_ARGS+=(--dhcp) || CONFIG_ARGS+=(--ipv4 "$ipv4")
  echo '下面为每种协议设置端口；同类协议不能占用同一个端口。'
  for proto in "${normalized_protocols[@]}"; do
    default_port=$(protocol_default_port "$proto"); family=$(protocol_family "$proto")
    while :; do
      ask port "${proto} 监听端口" "$default_port"
      if ! valid_port "$port"; then warn '端口必须在 1-65535 之间。'; continue; fi
      key="${family}:${port}"
      if [[ -n ${used[$key]+x} ]]; then warn "${port} 已被同为 ${family^^} 的 ${used[$key]} 使用，请换一个端口。"; continue; fi
      used[$key]=$proto; CONFIG_ARGS+=(--listeners "${proto}://0.0.0.0:${port}"); break
    done
  done

  ask peers '主动连接节点，逗号分隔；没有可留空（例 tcp://1.2.3.4:11010）' ''
  ask external '公共共享节点 URL（没有可留空）' ''
  ask proxy_nets '共享给其他设备的本地网段，逗号分隔（例 192.168.1.0/24）' ''
  while :; do
    ask rpc_port '本机管理 RPC 端口（仅监听 127.0.0.1）' '15888'
    valid_port "$rpc_port" || { warn '端口必须在 1-65535 之间。'; continue; }
    [[ -z ${used[tcp:$rpc_port]+x} ]] && break; warn 'RPC 端口与 TCP 类监听端口冲突。'
  done
  used["tcp:$rpc_port"]='本机 RPC'
  while :; do
    ask socks5 'SOCKS5 端口（留空表示不开启）' ''
    [[ -z $socks5 ]] && break
    valid_port "$socks5" || { warn '端口必须在 1-65535 之间。'; continue; }
    [[ $socks5 != "$rpc_port" && -z ${used[tcp:$socks5]+x} ]] && break; warn 'SOCKS5 端口与其他 TCP 端口冲突。'
  done
  [[ -z $socks5 ]] || used["tcp:$socks5"]='SOCKS5'
  ask compression '压缩方式（none/zstd）' 'none'
  [[ $compression == none || $compression == zstd ]] || die '压缩方式只能是 none 或 zstd。'
  append_csv_args --peers "$peers"
  [[ -n $external ]] && CONFIG_ARGS+=(--external-node "$external")
  append_csv_args --proxy-networks "$proxy_nets"
  CONFIG_ARGS+=(--rpc-portal "127.0.0.1:${rpc_port}" --compression "$compression")
  [[ -n $socks5 ]] && CONFIG_ARGS+=(--socks5 "$socks5")

  if yesno '配置 WireGuard VPN 入口？' n; then
    while :; do
      ask vpn_port 'WireGuard 入口 UDP 端口' '11020'
      valid_port "$vpn_port" || { warn '端口必须在 1-65535 之间。'; continue; }
      [[ -z ${used[udp:$vpn_port]+x} ]] && break; warn '此 UDP 端口已被监听协议使用。'
    done
    while :; do
      ask vpn_cidr 'WireGuard 客户端 IPv4 网段' '10.14.14.0/24'
      valid_ipv4_cidr "$vpn_cidr" && break; warn '请输入有效的 IPv4 CIDR（例如 10.14.14.0/24）。'
    done
    CONFIG_ARGS+=(--vpn-portal "wg://0.0.0.0:${vpn_port}/${vpn_cidr}")
    used["udp:$vpn_port"]='WireGuard 入口'
  fi
  yesno '启用多线程？（服务器或多连接设备建议开启）' y && CONFIG_ARGS+=(--multi-thread)
  yesno '启用延迟优先选路？' y && CONFIG_ARGS+=(--latency-first)
  yesno '禁用 IPv6？' n && CONFIG_ARGS+=(--disable-ipv6)

  if [[ ! -x ${INSTALL_DIR}/easytier-web-embed ]]; then
    warn '当前安装包没有 Web 控制面板组件，将继续使用 Core/CLI。'
  elif yesno '启用 Web 控制面板？' y; then
    WEB_ENABLED=true
    printf '%s\n' \
      'Web 访问范围：' \
      '  1) 仅本机（推荐；通过 SSH 隧道访问，不向公网暴露）' \
      '  2) 局域网 / 公网直接访问（需要防火墙或安全组放行）'
    while :; do
      ask web_access '请选择访问范围（1/2）' '1'
      [[ $web_access == 1 || $web_access == 2 ]] && break
      warn '请输入 1 或 2。'
    done
    if [[ $web_access == 1 ]]; then
      web_bind=127.0.0.1
    else
      web_bind=0.0.0.0
      warn '控制面板使用 HTTP。公网使用时请限制来源 IP，并建议在前面配置 HTTPS 反向代理。'
    fi
    while :; do
      ask web_port 'Web 控制面板 TCP 端口' '11211'
      valid_port "$web_port" || { warn '端口必须在 1-65535 之间。'; continue; }
      if [[ -n ${used[tcp:$web_port]+x} ]]; then warn "此 TCP 端口已被 ${used[tcp:$web_port]} 使用。"; continue; fi
      if port_is_listening tcp "$web_port" && ! existing_web_owns_port tcp "$web_port"; then
        original_port=$web_port; candidate=$((10#$web_port + 1))
        while :; do
          valid_port "$candidate" || die '附近没有可自动使用的 Web TCP 端口，请先释放端口后重试。'
          candidate=$(next_free_port tcp "$candidate") || die '附近没有可自动使用的 Web TCP 端口，请先释放端口后重试。'
          [[ -z ${used[tcp:$candidate]+x} ]] && break
          candidate=$((10#$candidate + 1))
        done
        web_port=$candidate
        warn "检测到 TCP ${original_port} 已被其他程序占用，Web 面板已自动改用 ${web_port}。"
      fi
      break
    done
    used["tcp:$web_port"]='Web 控制面板'
    while :; do
      ask web_config_proto 'Core 连接控制面板的协议（udp/tcp/ws）' 'udp'
      [[ $web_config_proto =~ ^(udp|tcp|ws)$ ]] && break
      warn '协议只能是 udp、tcp 或 ws。'
    done
    web_family=$(protocol_family "$web_config_proto")
    while :; do
      ask web_config_port '控制面板配置下发端口（通常无需在安全组放行）' '22020'
      valid_port "$web_config_port" || { warn '端口必须在 1-65535 之间。'; continue; }
      key="${web_family}:${web_config_port}"
      if [[ -n ${used[$key]+x} ]]; then warn "此 ${web_family^^} 端口已被 ${used[$key]} 使用。"; continue; fi
      if port_is_listening "$web_family" "$web_config_port" && ! existing_web_owns_port "$web_family" "$web_config_port"; then
        original_port=$web_config_port; candidate=$((10#$web_config_port + 1))
        while :; do
          valid_port "$candidate" || die '附近没有可自动使用的 Web 配置端口，请先释放端口后重试。'
          candidate=$(next_free_port "$web_family" "$candidate") || die '附近没有可自动使用的 Web 配置端口，请先释放端口后重试。'
          [[ -z ${used[${web_family}:$candidate]+x} ]] && break
          candidate=$((10#$candidate + 1))
        done
        web_config_port=$candidate; key="${web_family}:${web_config_port}"
        warn "检测到 ${web_family^^} ${original_port} 已被其他程序占用，配置下发端口已自动改用 ${web_config_port}。"
      fi
      break
    done
    used["$key"]='Web 配置下发'
    CONFIG_ARGS+=(--config-server "${web_config_proto}://127.0.0.1:${web_config_port}/admin")
    WEB_ARGS=(
      --db "$WEB_DB_FILE"
      --api-server-addr "$web_bind"
      --api-server-port "$web_port"
      --config-server-protocol "$web_config_proto"
      --config-server-port "$web_config_port"
      --disable-registration
      --console-log-level info
    )
    if [[ ! -s $WEB_DB_FILE ]]; then
      web_default_password=$(generate_default_secret)
      while :; do
        ask WEB_ADMIN_PASSWORD 'Web 管理员 admin 的新密码（明文显示；直接回车使用随机值）' "$web_default_password"
        valid_web_password "$WEB_ADMIN_PASSWORD" && break
        warn '密码需为 12-128 位，只能使用英文字母、数字及 -._~!@%+=:/。'
      done
    else
      info '检测到已有 Web 账户数据库，将保留当前登录密码。'
    fi
  fi

  echo '高级用户可逐行加入 EasyTier 原生参数；每行一个参数或值，直接回车结束。'
  while :; do
    ask extra '附加参数（回车结束）' ''
    [[ -z $extra ]] && break
    [[ $extra != *$'\n'* && $extra != *$'\r'* ]] || die '参数不能包含换行。'
    case $extra in
      --network-name|--network-name=*|--network-secret|--network-secret=*|--hostname|--hostname=*|\
      --dhcp|--dhcp=*|-d|-d?*|--ipv4|--ipv4=*|-i|-i?*|-p|-p?*|--peers|--peers=*|-e|-e?*|--external-node|--external-node=*|\
      -n|-n?*|--proxy-networks|--proxy-networks=*|--listeners|--listeners=*|-l|-l?*|--no-listener|\
      --rpc-portal|--rpc-portal=*|-r|-r?*|--socks5|--socks5=*|--vpn-portal|--vpn-portal=*|\
      --config-server|--config-server=*|-w|-w?*|\
      --compression|--compression=*|--multi-thread|--multi-thread=*|--latency-first|--latency-first=*|--disable-ipv6|--disable-ipv6=*)
        warn '此参数已由向导管理，不能在高级参数中重复添加。'; continue;;
    esac
    CONFIG_ARGS+=("$extra")
  done
  install -d -m 0700 "$CONFIG_DIR"
  printf '%s\n' "${CONFIG_ARGS[@]}" > "${ARGS_FILE}.new"; chmod 0600 "${ARGS_FILE}.new"
  if [[ $WEB_ENABLED == true ]]; then
    printf '%s\n' "${WEB_ARGS[@]}" > "${WEB_ARGS_FILE}.new"; chmod 0600 "${WEB_ARGS_FILE}.new"
  fi
  validate_config_candidate "${INSTALL_DIR}/easytier-core" || { rm -f -- "${ARGS_FILE}.new"; die '参数检查失败，旧配置未改动。'; }
  ok '参数检查通过，等待启动验证。'
}

write_atomic() {
  local target=$1 mode=$2 tmp
  tmp="${target}.new"
  install -d -m 0755 "$(dirname "$target")"
  cat > "$tmp"; chmod "$mode" "$tmp"; mv -f -- "$tmp" "$target"
}

install_self() {
  local src=${1:-${BASH_SOURCE[0]}} dest=${2:-$SELF_PATH} tmp
  [[ -f $src ]] || die "无法从当前输入流安装管理脚本；请先下载脚本文件再执行。"
  install -d -m 0755 "$(dirname "$dest")"
  if [[ -e $dest && $src -ef $dest ]]; then chmod 0755 "$dest"; return 0; fi
  tmp="${dest}.new"; install -m 0755 "$src" "$tmp"; mv -f -- "$tmp" "$dest"
}

save_proxy_env() {
  [[ -n ${EASYTIER_GITHUB_PROXY+x} ]] || return 0
  install -d -m 0700 "$CONFIG_DIR"
  if [[ -z $EASYTIER_GITHUB_PROXY ]]; then rm -f -- "$INSTALLER_ENV_FILE"; return 0; fi
  valid_proxy "$EASYTIER_GITHUB_PROXY" || die 'EASYTIER_GITHUB_PROXY 必须是无空格的 https:// 地址。'
  printf 'EASYTIER_GITHUB_PROXY=%s\n' "${EASYTIER_GITHUB_PROXY%/}" > "${INSTALLER_ENV_FILE}.new"
  chmod 0600 "${INSTALLER_ENV_FILE}.new"; mv -f -- "${INSTALLER_ENV_FILE}.new" "$INSTALLER_ENV_FILE"
}

write_units() {
  write_atomic "$RUNNER_PATH" 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
mapfile -t args < ${ARGS_FILE}
exec ${INSTALL_DIR}/easytier-core "\${args[@]}"
EOF
  write_atomic "$WEB_RUNNER_PATH" 0755 <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
mapfile -t args < ${WEB_ARGS_FILE}
exec ${INSTALL_DIR}/easytier-web-embed "\${args[@]}"
EOF
  write_atomic "$SERVICE_FILE" 0644 <<EOF
[Unit]
Description=EasyTier mesh VPN
After=network-online.target easytier-web.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${RUNNER_PATH}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  write_atomic "$WEB_SERVICE_FILE" 0644 <<EOF
[Unit]
Description=EasyTier Web control panel
After=network-online.target
Wants=network-online.target
Before=easytier.service
ConditionPathExists=${WEB_ARGS_FILE}

[Service]
Type=simple
ExecStart=${WEB_RUNNER_PATH}
Restart=on-failure
RestartSec=5s
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=strict
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectKernelLogs=true
RestrictSUIDSGID=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadWritePaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
  install_self "${BASH_SOURCE[0]}" "$SELF_PATH"
  save_proxy_env
  write_atomic "$UPDATE_SERVICE" 0644 <<EOF
[Unit]
Description=Update EasyTier to latest stable release
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${INSTALLER_ENV_FILE}
ExecStart=${SELF_PATH} --update
EOF
  write_atomic "$UPDATE_TIMER" 0644 <<'EOF'
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

stop_web_bootstrap() {
  local i
  [[ -n $WEB_BOOTSTRAP_PID ]] || return 0
  if kill -0 "$WEB_BOOTSTRAP_PID" 2>/dev/null; then
    kill "$WEB_BOOTSTRAP_PID" 2>/dev/null || true
    for ((i=0; i<5; i++)); do
      kill -0 "$WEB_BOOTSTRAP_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$WEB_BOOTSTRAP_PID" 2>/dev/null; then kill -KILL "$WEB_BOOTSTRAP_PID" 2>/dev/null || true; fi
  fi
  wait "$WEB_BOOTSTRAP_PID" 2>/dev/null || true
  WEB_BOOTSTRAP_PID=''
}

remove_new_web_database() {
  rm -f -- "$WEB_DB_FILE" "${WEB_DB_FILE}-wal" "${WEB_DB_FILE}-shm" "${WEB_DB_FILE}-journal"
}

bootstrap_web_admin_password() {
  local args_file="${WEB_ARGS_FILE}.new" web_port config_proto config_port temp log cookie old_hash new_hash
  local user_old_hash user_new_hash user_random user_status ready=false i
  [[ $WEB_ENABLED == true && -n $WEB_ADMIN_PASSWORD ]] || return 0
  if [[ -e $WEB_DB_FILE && ! -s $WEB_DB_FILE ]]; then remove_new_web_database; fi
  [[ ! -e $WEB_DB_FILE ]] || return 0
  web_port=$(arg_value_from_file "$args_file" --api-server-port) || return 1
  config_proto=$(arg_value_from_file "$args_file" --config-server-protocol) || return 1
  config_port=$(arg_value_from_file "$args_file" --config-server-port) || return 1
  valid_port "$web_port" && valid_port "$config_port" || return 1
  [[ $config_proto =~ ^(udp|tcp|ws)$ ]] || return 1

  temp=$(mktemp -d); log="${temp}/web.log"; cookie="${temp}/cookie"
  info '正在本机安全初始化 Web 管理员密码……'
  "${INSTALL_DIR}/easytier-web-embed" \
    --db "$WEB_DB_FILE" \
    --api-server-addr 127.0.0.1 \
    --api-server-port "$web_port" \
    --config-server-protocol "$config_proto" \
    --config-server-port "$config_port" \
    --disable-registration \
    --console-log-level info >"$log" 2>&1 &
  WEB_BOOTSTRAP_PID=$!

  for ((i=0; i<30; i++)); do
    if curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 4 \
        "http://127.0.0.1:${web_port}/api/v1/auth/captcha" -o /dev/null 2>/dev/null; then
      ready=true; break
    fi
    kill -0 "$WEB_BOOTSTRAP_PID" 2>/dev/null || break
    sleep 1
  done
  if [[ $ready != true ]]; then
    warn 'Web 控制面板临时启动失败，未公开面板。日志如下：'
    if grep -Eiq 'address already in use|addrinuse|os error 98|eaddrinuse' "$log" 2>/dev/null; then
      warn "检测到端口占用：请重新配置并换用其他 Web 端口（当前 TCP ${web_port}，配置下发 ${config_proto^^} ${config_port}）。"
    fi
    sed -n '1,80p' "$log" >&2 || true
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi

  old_hash=21232f297a57a5a743894a0e4a801fc3
  new_hash=$(md5_hex "$WEB_ADMIN_PASSWORD")
  if ! printf '{"username":"admin","password":"%s"}' "$old_hash" | \
    curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 8 \
      -c "$cookie" -H 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:${web_port}/api/v1/auth/login" -o /dev/null; then
    warn '无法使用上游初始账户完成 Web 安全初始化，未公开面板。'
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi
  if ! printf '{"new_password":"%s"}' "$new_hash" | \
    curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 8 \
      -b "$cookie" -X PUT -H 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:${web_port}/api/v1/auth/password" -o /dev/null; then
    warn 'Web 管理员密码修改失败，未公开面板。'
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi
  rm -f -- "$cookie"
  if ! printf '{"username":"admin","password":"%s"}' "$new_hash" | \
    curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 8 \
      -c "$cookie" -H 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:${web_port}/api/v1/auth/login" -o /dev/null; then
    warn 'Web 新管理员密码验证失败，未公开面板。'
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi

  user_old_hash=ee11cbb19052e40b07aac0ca060c23ee
  user_random="$(generate_default_secret)-$(generate_default_secret)"
  user_new_hash=$(md5_hex "$user_random")
  rm -f -- "$cookie"
  if ! user_status=$(printf '{"username":"user","password":"%s"}' "$user_old_hash" | \
    curl --disable --noproxy '*' -sS --connect-timeout 2 --max-time 8 \
      -c "$cookie" -H 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:${web_port}/api/v1/auth/login" -o /dev/null -w '%{http_code}'); then
    warn '无法检查 Web 内置 user 账户，未公开面板。'
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi
  if [[ $user_status == 200 ]]; then
    if ! printf '{"new_password":"%s"}' "$user_new_hash" | \
      curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 8 \
      -b "$cookie" -X PUT -H 'Content-Type: application/json' \
      --data-binary @- \
      "http://127.0.0.1:${web_port}/api/v1/auth/password" -o /dev/null; then
      warn 'Web 内置 user 账户的默认密码替换失败，未公开面板。'
      stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
      return 1
    fi
    rm -f -- "$cookie"
    if ! printf '{"username":"user","password":"%s"}' "$user_new_hash" | \
      curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 8 \
        -c "$cookie" -H 'Content-Type: application/json' \
        --data-binary @- \
        "http://127.0.0.1:${web_port}/api/v1/auth/login" -o /dev/null; then
      warn 'Web 内置 user 账户的新随机密码验证失败，未公开面板。'
      stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
      return 1
    fi
  elif [[ $user_status == 401 ]]; then
    info '上游内置 user/user 登录已不可用，无需替换。'
  else
    warn "检查 Web 内置 user 账户时收到异常 HTTP 状态：${user_status}。"
    stop_web_bootstrap; remove_new_web_database; rm -rf -- "$temp"
    return 1
  fi
  stop_web_bootstrap
  for i in "$WEB_DB_FILE" "${WEB_DB_FILE}-wal" "${WEB_DB_FILE}-shm"; do [[ ! -e $i ]] || chmod 0600 "$i"; done
  rm -rf -- "$temp"
  ok 'Web 内置默认密码均已替换，自助注册已关闭。'
}

wait_web_healthy() {
  local web_port i stable=0
  [[ -r $WEB_ARGS_FILE ]] || return 1
  web_port=$(arg_value_from_file "$WEB_ARGS_FILE" --api-server-port) || return 1
  valid_port "$web_port" || return 1
  for ((i=0; i<15; i++)); do
    sleep 1
    if systemctl is-active --quiet easytier-web.service; then ((stable+=1)); else stable=0; fi
    if ((stable >= 7)); then
      if curl --disable --noproxy '*' -fsS --connect-timeout 2 --max-time 5 \
          "http://127.0.0.1:${web_port}/api/v1/auth/captcha" -o /dev/null; then return 0; fi
      warn "Web 服务仍在运行，但本机 HTTP 健康检查失败（127.0.0.1:${web_port}）。"
      return 1
    fi
  done
  warn 'Web 服务在 15 秒内未能保持稳定运行。'
  return 1
}

redact_sensitive_lines() {
  awk '{
    lowered=tolower($0)
    if (lowered ~ /network[_-]secret|credential[_-]secret|local[_-]private[_-]key/) {
      print "[诊断] 此行包含敏感配置，已隐藏。"
    } else {
      print
    }
  }'
}

show_port_owner() {
  local family=$1 port=$2 output='' flag
  case $family in tcp) flag=t;; udp) flag=u;; *) return 0;; esac
  if command -v ss >/dev/null 2>&1; then
    output=$(ss -H "-ln${flag}p" 2>/dev/null || true)
  elif command -v netstat >/dev/null 2>&1; then
    output=$(netstat "-ln${flag}p" 2>/dev/null || true)
  fi
  [[ -n $output ]] || return 0
  printf '%s\n' "$output" | awk -v suffix=":${port}" '
    {
      matched=0
      for (i = 1; i <= NF; i++) {
        if (length($i) >= length(suffix) && substr($i, length($i) - length(suffix) + 1) == suffix) matched=1
      }
      if (matched) print "[端口占用] " $0
    }
  ' >&2
}

report_service_failure() {
  local unit=$1 label=$2 web_port='' config_proto='' config_port=''
  warn "${label}启动或健康检查失败，以下是自动诊断（敏感配置会隐藏）："
  systemctl status "$unit" --no-pager -l 2>&1 | redact_sensitive_lines >&2 || true
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -u "$unit" -n 80 --no-pager 2>&1 | redact_sensitive_lines >&2 || true
  fi
  if [[ $unit == easytier-web.service && -r $WEB_ARGS_FILE ]]; then
    web_port=$(arg_value_from_file "$WEB_ARGS_FILE" --api-server-port 2>/dev/null || true)
    config_proto=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-protocol 2>/dev/null || true)
    config_port=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-port 2>/dev/null || true)
    valid_port "$web_port" && show_port_owner tcp "$web_port"
    if valid_port "$config_port"; then
      case $config_proto in udp) show_port_owner udp "$config_port";; tcp|ws) show_port_owner tcp "$config_port";; esac
    fi
  fi
}

start_web_service_checked() {
  local was_active=false
  if [[ ! -s $WEB_ARGS_FILE ]]; then
    systemctl disable --now easytier-web.service >/dev/null 2>&1 || true
    return 0
  fi
  systemctl is-active --quiet easytier-web.service && was_active=true
  if ! systemctl enable easytier-web.service >/dev/null; then report_service_failure easytier-web.service 'Web 控制面板'; return 1; fi
  if [[ $was_active == true ]]; then
    if ! systemctl restart easytier-web.service; then report_service_failure easytier-web.service 'Web 控制面板'; return 1; fi
  else
    if ! systemctl start easytier-web.service; then report_service_failure easytier-web.service 'Web 控制面板'; return 1; fi
  fi
  if wait_web_healthy; then return 0; fi
  report_service_failure easytier-web.service 'Web 控制面板'
  return 1
}

wait_service_healthy() {
  local i stable=0
  # 连续稳定 7 秒，覆盖 RestartSec=5s，避免把“刚 active 随即崩溃”误判为成功。
  for ((i=0; i<15; i++)); do
    sleep 1
    if systemctl is-active --quiet easytier.service; then ((stable+=1)); else stable=0; fi
    if ((stable >= 7)); then verify_runtime_config && return 0; return 1; fi
  done
  return 1
}

verify_runtime_config() {
  local rpc='' listener output='' listeners_json='' i rpc_ok=false; local -a args expected=()
  [[ -r $ARGS_FILE && -x ${INSTALL_DIR}/easytier-cli ]] || { warn '缺少运行配置或 easytier-cli，无法完成健康检查。'; return 1; }
  mapfile -t args < "$ARGS_FILE" || return 1
  for ((i=0; i<${#args[@]}; i++)); do
    case ${args[$i]} in
      --rpc-portal) ((i+1 < ${#args[@]})) || return 1; rpc=${args[$((i+1))]}; ((i+=1));;
      --listeners) ((i+1 < ${#args[@]})) || return 1; expected+=("${args[$((i+1))]}"); ((i+=1));;
    esac
  done
  [[ -n $rpc ]] || { warn '新配置中缺少本机 RPC 地址，无法检查 Core。'; return 1; }
  for ((i=0; i<5; i++)); do
    if output=$("${INSTALL_DIR}/easytier-cli" -p "$rpc" -o json node 2>/dev/null); then rpc_ok=true; break; fi
    sleep 1
  done
  [[ $rpc_ok == true && -n $output ]] || { warn "Core 已启动，但本机 RPC ${rpc} 在检查期限内没有响应。"; return 1; }
  [[ $output == *'"listeners"'* ]] || { warn 'Core RPC 返回内容中缺少监听器状态。'; return 1; }
  listeners_json=${output#*'"listeners"'}
  [[ $listeners_json == *'['* && $listeners_json == *']'* ]] || return 1
  listeners_json=${listeners_json#*\[}
  listeners_json=${listeners_json%%\]*}
  for listener in "${expected[@]}"; do
    listener_present "$listeners_json" "$listener" || {
      warn "监听器未成功启动：${listener}"; return 1;
    }
  done
}

listener_present() {
  local list=$1 expected_listener=$2 without_default=''
  [[ $list == *"\"${expected_listener}\""* || $list == *"\"${expected_listener}/\""* ]] && return 0
  case $expected_listener in
    ws://*:80) without_default=${expected_listener%:80};;
    wss://*:443) without_default=${expected_listener%:443};;
  esac
  [[ -n $without_default ]] && [[ $list == *"\"${without_default}\""* || $list == *"\"${without_default}/\""* ]]
}

start_service_checked() {
  local was_active=false
  systemctl is-active --quiet easytier.service && was_active=true
  if ! systemctl enable easytier.service >/dev/null; then report_service_failure easytier.service 'EasyTier Core'; return 1; fi
  if [[ $was_active == true ]]; then
    if ! systemctl restart easytier.service; then report_service_failure easytier.service 'EasyTier Core'; return 1; fi
  else
    if ! systemctl start easytier.service; then report_service_failure easytier.service 'EasyTier Core'; return 1; fi
  fi
  if wait_service_healthy; then return 0; fi
  report_service_failure easytier.service 'EasyTier Core'
  return 1
}

activate_config() {
  local core_backup="${ARGS_FILE}.backup.$$" web_backup="${WEB_ARGS_FILE}.backup.$$"
  local had_core=false had_web=false had_web_db=false core_active=false core_enabled=false web_active=false web_enabled=false
  local files_ready=false failure_stage='写入配置文件'
  systemctl is-active --quiet easytier.service && core_active=true
  systemctl is-enabled --quiet easytier.service && core_enabled=true
  systemctl is-active --quiet easytier-web.service && web_active=true
  systemctl is-enabled --quiet easytier-web.service && web_enabled=true
  [[ -s $WEB_DB_FILE ]] && had_web_db=true
  if [[ -f $ARGS_FILE ]]; then cp -a -- "$ARGS_FILE" "$core_backup" || return 1; had_core=true; fi
  if [[ -f $WEB_ARGS_FILE ]]; then cp -a -- "$WEB_ARGS_FILE" "$web_backup" || { rm -f -- "$core_backup"; return 1; }; had_web=true; fi

  if [[ $BINARY_CHANGED == true && $web_active == true ]]; then
    if ! systemctl stop easytier-web.service || ! backup_web_database_for_transaction; then
      warn '无法安全备份 Web 账户数据库，已中止本次替换。'
      rm -f -- "$core_backup" "$web_backup"
      return 1
    fi
  fi

  if [[ $WEB_ENABLED == true && -n $WEB_ADMIN_PASSWORD ]]; then
    systemctl stop easytier-web.service >/dev/null 2>&1 || true
    if ! bootstrap_web_admin_password; then
      if [[ $web_active == true ]]; then systemctl start easytier-web.service >/dev/null 2>&1 || true; fi
      [[ $web_enabled == true ]] || systemctl disable easytier-web.service >/dev/null 2>&1 || true
      rm -f -- "$core_backup" "$web_backup"
      return 1
    fi
  fi

  if mv -f -- "${ARGS_FILE}.new" "$ARGS_FILE" && chmod 0600 "$ARGS_FILE"; then
    if [[ -f ${WEB_ARGS_FILE}.new ]]; then
      if mv -f -- "${WEB_ARGS_FILE}.new" "$WEB_ARGS_FILE" && chmod 0600 "$WEB_ARGS_FILE"; then files_ready=true; fi
    else
      rm -f -- "$WEB_ARGS_FILE" && files_ready=true
    fi
    if [[ $files_ready == true ]]; then
      failure_stage='Web 控制面板'
      if start_web_service_checked; then
        failure_stage='EasyTier Core'
        if start_service_checked; then
          rm -f -- "$core_backup" "$web_backup"
          ok 'EasyTier 与 Web 控制面板配置已生效。'
          return 0
        fi
      fi
    fi
  fi

  warn "失败阶段：${failure_stage}。"
  warn '新配置启动失败，正在自动恢复旧配置。'
  rm -f -- "${ARGS_FILE}.new" "${WEB_ARGS_FILE}.new"
  systemctl stop easytier.service easytier-web.service >/dev/null 2>&1 || true
  [[ $had_web_db == true ]] || remove_new_web_database
  if [[ $had_core == true ]]; then mv -f -- "$core_backup" "$ARGS_FILE" || return 1; else rm -f -- "$ARGS_FILE" || return 1; fi
  if [[ $had_web == true ]]; then mv -f -- "$web_backup" "$WEB_ARGS_FILE" || return 1; else rm -f -- "$WEB_ARGS_FILE" || return 1; fi
  systemctl reset-failed easytier.service easytier-web.service >/dev/null 2>&1 || true

  if [[ $had_web == true && $web_active == true ]]; then
    systemctl start easytier-web.service >/dev/null 2>&1 || true
    wait_web_healthy || warn '旧 Web 控制面板未能恢复运行。'
  fi
  if [[ $web_enabled == true ]]; then systemctl enable easytier-web.service >/dev/null 2>&1 || true; else systemctl disable easytier-web.service >/dev/null 2>&1 || true; fi
  if [[ $had_core == true && $core_active == true ]]; then
    systemctl start easytier.service >/dev/null 2>&1 || true
    wait_service_healthy || warn '旧 EasyTier 配置也未能恢复运行，请查看服务状态。'
  fi
  if [[ $core_enabled == true ]]; then systemctl enable easytier.service >/dev/null 2>&1 || true; else systemctl disable easytier.service >/dev/null 2>&1 || true; fi
  return 1
}

enable_updates() {
  if yesno '每周自动检查并更新 EasyTier？' y; then
    systemctl enable --now easytier-update.timer
    ok '已开启每周自动更新；只有下载校验和启动检查均通过才会保留新版本。'
  else systemctl disable --now easytier-update.timer >/dev/null 2>&1 || true; fi
}

show_web_access_info() {
  local bind port config_proto config_port candidate server_ip='服务器IP'
  [[ -s $WEB_ARGS_FILE ]] || { info 'Web 控制面板未启用。'; return 0; }
  bind=$(arg_value_from_file "$WEB_ARGS_FILE" --api-server-addr) || return 1
  port=$(arg_value_from_file "$WEB_ARGS_FILE" --api-server-port) || return 1
  config_proto=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-protocol) || return 1
  config_port=$(arg_value_from_file "$WEB_ARGS_FILE" --config-server-port) || return 1
  printf '\n%s\n' '========== Web 控制面板 =========='
  if [[ $bind == 127.0.0.1 ]]; then
    printf '面板仅监听本机。请先在自己的电脑终端运行：\n  ssh -L %s:127.0.0.1:%s 用户名@服务器IP\n然后浏览器打开：\n  http://127.0.0.1:%s\n' \
      "$port" "$port" "$port"
  else
    if command -v hostname >/dev/null 2>&1; then
      for candidate in $(hostname -I 2>/dev/null || true); do
        if valid_ipv4 "$candidate" && [[ $candidate != 127.* ]]; then server_ip=$candidate; break; fi
      done
    fi
    printf '浏览器打开：http://%s:%s\n' "$server_ip" "$port"
    warn "请在云安全组或防火墙放行 TCP ${port}，并限制为你自己的来源 IP。"
  fi
  printf '登录用户名：admin\n'
  if [[ -n $WEB_ADMIN_PASSWORD ]]; then printf '本次设置的登录密码：%s\n' "$WEB_ADMIN_PASSWORD"; else printf '登录密码：沿用已有 Web 管理员密码。\n'; fi
  printf 'Core 本机连接：%s://127.0.0.1:%s/admin（通常不要在安全组放行此端口）\n' "$config_proto" "$config_port"
}

show_status() {
  systemctl status easytier.service --no-pager -l || true
  if [[ -s $WEB_ARGS_FILE || -f $WEB_SERVICE_FILE ]]; then systemctl status easytier-web.service --no-pager -l || true; fi
}

show_logs() {
  journalctl -u easytier.service -u easytier-web.service -f
}

restart_running_services() {
  local web_active=$1 core_active=$2
  if [[ $web_active == true ]]; then
    systemctl reset-failed easytier-web.service >/dev/null 2>&1 || true
    systemctl restart easytier-web.service || return 1
    wait_web_healthy || return 1
  fi
  if [[ $core_active == true ]]; then
    systemctl reset-failed easytier.service >/dev/null 2>&1 || true
    systemctl restart easytier.service || return 1
    wait_service_healthy || return 1
  fi
}

do_install() {
  local was_active=false web_was_active=false
  need_root; need_systemd; install_tools; acquire_lock
  systemctl is-active --quiet easytier.service && was_active=true
  systemctl is-active --quiet easytier-web.service && web_was_active=true
  install_binary latest; configure; write_units
  begin_critical_section
  if ! activate_config; then
    if [[ $BINARY_CHANGED == true ]]; then
      rollback_binary
      restart_running_services "$web_was_active" "$was_active" || die '文件已回滚，但旧服务仍未恢复运行。'
    fi
    die '新配置启动失败，程序和配置已回滚。'
  fi
  finish_binary_transaction
  end_critical_section
  enable_updates
  show_web_access_info
  printf '\n常用命令：\n  查看节点：easytier-cli peer\n  查看状态：sudo easytier-installer --status\n  查看日志：sudo easytier-installer --logs\n  再次配置：sudo easytier-installer --configure\n  手动更新：sudo easytier-installer --update\n'
}

do_configure() {
  local was_active=false web_was_active=false arch
  need_root; need_systemd; acquire_lock; [[ -x ${INSTALL_DIR}/easytier-core ]] || die '请先安装 EasyTier。'
  systemctl is-active --quiet easytier.service && was_active=true
  systemctl is-active --quiet easytier-web.service && web_was_active=true
  arch=$(detect_arch)
  if release_arch_supports_web "$arch" && \
     [[ ! -x ${INSTALL_DIR}/easytier-web-embed || ! -x ${BIN_DIR}/easytier-web-embed ]]; then
    info '旧安装缺少 Web 控制面板组件，正在从已校验的官方 Release 补齐。'
    install_tools; install_binary latest
  elif [[ ! -x ${INSTALL_DIR}/easytier-web-embed ]]; then
    warn "上游当前未给 ${arch} 架构提供 Web 控制面板，将继续配置 Core/CLI。"
  fi
  configure; write_units; begin_critical_section
  if ! activate_config; then
    if [[ $BINARY_CHANGED == true ]]; then
      rollback_binary
      restart_running_services "$web_was_active" "$was_active" || die '组件已回滚，但旧服务仍未恢复运行。'
    fi
    die '新配置启动失败，已恢复旧配置。'
  fi
  finish_binary_transaction
  end_critical_section
  show_web_access_info
}

do_update() {
  need_root; need_systemd; install_tools; acquire_lock
  [[ -x ${INSTALL_DIR}/easytier-core ]] || die '尚未安装 EasyTier，请先运行 --install。'
  local before='' after='' was_active=false web_was_active=false
  [[ -f $VERSION_FILE ]] && before=$(<"$VERSION_FILE")
  systemctl is-active --quiet easytier.service && was_active=true
  systemctl is-active --quiet easytier-web.service && web_was_active=true
  save_proxy_env; install_binary latest
  [[ -f $VERSION_FILE ]] && after=$(<"$VERSION_FILE")
  begin_critical_section
  if [[ $BINARY_CHANGED == true && ($was_active == true || $web_was_active == true) ]]; then
    if [[ $web_was_active == true ]] && \
       { ! systemctl stop easytier-web.service || ! backup_web_database_for_transaction; }; then
      warn '无法安全备份 Web 账户数据库，正在回滚程序文件。'
      rollback_binary
      restart_running_services "$web_was_active" "$was_active" || die '程序已回滚，但旧服务仍未启动。'
      die '更新失败：未能创建一致的 Web 数据库备份。'
    fi
    if ! restart_running_services "$web_was_active" "$was_active"; then
      warn '新版本未能正常启动，正在回滚。'; rollback_binary
      restart_running_services "$web_was_active" "$was_active" || die '更新失败，旧版本文件已恢复，但旧服务仍未启动。'
      die '更新失败，已恢复旧版本并重新启动服务。'
    fi
  fi
  finish_binary_transaction
  end_critical_section
  [[ $before == "$after" ]] || ok "已从 ${before:-未知版本} 更新到 ${after}。"
  [[ $was_active == true || $web_was_active == true ]] || info '服务更新前处于停止状态，因此没有自动启动。'
}

do_uninstall() {
  need_root; need_systemd; acquire_lock
  warn '将停止 EasyTier 与 Web 控制面板，并删除程序、服务文件和自动更新任务。'
  local keep=true; yesno "保留 ${CONFIG_DIR} 中的组网配置、Web 账户和数据库？" y || keep=false
  systemctl stop easytier-update.timer >/dev/null 2>&1 || warn '自动更新计时器停止失败；将继续检查是否有更新任务在运行。'
  if systemctl is-active --quiet easytier-update.service; then
    systemctl stop easytier-update.service || die '自动更新任务停止失败，已中止卸载。'
    systemctl is-active --quiet easytier-update.service && die '自动更新任务仍在运行，已中止卸载。'
  fi
  systemctl disable easytier-update.timer easytier-update.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet easytier.service || systemctl cat easytier.service >/dev/null 2>&1 || [[ -f $SERVICE_FILE ]]; then
    systemctl stop easytier.service || die 'EasyTier 服务停止失败，未删除任何程序文件。'
  fi
  systemctl is-active --quiet easytier.service && die 'EasyTier 服务仍在运行，已中止卸载。'
  if systemctl is-active --quiet easytier-web.service || systemctl cat easytier-web.service >/dev/null 2>&1 || [[ -f $WEB_SERVICE_FILE ]]; then
    systemctl stop easytier-web.service || die 'Web 控制面板停止失败，未删除任何程序文件。'
  fi
  systemctl is-active --quiet easytier-web.service && die 'Web 控制面板仍在运行，已中止卸载。'
  systemctl disable easytier.service easytier-web.service >/dev/null 2>&1 || true
  rm -f -- "$SERVICE_FILE" "$WEB_SERVICE_FILE" "$UPDATE_SERVICE" "$UPDATE_TIMER" "$SELF_PATH" "$RUNNER_PATH" "$WEB_RUNNER_PATH" \
    "${BIN_DIR}/easytier-core" "${BIN_DIR}/easytier-cli" "${BIN_DIR}/easytier-web-embed" \
    "${INSTALL_DIR}/easytier-core" "${INSTALL_DIR}/easytier-cli" "${INSTALL_DIR}/easytier-web-embed" "$VERSION_FILE"
  rmdir -- "$INSTALL_DIR" "$(dirname "$RUNNER_PATH")" >/dev/null 2>&1 || true
  if [[ $keep == false ]]; then
    rm -f -- "$ARGS_FILE" "$WEB_ARGS_FILE" "$INSTALLER_ENV_FILE" "${ARGS_FILE}.new" "${WEB_ARGS_FILE}.new" \
      "$WEB_DB_FILE" "${WEB_DB_FILE}-wal" "${WEB_DB_FILE}-shm" "${WEB_DB_FILE}-journal"
    rmdir -- "$CONFIG_DIR" >/dev/null 2>&1 || warn "${CONFIG_DIR} 中仍有其他文件，已保留该目录。"
  fi
  systemctl daemon-reload; ok 'EasyTier 已卸载。'
}

menu() {
  printf '\n%s\n' '========== EasyTier 一键管理脚本 =========='
  printf '%s\n' '1) 安装 / 重新安装并配置' '2) 更新到最新版' '3) 重新配置' '4) 查看状态' '5) 实时日志' '6) 卸载' '0) 退出'
  local choice; read -r -p '请选择 [0-6]: ' choice
  case $choice in
    1) do_install;; 2) do_update;; 3) do_configure;; 4) show_status;;
    5) show_logs;; 6) do_uninstall;; 0) exit 0;; *) die '无效选择。';;
  esac
}

cleanup_main() {
  local rc=$?
  set +e
  stop_web_bootstrap
  [[ -z $WORK_TMP || ! -d $WORK_TMP ]] || rm -rf -- "$WORK_TMP"
  if ((rc != 0)) && [[ $BINARY_CHANGED == true ]]; then rollback_binary; fi
  return "$rc"
}

on_unhandled_error() {
  local rc=$? line=${BASH_LINENO[0]:-${LINENO}} function_name=${FUNCNAME[1]:-main}
  [[ $ERROR_MESSAGE_SHOWN == true ]] && return 0
  printf "\n%b[错误]%b 未处理错误（函数 %s，第 %s 行，退出码 %s）。请保留上方诊断。\n" \
    "$RED" "$NC" "$function_name" "$line" "$rc" >&2
}

main() {
  trap cleanup_main EXIT
  trap on_unhandled_error ERR
  validate_runtime_paths
  case ${1:-} in
    --install) do_install;; --update) do_update;; --configure) do_configure;; --uninstall) do_uninstall;;
    --status) show_status;; --logs) show_logs;;
    -h|--help) echo "用法：sudo bash $0 [--install|--update|--configure|--status|--logs|--uninstall]";;
    '') menu;; *) die "未知参数：$1（使用 --help 查看帮助）";;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
