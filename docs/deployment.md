# 服务器及系统服务指南

## 3. 部署 Linux x64 Server

### 3.1 下载并运行

在 Server CI 成功任务的 Artifacts 中下载 `SindreDeskServer-linux-x64-ci`，解压后执行：

```bash
sha256sum -c SHA256SUMS
chmod +x SindreDeskServer
./SindreDeskServer
```

以普通 Linux 用户运行，不需要额外安装 Go 或单独启动 hbbs/hbbr。运行器首次启动时生成密钥，控制台输出服务端公钥、数据目录以及 TCP 端口就绪信息。保持进程运行；Ctrl+C 停止。

### 3.2 数据和密钥

默认数据目录为当前用户配置目录下的 `sindredesk-server`（通常为 `~/.config/sindredesk-server`）。可显式指定：

```bash
export SINDREDESK_DATA_DIR="$HOME/sindredesk-data"
./SindreDeskServer
```

目录必须不是符号链接，权限为 0700 或更严格。相同目录只允许一个服务端实例。另开终端、使用同一数据目录，可读取公钥：

```bash
./SindreDeskServer key
```

公钥为 32 字节 Base64 字符串，复制给 Host 和 Client；不要分享私钥。升级时保留数据目录，否则重新生成密钥后两端需要重新配置。需要备份时先停止服务，妥善保管整个目录。

### 3.3 网络端口

| 协议 | 端口 | 用途 |
| --- | --- | --- |
| TCP | 21115 | NAT 类型检测 |
| TCP / UDP | 21116 | 注册、心跳、连接协商 |
| TCP | 21117 | 中继 |

服务器部署时，局域网使用服务器私有 IPv4；跨网络使用双方可访问的公网 IP 或域名，并配置防火墙、云安全组及必要端口映射。Host/Client 的无服务器局域网直连另使用 TCP 32118，设备发现使用 UDP 32119；只在可信网络的私有配置文件中开放这两个端口。公网部署不要开放 Host 的 32118 端口。上游可能监听额外 WebSocket 端口，本项目不要求对外开放这些端口。

若需要显式指定中继地址：

```bash
export SINDREDESK_RELAY=remote.example.com:21117
./SindreDeskServer
```

可选 systemd 部署（Linux 管理员执行；先确认未运行其他实例）：

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin sindredesk
sudo install -m 0755 SindreDeskServer /usr/local/bin/SindreDeskServer
sudo install -m 0644 deploy/sindredesk.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sindredesk
sudo systemctl status sindredesk
sudo journalctl -u sindredesk -f
sudo -u sindredesk env SINDREDESK_DATA_DIR=/var/lib/sindredesk /usr/local/bin/SindreDeskServer key
```

服务单元从对应源码版本获取；已有用户时跳过 useradd。systemd 在异常退出时重启，密钥保留在 /var/lib/sindredesk。手动运行可用同一数据目录执行 `./SindreDeskServer status` 查询进程锁与 TCP 端口状态；这不是协议认证检查。


### 电脑被控端系统级开机自启

电脑 Host 采用原生永久密码认证。首次启动自动生成固定密码，使用原生验证值及本机私钥派生密钥的加密显示缓存。旧版已设置密码无法恢复显示，可主动更换。

Windows：固定密码就绪后即可开启系统级自启；无服务器局域网直连不要求配置私服，只有数字连接码/跨网络使用时才需要私服。便携版会进入原生安装界面，Host 默认使用系统注册表指定的 Program Files 下的 SindreDeskHost 正式安装目录；管理员授权后由原生安装器导入配置并注册 Windows Service。安装完成后重新打开已安装 Host 检查状态。不要从可被普通用户修改的目录注册系统服务。

Linux（systemd 桌面环境）：管理员从可信 Release 解压完整 Host 运行目录，然后将完整目录安装至 /usr/lib/sindredesk-host，并保证目录及文件 root 所有且普通用户不可写；将 Host 发布包中 sindredesk-host.service 安装至 /etc/systemd/system/，执行 sudo systemctl daemon-reload。以普通用户启动 /usr/lib/sindredesk-host/sindredesk-host，固定密码就绪后即可开启系统级自启；局域网直连不要求私服，数字连接码/跨网络使用时再配置私服。不要以 root 启动 GUI。原生服务同步配置后启用系统服务。关闭开关使用原生停止/卸载服务入口。

注意：为匹配实际进程和服务名称，桌面 Host 的原生应用标识调整为 Windows SindreDeskHost、Linux sindredesk-host。升级时尝试迁移当前系统账户的两份旧 Host 配置；保留旧文件，不覆盖已存在的新配置。迁移失败时保留原配置路径供读取。升级前建议备份，升级后核对连接码及私服配置；实际迁移仍需真机验证。新版本重启后的 ID、密码和配置保持情况需要真实设备验证。Linux X11、Wayland 和登录管理器的登录前控制能力存在差异。六位密码应仅在可信网络内使用；无服务器直连使用签名握手与加密通道完成密码认证，首次成功登录后保存设备身份；首次连接仅在可信局域网使用。

