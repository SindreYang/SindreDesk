# SindreDesk

基于 RustDesk 的极简、自托管远程桌面。控制端与被控端独立安装，用户只需配置私有服务器地址、公钥以及连接码和临时密码。

> 当前为开发测试版，不是生产稳定版。Windows、Linux 两种客户端角色已通过上一轮编译，Linux 服务端已通过真实进程集成测试；Android ARM64 打包冲突已修正，仍待新版本构建验证。所有平台的真实远程会话仍待验收。

## 1. 选择安装包

| 平台 | Host（被控端） | Client（控制端） | Server（服务端） |
| --- | --- | --- | --- |
| Windows 10/11 x64 | SindreDeskHost.exe | SindreDeskClient.exe | 不支持 |
| Linux x64 | sindredesk-host | sindredesk-client | SindreDeskServer |
| Android arm64-v8a | SindreDeskHost.apk | SindreDeskClient.apk | 不支持 |

桌面端必须保留完整运行目录，包括 Flutter 数据和动态库，不能只复制 EXE 或可执行文件。Android 两端包名分别为 `com.sindre.desk.host` 和 `com.sindre.desk.client`，可以分别安装在同一部兼容手机上。仅支持 ARM64 Android（包括主流骁龙、天玑及部分 Helio 设备），不保证所有设备兼容。不支持 Android 32 位、Linux ARM64、Windows ARM64、macOS、iOS。

