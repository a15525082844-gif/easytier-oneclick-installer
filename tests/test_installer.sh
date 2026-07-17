#!/usr/bin/env bash
set -Eeuo pipefail

TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export EASYTIER_INSTALLER_TEST_MODE=1
export EASYTIER_INSTALL_DIR="$TEST_ROOT/opt/easytier"
export EASYTIER_BIN_DIR="$TEST_ROOT/bin"
export EASYTIER_CONFIG_DIR="$TEST_ROOT/etc/easytier"
export EASYTIER_SYSTEMD_DIR="$TEST_ROOT/systemd"
export EASYTIER_SELF_PATH="$TEST_ROOT/sbin/easytier-installer"
export EASYTIER_RUNNER_PATH="$TEST_ROOT/lib/easytier/run"
export EASYTIER_MAX_ASSET_BYTES=64

# shellcheck disable=SC1091
source "$(dirname "$0")/../easytier-installer.sh"
[[ $ARGS_FILE == "$TEST_ROOT/"* ]] || { echo 'test paths escaped TEST_ROOT' >&2; exit 1; }

pass=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"; ((pass+=1)); }
assert_ok() { "$@" || fail "command failed: $*"; ((pass+=1)); }
assert_fail() { if "$@"; then fail "command unexpectedly succeeded: $*"; fi; ((pass+=1)); }

digest='61b659eaedba658fa66fe47d17e1426cdd77e5d02fa15fed447bb4357c09dfd6'
json='{"tag_name":"v2.6.4","assets":[{"name":"other.zip","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},{"name":"target.zip","uploader":{"login":"nested"},"digest":"sha256:61B659EAEDBA658FA66FE47D17E1426CDD77E5D02FA15FED447BB4357C09DFD6","browser_download_url":"https://example/target"},{"name":"after.zip","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
actual=$(printf '%s' "$json" | extract_asset_digest_from_json target.zip)
assert_eq "$actual" "$digest"

missing='{"assets":[{"name":"target.zip","digest":null},{"name":"after.zip","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}'
if actual=$(printf '%s' "$missing" | extract_asset_digest_from_json target.zip); then fail "missing digest was accepted: $actual"; fi
((pass+=1))

html='<clipboard-copy value="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" aria-label="Copy to clipboard digest for other.zip"></clipboard-copy>
<clipboard-copy value="sha256:61B659EAEDBA658FA66FE47D17E1426CDD77E5D02FA15FED447BB4357C09DFD6" aria-label="Copy to clipboard digest for target.zip"></clipboard-copy>'
actual=$(printf '%s' "$html" | extract_asset_digest_from_html target.zip)
assert_eq "$actual" "$digest"

for ip in 0.0.0.0 10.126.126.2 255.255.255.255; do assert_ok valid_ipv4 "$ip"; done
for ip in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d; do assert_fail valid_ipv4 "$ip"; done
assert_ok valid_port 1; assert_ok valid_port 65535
assert_fail valid_port 0; assert_fail valid_port 011010; assert_fail valid_port 65536; assert_fail valid_port 999999999999999999999; assert_fail valid_port abc
assert_ok valid_ipv4_cidr 10.14.14.0/24
assert_ok valid_ipv4_cidr 10.14.14.1/32
assert_fail valid_ipv4_cidr 10.14.14.1/24
assert_fail valid_ipv4_cidr 10.14.14.0/33

assert_eq "$(protocol_family tcp)" tcp
assert_eq "$(protocol_family faketcp)" tcp
assert_eq "$(protocol_family quic)" udp
assert_eq "$(protocol_default_port ws)" 11011
assert_eq "$(protocol_default_port quic)" 11012
assert_ok valid_proxy 'https://proxy.example/prefix'
assert_fail valid_proxy 'http://proxy.example'
assert_fail valid_proxy $'https://proxy.example/\nBAD=1'

