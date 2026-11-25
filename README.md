# SindreDesk

轻量远程控制工具。无需注册账号，电脑和安卓手机均可使用。

- **Host（被控端）**：安装在需要被控制的设备上。
- **Client（控制端）**：安装在用来操作其他设备的设备上。
- **Server（服务器）**：仅在跨网络使用连接码时需要自行部署。

> 当前为开发测试版。新界面和固定密码尚需跨平台构建与真机验收；请勿将其用于未经验证的生产或无人值守场景。

## 1. 下载并安装

前往 [版本下载](https://github.com/SindreYang/SindreDesk/releases)，选择对应设备和角色。

| 平台 | 被控端 Host | 控制端 Client |
| --- | --- | --- |
| Windows 10/11 x64 | SindreDeskHost-windows-x64.zip | SindreDeskClient-windows-x64.zip |
| Linux x64 | SindreDeskHost-linux-x64.tar.gz | SindreDeskClient-linux-x64.tar.gz |
| Android ARM64 | SindreDeskHost.apk | SindreDeskClient.apk |

- Windows：下载 ZIP，完整解压到一个新目录，再双击 `SindreDeskHost.exe` 或 `SindreDeskClient.exe`。请保留同目录的 DLL 和资源文件，不要只复制 EXE。升级时解压到新目录，避免混用旧文件。
- Linux：解压后运行 `./sindredesk-host` 或 `./sindredesk-client`（必要时先添加执行权限）。
- Android：安装 APK；文件名带 `-test.apk` 表示测试签名，仅供测试。签名不兼容时可能需要先卸载旧版，请先备份配置。

未提供 macOS、iOS、32 位 Android 或 ARM64 桌面版本。若该版本没有对应附件，可查看 [构建记录](https://github.com/SindreYang/SindreDesk/actions)；没有成功构建的包暂不可下载。Windows 提供 ZIP 便携版，不是 MSI 安装器。

## 2. 同一局域网连接（推荐）

两台设备连接同一个可信 Wi-Fi 或有线网络，不需要服务器。

1. 在被控设备打开 **Host**。首页显示本机连接码、固定密码和右下角的局域网 IP。
2. 如果被控设备是 Android，按页面提示开启共享并确认系统屏幕捕获授权；需要远程触摸时开启无障碍权限。
3. 在另一台设备打开 **Client**，从局域网设备列表选择 Host，或输入 Host 右下角的 IP，例如 `192.168.5.10`。
4. 输入 Host 显示的固定密码，点击「连接设备」。
5. 使用结束后退出远程会话；Host 可从连接管理窗口断开，Android 也可停止共享。

首次连接请在可信局域网内操作，连接成功后软件自动记住设备身份，无需额外输入。从旧版升级后会重新建立一次信任。首次连接不能预先确认设备身份，请勿在不可信网络使用局域网直连。如果设备更换或 IP 被分配给另一台设备，确认目标无误后，可在 Client 设置中清除局域网信任记录，再重新连接。

### 局域网兼容模式（测试）

若局域网加密握手失败，可在 Host 和 Client 的右上角设置中分别开启「局域网兼容模式」。之后仍只输入 IP 和固定密码，软件先尝试加密连接，失败后自动尝试一次非加密连接。开关默认关闭，设置后立即生效；该模式仅适用于可信私有 IPv4 局域网，不影响连接码或跨网络连接。非加密会话可能被监听或篡改，测试结束后请关闭。已知设备身份变化或密码错误不会触发降级。

## 3. 不同网络连接

需要一台双方均可访问的自建 Linux x64 服务器，不使用公共服务器。

1. 下载 `SindreDeskServer-linux-x64.tar.gz` 并解压。
2. 在 Linux 服务器运行：

```bash
chmod +x SindreDeskServer
./SindreDeskServer
```

3. 记下启动时显示的服务器公钥，确保服务器 TCP 21115、TCP/UDP 21116、TCP 21117 可达。
4. 在 Host 与 Client 右上角点击设置，填写相同的服务器 IP 或域名、公钥，保存。
5. 在 Client 输入 Host 首页显示的连接码及固定密码，点击「连接设备」。

不再使用跨网络功能时，可在两端设置中同时清空服务器地址和公钥。服务器升级请保留原有数据目录，避免公钥改变。局域网仍可直接使用 IP。

更多服务器安装、开机自启与备份方式见 [服务器及系统服务指南](docs/deployment.md)。

## 4. 固定密码

新设备首次启动时自动生成六位随机固定密码，之后保持不变。点击密码旁的编辑图标可更换，旧密码立即失效。

旧版已设置固定密码的设备可能只显示「已设置」：这是因为旧密码只有验证值、无法恢复显示。点击编辑图标主动更换一次即可。服务尚未就绪时显示「准备中…」，不会因此覆盖旧密码。

请仅将连接码和密码交给可信人员。

## 5. 开机自启与手机权限

- Windows / Linux：在 Host 右上角设置中开启系统级开机自启，按提示完成管理员授权和正式安装。Linux 需先按照 [系统服务指南](docs/deployment.md) 安装。
- Android：系统要求屏幕捕获授权时必须在被控设备确认。锁屏、重启或系统清理后台后可能需要再次授权，不能保证无人值守。

## 6. 常见问题

| 问题 | 处理方法 |
| --- | --- |
| 找不到局域网设备 | 确认双方在同一网络；尝试手动输入 Host 的 IP |
| 显示多个网络地址 | 点击 Host 右下角 IP 查看其他地址 |
| 提示设备已变化 | 确认目标 IP 和设备；确实更换设备时，在设置中清除局域网信任记录 |
| 密码错误 | 核对 Host 当前固定密码；确认是否已被修改 |
| 黑屏或无法控制 | 检查 Host 共享状态、屏幕捕获及无障碍权限 |
| 跨网络连不上 | 确认双方服务器地址和公钥一致、服务器端口可达 |
| Release 没有安装包 | 查看对应版本构建记录；成功产物才能下载 |

局域网直连仅支持私有 IPv4，使用 TCP 32118（连接）和 UDP 32119（发现）。仅在可信局域网开放，不向公网映射 Host 直连端口。

## 7. 连接失败时查看日志

Windows 解压并双击 EXE 后，通常会在 EXE 同级目录生成 `SindreDeskHost.log` 或 `SindreDeskClient.log`。如果目录不可写，会退回到应用日志目录。系统服务可能由不同账户运行，其日志位于安装目录或服务账户的应用日志目录。

连接失败时，将两端日志中对应时间的内容发给维护人员。日志记录程序启动、端口监听、连接阶段、身份验证和登录结果，不记录密码、私钥或协议消息正文。日志包含局域网地址，请注意保护隐私。

新版使用独立端口，Host 和 Client 必须一起更新；原版 RustDesk 不必停止。若显示「局域网端口不可用」，请检查是否有其他程序占用 TCP 32118，并重新启动 Host。

## 8. 其他资料

[版本变更](CHANGELOG.md) · [部署指南](docs/deployment.md) · [开发与发布](docs/development.md) · [架构](docs/architecture.md) · [验收记录](docs/acceptance.md)

本项目基于 [RustDesk](https://github.com/rustdesk/rustdesk) 和 [RustDesk Server](https://github.com/rustdesk/rustdesk-server)，遵循 AGPL-3.0，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。