下载入口：[Releases](https://github.com/SindreYang/SindreDesk/releases)；如果 Release 没有附件，从对应版本的 [Actions](https://github.com/SindreYang/SindreDesk/actions) 成功运行页面底部 Artifacts 下载。下载 ZIP 后解压。没有成功产物的平台暂不可下载。

## 2. 工作方式

```text
Host（被控设备） ── 注册/协商 ── 私有 Server ── 协商 ── Client（控制设备）
        └────────────── 加密 P2P 会话 ──────────────────┘
              P2P 不可用时通过自建 hbbr 中继
```

- Host 负责共享画面、提供连接码和临时密码，不发起远程控制。
- Client 输入目标连接码、密码，发起远程控制，不作为被控服务运行。
- Server 包含 hbbs（注册、连接协商）和 hbbr（中继），无需账号系统或公共 RustDesk 服务器。
- 同一局域网可使用服务器协商的 P2P；局域网内自建服务器时无需互联网即可尝试连接。无服务器的直接 IP 模式尚未实现安全握手，当前禁止使用。
- 保留上游远程会话能力，但剪贴板、文件传输、硬件编码、重连等功能仍需逐项实测。

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

局域网部署时，使用服务器局域网 IPv4；跨网络部署时使用双方可访问的公网 IP 或域名，并配置防火墙、云安全组及必要的端口映射。仅开放所需端口。上游可能监听额外 WebSocket 端口，本项目不要求对外开放这些端口。

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

## 4. Android 使用说明

### 4.1 被控端 Host

1. 下载并解压 Host 构建产物，在目标手机安装 SindreDeskHost.apk；如系统提示，按需允许当前安装来源安装应用。
2. 打开 SindreDesk Host，点击右上角服务器设置。
3. 输入 Server 的 IPv4 或域名（不带 http://、https:// 或端口）及公钥，保存。
4. 展开“系统权限”，按页面提示开启所需权限；远程触摸控制通常需要启用本应用的无障碍服务。
5. 启动共享服务，接受 Android 系统屏幕捕获授权；按系统提示允许前台服务相关权限。
6. 读取页面连接码和临时密码，通过可信渠道告知控制者。
7. 不使用时停止屏幕共享，必要时关闭应用及无障碍授权。

Android 不保证锁屏、重启、后台被系统清理后仍能无人值守控制。系统要求再次授权时必须在被控手机上确认。不要尝试绕过系统隐私权限。

### 4.2 控制端 Client

1. 在控制设备安装 SindreDeskClient.apk。
2. 打开 SindreDesk Client，在右上角配置与 Host 相同的服务器地址和公钥。
3. 输入 Host 数字连接码、当前临时密码，点击“连接”。
4. 连接成功后使用远程会话界面操作；完成后退出会话。

两端必须能访问同一私服。仅输入连接码不需要填写目标手机 IP；当前不支持直接输入 IP 发起连接。

### 4.3 ADB 安装（可选）

启用手机 USB 调试并连接电脑后：

```bash
adb devices
adb shell getprop ro.product.cpu.abilist
adb install -r SindreDeskHost.apk
adb install -r SindreDeskClient.apk
```

只需安装对应角色即可。CPU ABI 列表应包含 arm64-v8a。CI APK 使用调试签名，仅供测试；未来正式签名版若不兼容旧签名，可能需要卸载旧版（先备份配置）。

## 5. Windows / Linux 使用说明

解压对应角色的完整运行目录。Windows 双击 SindreDeskHost.exe 或 SindreDeskClient.exe；Linux 进入对应目录执行 `./sindredesk-host` 或 `./sindredesk-client`（必要时先 chmod +x）。按第 4 节相同方式配置服务器、连接码及临时密码。

Windows UAC、锁屏、无人值守服务以及 Linux Wayland 授权、桌面环境兼容性尚待验证；Linux 优先测试 X11。当前未提供正式 MSI、AppImage 或桌面签名安装器。

## 6. 常见问题

| 现象 | 检查方法 |
| --- | --- |
| Host 等待服务器连接 | 确认 Server 运行、地址正确、TCP/UDP 21116 可达 |
| 公钥无效或连接失败 | 确认复制完整的 Base64 公钥，双方使用同一 Server |
| 密码错误 | 使用 Host 当前显示的临时密码，勿使用旧密码 |
| 连接后黑屏 | 检查 Host 屏幕捕获授权及共享服务状态 |
| 能看不能控制 | 检查 Android 无障碍授权或桌面系统控制权限 |
| 跨网络连接失败 | 检查 NAT、防火墙、TCP 21117 中继可达性 |
| APK 无法安装 | 检查 ARM64、系统兼容性、安装来源授权及签名冲突 |
| Release 没有安装包 | 查看该版本 Actions 的构建结论和 Artifacts |

## 7. GitHub Actions 与发布

仓库只保留两个 Workflow：

- `.github/workflows/client-build-verify.yml`：生成共享 Flutter Rust Bridge，构建 Host/Client × Windows/Linux/Android，检查二进制与 APK ABI。
- `.github/workflows/server.yml`：Go race 测试、vet、Linux x64 编译、真实进程集成测试和服务端产物上传。

仅正式发布 GitHub Release（包括已发布的预发行版）时触发；普通 push、PR 更新及合并 main 不触发。草稿 Release 不触发。发布前使用未占用的新 Tag，基于最新 main 提交。失败任务的旧版本重跑不会包含新提交。

| Artifacts 名称 | 内容 |
| --- | --- |
| SindreDesk-host-android-arm64-ci | SindreDeskHost.apk |
| SindreDesk-client-android-arm64-ci | SindreDeskClient.apk |
| SindreDesk-host-windows-x64-ci | Windows Host 完整运行目录 |
| SindreDesk-client-windows-x64-ci | Windows Client 完整运行目录 |
| SindreDesk-host-linux-x64-ci | Linux Host 完整运行目录 |
| SindreDesk-client-linux-x64-ci | Linux Client 完整运行目录 |
| SindreDeskServer-linux-x64-ci | 服务端二进制与 SHA256SUMS |

工作流在客户端六项全部成功后上传客户端 Release 附件；服务端独立通过测试后上传服务端附件。分别提供 SHA256SUMS-clients 和 SHA256SUMS-server。下载前确认对应任务成功，调试签名 APK 仅供测试。未配置正式签名的 0.x 开发版或预发行版 APK 使用调试签名，Release 文件名带 -test；其他稳定版必须使用正式签名。构建检查 APK 签名、角色包名及 arm64-v8a 原生库。

## 8. 开发与验收

固定上游 RustDesk 1.4.9（`6c578292e8ebbbec708b76986ba8c4bc7c509747`），RustDesk Server OSS 1.1.16（`73523b31cfd25d77dee862e6fc9f5e1fb5e485ef`）。CI 使用 Rust 1.75、Flutter 3.24.5（Bridge 3.22.3）、Android NDK r28c 和 JDK 17。

```bash
bash scripts/checkout-upstream.sh
python scripts/prepare-client.py host
python scripts/prepare-client.py client
bash scripts/build-server-release.sh
bash scripts/test-server-integration.sh
```

源码准备脚本要求目标目录不存在；已存在时使用 --output 指定新目录。具体编译参数、依赖和平台环境以现有 Workflow 为准。

- [x] Linux 服务端真实进程、端口监听、密钥持久化、重复实例拦截及退出测试。
- [x] Windows/Linux 两种角色编译（上一轮）。
- [ ] Android 两种角色修复后 APK 编译及真机安装。
- [ ] 九种跨平台控制组合、错误密码/公钥拒绝、局域网及跨网络 P2P/中继。
- [ ] Android 权限、旋转、后台、重连及高通/联发科实机验证。
- [ ] Windows 锁屏/UAC、Linux Wayland、正式签名及发布附件。

详细要求见 [架构与验收](docs/architecture.md)。

## 9. 许可证

上游 [RustDesk](https://github.com/rustdesk/rustdesk) 与 [RustDesk Server](https://github.com/rustdesk/rustdesk-server) 使用 AGPL-3.0。分发二进制须同时满足对应源码、构建脚本、版权及许可证声明义务。

### 服务器连接状态
Host 首页始终显示本机连接码和原生密码状态，不以服务器配置或注册状态作为显示前提。Android 未启动共享时仍显示本机信息和启动共享入口；密码由原生服务提供，未生成时显示占位符。服务器状态单独显示。当前连接码仍需要私服协商，无服务器的安全局域网 IP 直连尚未开放。


两端首页底部显示服务器状态。Host 使用 RustDesk 原生注册状态，Client 使用 TCP 可达性检测；两者均不代表远程会话已认证或中继可用。Android Host 提供当前会话断开和停止共享；桌面 Host 保留原生会话管理窗口。修改服务器配置失败时尝试恢复原配置，恢复失败会明确提示。

完整验收记录模板见 [发布验收](docs/acceptance.md)，第三方来源见 [声明](THIRD_PARTY_NOTICES.md)，版本变更见 [CHANGELOG](CHANGELOG.md)。

### 控制端状态说明

Client 不注册为被控设备，使用 TCP 21116 探测私服可达性，显示服务器可达/不可达/检测中；可达不表示公钥认证成功。Host 继续显示原生注册状态。每 5 秒检测，连接超时 3 秒。

### 正式发布配置

0.x 开发版本及预发行版可以使用临时调试签名（即使 GitHub 未勾选 Pre-release）；其他稳定版必须在仓库 Actions Secrets 配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，并在 Actions Variables 配置 `WINDOWS_ENGINE_SHA256`（可信来源核对的 64 位十六进制 SHA256）。签名配置不完整或引擎校验不一致时构建失败。不要提交证书、密码或私钥。正式签名与调试签名不同，旧测试 APK 可能需要先卸载。签名和哈希配置不是实机验收的替代。

发布前先运行 `python -m unittest discover -s tests -v`。Release 客户端工作流首先检查签名配置和引擎哈希格式，再启动耗时构建，以避免配置缺失导致六个平台重复编译。

0.x 开发版本允许暂缺 Windows Engine 哈希，仅供测试；建议仍勾选 Pre-release。已有但无效或不完整的配置继续拒绝构建。旧 Tag 不会自动包含新代码。

### 电脑被控端系统级开机自启

电脑 Host 采用原生永久密码认证。首次使用点击「生成 6 位连接密码」，保存弹窗中的随机密码后确认；不额外存储明文，重启后无需重新生成。忘记密码可在本机重新生成，旧密码失效。Android 仍使用原有密码流程。

Windows：先配置私服、生成固定密码，再开启系统级自启。便携版会进入原生安装界面，Host 默认使用系统注册表指定的 Program Files 下的 SindreDeskHost 正式安装目录；管理员授权后由原生安装器导入配置并注册 Windows Service。安装完成后重新打开已安装 Host 检查状态。不要从可被普通用户修改的目录注册系统服务。

Linux（systemd 桌面环境）：管理员从可信 Release 解压完整 Host 运行目录，然后将完整目录安装至 /usr/lib/sindredesk-host，并保证目录及文件 root 所有且普通用户不可写；将 Host 发布包中 sindredesk-host.service 安装至 /etc/systemd/system/，执行 sudo systemctl daemon-reload。以普通用户启动 /usr/lib/sindredesk-host/sindredesk-host，配置私服并设置密码，再开启系统级自启。不要以 root 启动 GUI。原生服务同步配置后启用系统服务。关闭开关使用原生停止/卸载服务入口。

注意：为匹配实际进程和服务名称，桌面 Host 的原生应用标识调整为 Windows SindreDeskHost、Linux sindredesk-host。升级时尝试迁移当前系统账户的两份旧 Host 配置；保留旧文件，不覆盖已存在的新配置。迁移失败时保留原配置路径供读取。升级前建议备份，升级后核对连接码及私服配置；实际迁移仍需真机验证。新版本重启后的 ID、密码和配置保持情况需要真实设备验证。Linux X11、Wayland 和登录管理器的登录前控制能力存在差异。六位密码应仅在可信私服和受限网络内使用。

### 桌面首页

Client 默认 440×440、Host 默认 480×540（逻辑像素），采用系统原生标题栏和紧凑首页；保留最小窗口限制和缩放，设置、连接信息与服务器状态集中展示。Android 和远程会话窗口不改变布局。旧首页窗口大小不再恢复。

桌面端使用 SindreDesk 自有蓝色显示器连接图标，覆盖 Windows EXE 内嵌资源、窗口运行时图标与 Linux 窗口图标；共享 Flutter 桌面图标同步更新，保留上游版权和许可证。Android 图标不变。