default_secret=$(generate_default_secret)
[[ $default_secret =~ ^et-[0-9a-fA-F]{20}$ ]] || fail "invalid generated default secret: $default_secret"
((pass+=1))
ask_result=''
ask ask_result 'test prompt' 'recommended-value' <<< ''
assert_eq "$ask_result" 'recommended-value'
ask ask_result 'test prompt' 'recommended-value' <<< 'visible-value'
assert_eq "$ask_result" 'visible-value'
if grep -F 'read -r -s' "$(dirname "$0")/../easytier-installer.sh" >/dev/null; then
  fail 'network secret input is still hidden'
fi
((pass+=1))

mkdir -p "$TEST_ROOT/self"
printf '#!/usr/bin/env bash\necho ok\n' > "$TEST_ROOT/self/source.sh"
install_self "$TEST_ROOT/self/source.sh" "$TEST_ROOT/self/dest.sh"
assert_eq "$("$TEST_ROOT/self/dest.sh")" ok
assert_ok install_self "$TEST_ROOT/self/dest.sh" "$TEST_ROOT/self/dest.sh"

mkdir -p "$EASYTIER_CONFIG_DIR"
printf '%s\n' '--network-name' 'name with spaces' > "${ARGS_FILE}.new"
cat > "$TEST_ROOT/fake-core" <<'EOF'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ARG_LOG"
[[ " $* " != *' --bad '* ]] || exit 2
exit 1
EOF
chmod +x "$TEST_ROOT/fake-core"
export ARG_LOG="$TEST_ROOT/args.log"
assert_ok validate_config_candidate "$TEST_ROOT/fake-core"
grep -Fx '[name with spaces]' "$ARG_LOG" >/dev/null || fail 'argument containing spaces was split'
printf '%s\n' '--bad' > "${ARGS_FILE}.new"
assert_fail validate_config_candidate "$TEST_ROOT/fake-core"
((pass+=1))

mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/easytier-cli" <<'EOF'
#!/usr/bin/env bash
if [[ ${NODE_MODE:-good} == good ]]; then
  cat <<'JSON'
{"listeners":["ring://id","tcp://0.0.0.0:11010","ws://0.0.0.0:11011/"],"config":"listeners = [\"tcp://0.0.0.0:11010\", \"ws://0.0.0.0:11011\"]"}
JSON
elif [[ $NODE_MODE == bad ]]; then
  cat <<'JSON'
{"listeners":["ring://id","tcp://0.0.0.0:11010"],"config":"listeners = [\"tcp://0.0.0.0:11010\", \"ws://0.0.0.0:11011\"]"}
JSON
else
  cat <<'JSON'
{"listeners":["ring://id","tcp://0.0.0.0:11010","ws://0.0.0.0:11011/"],"config":""}
JSON
  exit 1
fi
EOF
chmod +x "$INSTALL_DIR/easytier-cli"
printf '%s\n' '--listeners' 'tcp://0.0.0.0:11010' '--listeners' 'ws://0.0.0.0:11011' \
  '--rpc-portal' '127.0.0.1:15888' > "$ARGS_FILE"
export NODE_MODE=good
assert_ok verify_runtime_config
export NODE_MODE=bad
assert_fail verify_runtime_config
export NODE_MODE=error
assert_fail verify_runtime_config
export NODE_MODE=good
assert_ok listener_present '["ws://0.0.0.0/"]' 'ws://0.0.0.0:80'
assert_ok listener_present '["wss://0.0.0.0/"]' 'wss://0.0.0.0:443'
assert_fail listener_present '["tcp://0.0.0.0:110100"]' 'tcp://0.0.0.0:11010'

MOCK_LOG="$TEST_ROOT/systemctl.log"; MOCK_ACTIVE=true
systemctl() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case $1 in
    is-active) [[ $MOCK_ACTIVE == true ]];;
    restart|start) MOCK_ACTIVE=true;;
    *) return 0;;
  esac
}
sleep() { :; }
assert_ok start_service_checked
grep -Fx 'enable easytier.service' "$MOCK_LOG" >/dev/null || fail 'service was not enabled'
grep -Fx 'restart easytier.service' "$MOCK_LOG" >/dev/null || fail 'active service was not restarted'
if grep -F -- '--now' "$MOCK_LOG" >/dev/null; then fail 'start flow still uses enable --now'; fi
((pass+=3))

