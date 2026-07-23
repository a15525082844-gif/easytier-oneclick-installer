# EasyTier 中文一键安装与自动更新脚本

面向新手的 Linux / systemd 交互式安装器。脚本会识别 CPU 架构，安装 [EasyTier 官方 Release](https://github.com/EasyTier/EasyTier/releases) 的最新稳定版和官方 Web 控制面板，并逐步询问组网、监听协议、端口、连接节点、子网代理、Web 访问范围等参数。

## 一键安装

GitHub 官方线路（海外服务器或已配置代理时使用）：

```bash
curl --disable -fsSL https://raw.githubusercontent.com/AiCodeNb/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh && sudo bash easytier-installer.sh --install
```

中国大陆网络推荐使用国内优选 IPv4 加速线路：

```bash
curl --disable -fL https://v4.gh-proxy.org/https://raw.githubusercontent.com/AiCodeNb/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh
echo '8ea007d916682171b1b1141d4c3130657a839d2b3785389d04987557cb11cde5  easytier-installer.sh' | sha256sum -c -
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

## 两种主机参数管理模式

向导首先会问“主机参数由谁管理”。这个选项只决定以后在哪里修改这台主机的组网参数，和后面的“私有网络 / IP + 端口开放连接”不是一回事：前者决定**怎么管理**，后者决定**谁可以连接**。

### 1）安装器管理（默认，适合新手）

- 全新安装时直接回车就会选择此模式。
- 网络名称、密钥、虚拟 IP、监听端口、连接节点等参数都由终端向导管理。
- Web 面板仍可查看这台主机和运行状态，但为避免网页配置与启动参数互相覆盖，主机参数会显示为只读。
- 需要修改时运行 `sudo easytier-installer --configure`，继续选择“安装器管理”，再按提示填写。

### 2）Web 完全管理

- 安装器会强制启用 Web 控制面板，并把主网络保存为 Web 可以读写的配置。
- 以后可在 Web 的“远程管理”中修改网络名称、密钥、虚拟 IP、监听器、连接节点等参数，也可以启动、停用或删除网络。
- 在 Web 中保存的修改会写入磁盘；重启 EasyTier、重启服务器或自动更新主程序后仍会保留。
- 已处于此模式时再次运行 `--configure`，安装器会保留面板中的全部网络参数和网络文件，只重新询问本机 RPC、Web 访问范围和相关端口。
- 此模式要求当前架构的 EasyTier Release 包含 `easytier-web-embed`；不带 Web 组件的架构不能选择。

### 如何切换

运行下面的命令，在向导开头选择另一种管理模式：

```bash
sudo easytier-installer --configure
```

- 从“安装器管理”切到“Web 完全管理”时，如果原 Core 正常运行，安装器会导出当前完整网络配置并保留主机身份与网络实例身份；没有可导出的运行实例时，则由向导创建一个可继续在 Web 中修改的初始网络。
- 从“Web 完全管理”切回“安装器管理”时，需要在终端向导中重新确认组网参数；切换成功后，以这次向导填写的参数为准，Web 中原来的参数不再控制当前运行的主网络。
- 切换时会先停止相关服务并备份当前配置、网络文件和 Web 数据库。只有新配置通过检查并成功启动才会生效；失败会自动恢复旧模式和旧配置。

管理方式变更属于重要操作。虽然脚本带自动回滚，长期运行或保存了多个 Web 网络时，仍建议先自行备份整个 `/etc/easytier` 目录。不要在 Web 完全管理模式下额外加入会覆盖网络的 Core 命令行参数，否则该网络会重新变成只读。

## 向导怎么填写

- 提示中带 `[默认值]` 的项目，不输入内容直接回车就会采用该值；可选项目直接回车表示不启用。
- 主机参数管理模式：全新安装默认选择“安装器管理”；以后重新运行向导时，直接回车会沿用当前管理模式。
- 节点接入方式有两个选项：
  - `1) 私有网络（推荐，默认）`：只有网络名称和网络密钥都相同的设备才能连接本节点，其他虚拟网络不能借用本节点中转。
  - `2) IP + 端口开放连接（公共共享 / 中继）`：其他 EasyTier 网络知道本机 IP 和监听端口后，就能连接本机并用于发现和中继。它们不需要知道本共享节点自己的网络名称和密钥，仍使用各自网络的名称和密钥，也不能借此加入你的私有网络；该模式会消耗本机带宽和连接资源，因此脚本会要求再次确认。
- 网络名称、网络密钥：同一虚拟网络的所有设备必须完全一致。网络密钥会明文显示，并预先生成一个随机默认值；直接回车采用它，再复制到其他设备即可。
- 虚拟 IP：新手选 DHCP；服务器也可设置一个不重复的固定 IP。
- 监听协议：默认 `tcp,udp` 已够多数场景。每种协议会单独询问端口，向导会阻止端口冲突。
- 主动连接节点：例如 `tcp://1.2.3.4:11010`；多个地址用逗号分隔。
- 公共共享节点：只填写你信任的共享节点，不清楚时可留空。
- 子网代理、SOCKS5、WireGuard 入口：没有明确需要时都可留空或选“否”。
- Web 控制面板：默认启用；访问范围直接回车选择“仅本机”，可通过 SSH 隧道安全访问。需要从局域网或公网直接打开时选择 `2`。
- Web 登录密码：首次启用时会明文显示一个随机默认密码，直接回车即可使用；登录用户名固定为 `admin`。
- 高级参数：每行输入一个 EasyTier 原生参数或参数值，直接回车结束。

