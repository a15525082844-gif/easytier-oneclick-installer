# EasyTier 中文一键安装与自动更新脚本

面向新手的 Linux / systemd 交互式安装器。脚本会识别 CPU 架构，安装 [EasyTier 官方 Release](https://github.com/EasyTier/EasyTier/releases) 的最新稳定版，并逐步询问组网、监听协议、端口、连接节点、子网代理等参数。

## 一键安装

GitHub 官方线路（海外服务器或已配置代理时使用）：

```bash
curl --disable -fsSL https://raw.githubusercontent.com/a15525082844-gif/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh && sudo bash easytier-installer.sh --install
```

中国大陆网络推荐使用国内优选 IPv4 加速线路：

```bash
curl --disable -fL https://v4.gh-proxy.org/https://raw.githubusercontent.com/a15525082844-gif/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh
echo '895c3a029fa6ab76258801575c54303b5811a9ced93a3e37836249c6cea4c958  easytier-installer.sh' | sha256sum -c -
less easytier-installer.sh
# 确认脚本内容后再执行：
sudo bash easytier-installer.sh --install
```

加速地址由第三方提供，不能安全地把它直接连接到 `sudo bash`。上面的摘要与本仓库当前脚本绑定，显示 `OK` 后仍建议查看完整脚本；EasyTier 程序包无论从哪条线路下载，都必须通过 GitHub 官方 SHA-256 校验，否则拒绝安装。

若你有自己的可信 GitHub 加速地址：

```bash
EASYTIER_GITHUB_PROXY=https://你的代理地址 sudo -E bash easytier-installer.sh --install
```

格式是“代理前缀 + 完整 GitHub URL”，例如 `https://proxy.example.com/https://github.com/...`。该地址会参加测速，并在同速时优先使用；同时会以 `0600` 权限保存，供每周自动更新继续使用。

## 主程序下载加速

安装器不会再固定等待缓慢的 GitHub 官方线路。下载 EasyTier 主程序前，它会：

1. 同时测试自定义线路、国内优选线路、备用线路和 GitHub 官方线路，最多等待 8 秒。
2. 每条线路只读取一小段公开 Release 文件，根据实际速度排序。
3. 优先从当前机器上最快的线路下载；连续 20 秒过慢或连接失败就自动换下一条。
4. 所有高速线路都失败时，仅对测速最优线路进行一次低速兼容重试。
5. 无论最终使用哪条镜像，都必须通过 GitHub 官方 SHA-256 和 ZIP 完整性检查才能安装。

默认候选包括 `v4.gh-proxy.org`、`cdn.gh-proxy.org`、`gh-proxy.com`、`ghfast.top` 和 GitHub 官方线路。线路速度会因地区、运营商和 CDN 缓存变化，所以脚本每次需要下载新版本时都会重新测速。

## 向导怎么填写

- 网络名称、网络密钥：同一虚拟网络的所有设备必须完全一致。
- 虚拟 IP：新手选 DHCP；服务器也可设置一个不重复的固定 IP。
- 监听协议：默认 `tcp,udp` 已够多数场景。每种协议会单独询问端口，向导会阻止端口冲突。
- 主动连接节点：例如 `tcp://1.2.3.4:11010`；多个地址用逗号分隔。
- 公共共享节点：只填写你信任的共享节点，不清楚时可留空。
- 子网代理、SOCKS5、WireGuard 入口：没有明确需要时都可留空或选“否”。
- 高级参数：每行输入一个 EasyTier 原生参数或参数值，直接回车结束。

TCP 与 UDP 可以使用相同数字端口；同为 TCP 或同为 UDP 的协议不能占用同一端口。使用云服务器时，还要在防火墙或安全组中放行相应的 TCP/UDP 端口。

## 安装后的命令

```bash
# 查看节点和连接
easytier-cli peer

# 查看服务状态 / 实时日志
sudo easytier-installer --status
sudo easytier-installer --logs

# 重新运行向导 / 立即检查更新
sudo easytier-installer --configure
sudo easytier-installer --update

# 卸载
sudo easytier-installer --uninstall
```

配置保存在 `/etc/easytier/config.args`，权限为 `0600`；程序位于 `/opt/easytier`。重新配置会真正重启服务，新配置启动失败时自动恢复旧配置。

## 自动更新与回滚

安装结束时可选择开启每周自动更新。更新过程会：

1. 从 GitHub 官方接口取得最新版本和对应程序包的 SHA-256。
2. 并行小块测速，自定义代理、国内加速和 GitHub 官方线路一起参与排序。
3. 从最快线路开始下载；低速、超时或下载失败会快速切换下一条。
4. 先比对官方 SHA-256，再检查 ZIP，校验不符会丢弃并换线路。
5. 仅在版本变化时替换程序；原服务原本停止时不会擅自启动。
6. 更新后服务无法正常运行时，自动恢复旧程序和版本号。

出于 root 供应链安全考虑，定时任务不会从可变的 `main` 分支静默替换管理脚本本身。要取得本仓库的新脚本，请重新执行上方 GitHub 官方线路的下载命令并查看变更。

如果 GitHub 官方摘要来源不可达，脚本会停止安装，而不会把第三方镜像返回的文件当作可信文件。特殊网络环境可同时明确指定版本和从独立可信渠道取得的摘要：

```bash
EASYTIER_VERSION=v2.6.4 EASYTIER_SHA256=64位十六进制摘要 sudo -E bash easytier-installer.sh --install
```

## 支持范围

- 使用 systemd 的常见 Linux：Debian、Ubuntu、CentOS、Rocky、AlmaLinux、Fedora、Arch、Alpine 等。
- x86_64、aarch64、arm/armhf、armv7/armv7hf、riscv64、loongarch64、mips、mipsel。
- 仅安装上游 Release 中的 `easytier-core` 和 `easytier-cli`。

Windows、macOS、OpenWrt 请使用 EasyTier 官方对应安装包或插件。

## 安全说明

- 下载镜像只负责传输文件，永远不能提供自己文件的可信摘要；摘要只取自 GitHub 官方站或用户显式提供。
- 测速会向候选镜像发送公开 EasyTier Release 的小块请求；不会向镜像发送网络密钥、GitHub Token 或私有仓库地址。
- 网络密钥不写入 systemd unit，但 EasyTier 以命令行参数启动；root 用户仍可从进程信息读取它。
- 公共共享节点能够中继流量，应只选择可信节点并使用足够强的网络密钥。
- RPC 只监听 `127.0.0.1`。公开 SOCKS5、WireGuard 或子网代理会扩大可访问范围，不需要时不要开启。

上游项目：[EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) · [EasyTier 中文网站](https://easytier.cn/)