GOOD_BYTES='verified-release-bytes'
BAD_BYTES='mirror-returned-wrong-bytes'
expected=$(printf '%s' "$GOOD_BYTES" | sha256sum | awk '{print $1}')
PROBE_LOG="$TEST_ROOT/probe.log"
PROBE_META_LOG="$TEST_ROOT/probe-meta.log"
DOWNLOAD_LOG="$TEST_ROOT/download.log"
CURL_ARGS_LOG="$TEST_ROOT/curl-args.log"
UNZIP_LOG="$TEST_ROOT/unzip.log"
CURL_SCENARIO=fast_mirror

route_for_url() {
  case $1 in
    https://proxy.example/*) echo custom;;
    https://v4.gh-proxy.org/*) echo v4_proxy;;
    https://cdn.gh-proxy.org/*) echo cdn_proxy;;
    https://ghfast.top/*) echo ghfast;;
    https://gh-proxy.com/*) echo gh_proxy;;
    https://github.com/*) echo official;;
    *) echo unknown;;
  esac
}

reset_download_mock() {
  CURL_SCENARIO=$1
  : > "$PROBE_LOG"
  : > "$PROBE_META_LOG"
  : > "$DOWNLOAD_LOG"
  : > "$CURL_ARGS_LOG"
  : > "$UNZIP_LOG"
}

# 模拟 curl 的两种调用：带 --range 的短探测，以及随后真正输出程序包的完整下载。
# 探测结果格式与真实 curl -w 一致：HTTP 状态、收到的字节数、平均 B/s。
curl() {
  local first=${1-} url='' route='' max_time='' output='' arg probe=false
  printf '%s\n' "$first" >> "$CURL_ARGS_LOG"
  while (($#)); do
    arg=$1
    case $arg in
      --range|-r) probe=true; shift;;
      --range=*|-r*) probe=true;;
      --max-time) shift; max_time=${1-};;
      --max-time=*) max_time=${arg#*=};;
      -o|--output) shift; output=${1-};;
      --output=*) output=${arg#*=};;
      https://*) url=$arg;;
    esac
    shift || true
  done
  route=$(route_for_url "$url")

  if [[ $probe == true ]]; then
    printf '%s\n' "$route" >> "$PROBE_LOG"
    printf '%s\t%s\n' "$route" "${max_time:-missing}" >> "$PROBE_META_LOG"
    case "${CURL_SCENARIO}:${route}" in
      fast_mirror:official) return 28;;
      fast_mirror:ghfast) printf '206 524288 900000\n';;
      fast_mirror:v4_proxy) printf '206 524288 700000\n';;
      fast_mirror:cdn_proxy) printf '206 524288 600000\n';;
      fast_mirror:gh_proxy) printf '206 524288 500000\n';;
      hash_fallback:ghfast) printf '206 524288 900000\n';;
      hash_fallback:gh_proxy) printf '206 524288 800000\n';;
      hash_fallback:v4_proxy) printf '206 524288 700000\n';;
      hash_fallback:cdn_proxy) printf '206 524288 600000\n';;
      hash_fallback:official) printf '206 524288 400000\n';;
      custom_tie:custom|custom_tie:ghfast) printf '206 524288 900000\n';;
      custom_tie:v4_proxy) printf '206 524288 700000\n';;
      custom_tie:cdn_proxy) printf '206 524288 600000\n';;
      custom_tie:gh_proxy) printf '206 524288 500000\n';;
      custom_tie:official) printf '206 524288 400000\n';;
      oversized:*) printf '206 524288 500000\n';;
      *) return 28;;
    esac
    return 0
  fi

  printf '%s\n' "$route" >> "$DOWNLOAD_LOG"
  case "${CURL_SCENARIO}:${route}" in
    hash_fallback:ghfast)
      if [[ -n $output && $output != /dev/null ]]; then printf '%s' "$BAD_BYTES" > "$output"; else printf '%s' "$BAD_BYTES"; fi;;
    oversized:*)
      if [[ -n $output && $output != /dev/null ]]; then printf '%080d' 0 > "$output"; else printf '%080d' 0; fi;;
    *)
      if [[ -n $output && $output != /dev/null ]]; then printf '%s' "$GOOD_BYTES" > "$output"; else printf '%s' "$GOOD_BYTES"; fi;;
  esac
}