TCP 与 UDP 可以使用相同数字端口；同为 TCP 或同为 UDP 的协议不能占用同一端口。使用云服务器时，还要在防火墙或安全组中放行相应的 TCP/UDP 端口。

## Web 控制面板

安装器使用上游发行包中的 `easytier-web-embed`，同时提供网页、API 和配置下发服务。首次启用时，安装器会先把面板临时限制在 `127.0.0.1`，自动完成以下安全初始化，全部成功后才正式启动：

1. 把上游内置 `admin` 账户的默认密码改为向导中显示的新密码。
2. 把内置 `user` 账户的默认密码改成不可预测的随机值。
3. 关闭网页自助注册。
4. 使用新密码重新登录验证，并检查 Web 服务能持续运行。

默认端口如下，向导中都可以修改：

- `11211/TCP`：网页与 API。
- `22020/UDP`：本机 EasyTier Core 接入控制面板的配置下发端口，也可改为 TCP 或 WS。

脚本会同时检查系统中正在监听的端口。若 `11211`（也是 Memcached 常用端口）或配置下发端口已被其他程序占用，会明确提示并自动改用相邻空闲端口；最终访问地址以安装完成时打印的端口为准。

选择“仅本机”后，安装完成会打印 SSH 隧道命令。先在自己的电脑运行该命令，再打开脚本显示的 `http://127.0.0.1:端口`。选择“局域网 / 公网直接访问”后，打开脚本显示的 `http://服务器IP:端口`，并只把该 TCP 端口放行给可信来源；仅管理同机 Core 时通常不要在安全组放行配置下发端口。

面板自身只提供 HTTP。若需长期从公网访问，请限制来源 IP，并使用 Nginx、Caddy 等反向代理配置 HTTPS。Web 账户数据库保存在 `/etc/easytier/web.db`，重新配置和更新都会保留已有密码。

Web 密码以不可逆哈希保存，忘记后无法查看原密码。可直接安全重置：

```bash
sudo easytier-installer --reset-web-password
```

终端会明文显示输入内容；不输入直接回车会采用当场生成的随机强密码。重置过程只修改 `admin` 的密码，不改 Core 组网参数，也会保留其他 Web 账户、设备和配置：脚本先停止 Web 并创建经过完整性检查的数据库备份，再让当前安装的 EasyTier Web 在临时数据库中生成兼容的密码哈希，写入后用新密码实际登录验证。任何一步失败都会恢复原数据库和原服务状态。Web 原本处于停止状态时，重置后仍保持停止。

如果 Web 的“远程管理”中主机参数是只读，这通常表示当前选择的是“安装器管理”，不是面板故障。可先运行 `sudo easytier-installer --status` 查看当前模式；确实需要在网页中修改时，再用 `sudo easytier-installer --configure` 切换到“Web 完全管理”。

旧版脚本已经安装过 EasyTier、但缺少 Web 组件时，下载本仓库最新版脚本并执行：

```bash
sudo bash easytier-installer.sh --configure
```

脚本会从经过官方 SHA-256 校验的 Release 自动补齐 Web 组件，然后进入向导。

如果新配置仍然不能启动，最新版脚本会直接标明失败发生在“Web 控制面板”还是“EasyTier Core”，显示经过敏感信息隐藏的服务状态、最近日志和端口占用进程，然后再恢复旧配置，不再只显示“第 1 行执行失败”。

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

# 忘记 Web 管理员密码时安全重置
sudo easytier-installer --reset-web-password

