# EasyTier 中文一键安装与自动更新脚本

面向新手的 Linux / systemd 交互式安装器。它会自动识别 CPU 架构，从 EasyTier 官方 Release 安装最新稳定版，并逐步询问组网、监听端口、连接节点、子网代理等参数。

## 一键使用

```bash
curl -fsSL https://raw.githubusercontent.com/a15525082844-gif/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh && sudo bash easytier-installer.sh
```

中国大陆网络可使用加速地址：

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/a15525082844-gif/easytier-oneclick-installer/main/easytier-installer.sh -o easytier-installer.sh && sudo bash easytier-installer.sh
```

加速地址由第三方提供；重视供应链安全时，请优先使用上面的 GitHub 官方地址，并在执行前检查脚本内容。

> 建议先下载、阅读脚本，再用 `sudo` 执行。不要直接执行来源不明的 root 脚本。

如果 GitHub 在中国大陆下载较慢，脚本会依次尝试官方地址和多个公开加速地址。也可以指定自己的可信代理：

```bash
EASYTIER_GITHUB_PROXY=https://你的代理地址 sudo -E bash easytier-installer.sh
```

代理格式应为“代理前缀 + 完整 GitHub URL”，例如 `https://proxy.example.com/https://github.com/...`。

## 向导里最重要的四项

1. **网络名称**：同一虚拟网络的所有设备必须一致。
2. **网络密钥**：同一虚拟网络的所有设备必须一致；请使用随机且足够长的密钥。
3. **虚拟 IP**：新手可选 DHCP 自动分配；服务器建议设置不重复的固定 IP。
4. **对等节点 / 公共共享节点**：至少有一个其他节点的地址，或填写一个可信共享节点，设备才能互相发现。

监听地址示例：`tcp://0.0.0.0:11010`。主动连接地址示例：`tcp://1.2.3.4:11010`。如果服务器有防火墙或云安全组，需要放行你选择的 TCP/UDP 端口。

## 安装后的命令

```bash
# 查看节点和连接
easytier-cli peer

# 查看服务状态 / 实时日志
sudo easytier-installer --status
sudo easytier-installer --logs

# 重新运行配置向导 / 立即检查更新
sudo easytier-installer --configure
sudo easytier-installer --update
```

配置保存在 `/etc/easytier/config.args`，权限为 `0600`；程序位于 `/opt/easytier`。自动更新默认每周检查一次，版本变化后才会替换二进制并重启服务。

## 支持范围

- 使用 systemd 的 Linux（Debian、Ubuntu、CentOS、Rocky、AlmaLinux、Fedora、Arch、Alpine 等常见发行版）
- x86_64、aarch64、armv7、armhf、riscv64、loongarch64、mips、mipsel
- 只安装官方 Release 中的 `easytier-core` 和 `easytier-cli`

Windows、macOS、OpenWrt 不使用本脚本；请使用 EasyTier 官方对应安装包或 OpenWrt 插件。

## 安全说明

- 下载后优先使用 GitHub Release API 提供的 SHA-256 摘要校验；API 不可用时至少执行 ZIP 完整性检查并明确告警。
- 网络密钥不会写入 systemd unit，但 EasyTier 以命令行参数启动，root 用户仍可从进程信息读取它。
- 公开共享节点能够中继流量。即使 EasyTier 默认加密，也应只选择可信节点并使用强密钥。
- 公开 RPC、SOCKS5、WireGuard 或子网代理会扩大可访问范围；不需要的功能请不要开启。

上游项目：[EasyTier/EasyTier](https://github.com/EasyTier/EasyTier) · [官方中文网站](https://easytier.cn/)