unzip() { printf 'called\n' >> "$UNZIP_LOG"; return 0; }

# 官方线路探测超时不应触发 1800 秒完整下载；最快镜像应直接成为首选。
unset EASYTIER_GITHUB_PROXY
reset_download_mock fast_mirror
download_verified_asset v2.6.4 x86_64 "$TEST_ROOT/fast-mirror.zip" "$expected"
assert_eq "$(<"$TEST_ROOT/fast-mirror.zip")" "$GOOD_BYTES"
assert_eq "$(sed -n '1p' "$DOWNLOAD_LOG")" ghfast
assert_eq "$(wc -l < "$DOWNLOAD_LOG" | tr -d ' ')" 1
for route in official ghfast gh_proxy v4_proxy cdn_proxy; do grep -Fx "$route" "$PROBE_LOG" >/dev/null || fail "$route did not participate in probing"; done
awk -F '\t' '$1 == "official" && $2 ~ /^[0-9]+$/ && $2 <= 8 { ok=1 } END { exit !ok }' "$PROBE_META_LOG" || fail 'slow official probe was not time-bounded'
assert_eq "$(sort -u "$CURL_ARGS_LOG")" '--disable'
((pass+=6))

# 最快镜像若返回错误摘要，必须立刻换到测速第二名，且坏包不能送进 unzip。
reset_download_mock hash_fallback
download_verified_asset v2.6.4 x86_64 "$TEST_ROOT/hash-fallback.zip" "$expected"
assert_eq "$(<"$TEST_ROOT/hash-fallback.zip")" "$GOOD_BYTES"
assert_eq "$(sed -n '1p' "$DOWNLOAD_LOG")" ghfast
assert_eq "$(sed -n '2p' "$DOWNLOAD_LOG")" gh_proxy
assert_eq "$(wc -l < "$DOWNLOAD_LOG" | tr -d ' ')" 2
assert_eq "$(wc -l < "$UNZIP_LOG" | tr -d ' ')" 1

# 自定义代理必须参与测速；同速时保持候选原顺序，因此自定义代理优先。
export EASYTIER_GITHUB_PROXY='https://proxy.example'
reset_download_mock custom_tie
download_verified_asset v2.6.4 x86_64 "$TEST_ROOT/custom-proxy.zip" "$expected"
grep -Fx custom "$PROBE_LOG" >/dev/null || fail 'custom proxy did not participate in probing'
assert_eq "$(sed -n '1p' "$DOWNLOAD_LOG")" custom
assert_eq "$(wc -l < "$DOWNLOAD_LOG" | tr -d ' ')" 1
((pass+=1))

# 下载上限在测速排序后仍必须生效，且所有超限临时文件都会清理。
unset EASYTIER_GITHUB_PROXY
reset_download_mock oversized
if (download_verified_asset v2.6.4 x86_64 "$TEST_ROOT/too-large.zip" "$expected" >/dev/null 2>&1); then
  fail 'oversized downloads were accepted'
fi
[[ ! -e $TEST_ROOT/too-large.zip && ! -e $TEST_ROOT/too-large.zip.part ]] || fail 'oversized partial file was retained'
[[ ! -s $UNZIP_LOG ]] || fail 'oversized downloads reached unzip'
((pass+=2))

printf 'PASS: %d assertions\n' "$pass"