# 卸载
sudo easytier-installer --uninstall
```

当前管理模式记录在 `/etc/easytier/management.mode`，Web 启动参数保存在 `/etc/easytier/web.args`。在“安装器管理”模式下，组网参数保存在 `/etc/easytier/config.args`；在“Web 完全管理”模式下，该文件只保存 Core 的本机启动参数，可编辑的网络配置保存在 `/etc/easytier/networks/<网络实例 UUID>.toml`。主机身份与安装器主网络身份分别保存在 `/etc/easytier/machine-id` 和 `/etc/easytier/managed-instance-id`，切换与更新时会保持稳定，避免 Web 把同一台主机误认成新设备。配置文件权限为 `0600`，网络配置目录权限为 `0700`；程序位于 `/opt/easytier`。重新配置会真正重启 Core 和 Web 服务，新配置启动失败时自动恢复旧配置。

## 自动更新与回滚

安装结束时可选择开启每周自动更新。更新过程会：

1. 从 GitHub 官方接口取得最新版本和对应程序包的 SHA-256。
2. 并行小块测速，自定义代理、国内加速和 GitHub 官方线路一起参与排序。
3. 从最快线路开始下载；低速、超时或下载失败会快速切换下一条。
4. 先比对官方 SHA-256，再检查 ZIP，校验不符会丢弃并换线路。
5. 仅在版本变化时替换程序；原服务原本停止时不会擅自启动。
6. 更新前对停止后的 Web 数据库做一致备份；Core 或 Web 启动失败时，自动恢复旧程序、版本号和 Web 数据库。

出于 root 供应链安全考虑，定时任务不会从可变的 `main` 分支静默替换管理脚本本身。要取得本仓库的新脚本，请重新执行上方 GitHub 官方线路的下载命令并查看变更。

如果 GitHub 官方摘要来源不可达，脚本会停止安装，而不会把第三方镜像返回的文件当作可信文件。特殊网络环境可同时明确指定版本和从独立可信渠道取得的摘要：

```bash
EASYTIER_VERSION=v2.6.4 EASYTIER_SHA256=64位十六进制摘要 sudo -E bash easytier-installer.sh --install
```

## 支持范围

- 使用 systemd 的常见 Linux：Debian、Ubuntu、CentOS、Rocky、AlmaLinux、Fedora、Arch、Alpine 等。
- x86_64、aarch64、arm/armhf、armv7/armv7hf、riscv64、loongarch64、mips、mipsel。
- 安装上游 Release 中的 `easytier-core`、`easytier-cli` 和（该架构提供时）`easytier-web-embed`。

上游 v2.6.4 的 MIPS / MIPSel 发行包未包含 `easytier-web-embed`，因此这两个架构只安装 Core/CLI，并在向导中明确提示；其余上述 Linux 架构可启用 Web 面板。

Windows、macOS、OpenWrt 请使用 EasyTier 官方对应安装包或插件。

## 安全说明

- 下载镜像只负责传输文件，永远不能提供自己文件的可信摘要；摘要只取自 GitHub 官方站或用户显式提供。
- 测速会向候选镜像发送公开 EasyTier Release 的小块请求；不会向镜像发送网络密钥、GitHub Token 或私有仓库地址。
- 配置向导会明文显示网络密钥，方便新手确认和复制；在他人可看到屏幕或终端记录的环境中，请自行输入新的强密钥。
- “安装器管理”模式不会把网络密钥写入 systemd unit，但 EasyTier 会以命令行参数启动，root 用户仍可从配置和进程信息读取它；“Web 完全管理”模式把密钥保存在仅 root 可读的网络配置文件中，能登录 Web 的管理用户也可能查看或修改它。
- 公共共享节点能够中继流量，应只选择可信节点并使用足够强的网络密钥。
- 本机默认使用私有网络模式。只有明确要运营公共共享节点时才选择第二项；该模式可能被扫描、滥用中继或消耗大量流量、CPU、内存和连接数，请配置防火墙并监控带宽。
- RPC 只监听 `127.0.0.1`。公开 SOCKS5、WireGuard 或子网代理会扩大可访问范围，不需要时不要开启。
- Web 面板首次启用会替换两个上游默认账户密码并关闭注册；已有数据库不会被重置。请妥善保存 `admin` 密码。
- 忘记 `admin` 密码时只能重置、不能找回明文；重置命令不会接收命令行密码参数，避免密码出现在进程列表中。
- Web 面板直接对外提供的是 HTTP，不应无来源限制地暴露到公网；推荐仅本机监听并使用 SSH 隧道，或在可信反向代理后启用 HTTPS。

上游项目：[EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) · [EasyTier 中文网站](https://easytier.cn/)
