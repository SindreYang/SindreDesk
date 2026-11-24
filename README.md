# SindreDesk

基于 RustDesk 的极简、自托管远程桌面。项目处于开发阶段，平台构建和设备连接尚未全部验收。

## 支持范围

| 系统 | Host 被控端 | Client 控制端 | Server |
|---|---:|---:|---:|
| Windows 10/11 x64 | 构建验证中 | 构建验证中 | 不支持 |
| Linux x64 | 构建验证中 | 构建验证中 | 支持 |
| Android arm64-v8a | 构建验证中 | 构建验证中 | 不支持 |

Android 目标设备为主流高通 Snapdragon 与联发科 Dimensity / Helio 64 位机型，使用 Android 标准屏幕采集、无障碍和 MediaCodec 接口。不支持 Android 32 位、Linux ARM64、Windows ARM64、macOS、iOS。

## 连接方式

1. Linux x64 服务端部署在局域网或云服务器。
2. Host 和 Client 分别配置同一服务器 IP / 域名及服务器公钥。
3. Client 输入 Host 的连接码和临时密码。
4. 局域网内优先由 RustDesk P2P 直连；无法直连时由自建 hbbr 中继。

媒体数据在 P2P 成功时不经过中继。当前不开放 RustDesk 原生未认证的直接 IP 连接；离线 IP 直连必须先完成独立的安全握手实现和测试。

## Linux 服务端

服务端仅支持 Linux x86_64，使用 Go 单文件运行器管理固定版本的官方 hbbs / hbbr：

```bash
sha256sum -c SHA256SUMS
chmod +x SindreDeskServer
./SindreDeskServer
```

首次启动自动生成并持久化密钥，控制台输出公钥，不输出私钥。数据默认保存在用户配置目录，也可通过 `SINDREDESK_DATA_DIR` 指定。可通过 `SINDREDESK_RELAY` 指定中继地址。

默认需要 TCP 21115–21117、UDP 21116。请只向可信网络开放必要端口。

服务端自动化集成测试已验证官方 hbbs / hbbr 进程启动、TCP / UDP 监听、密钥持久化、重复实例拦截和正常退出；尚未完成真实客户端会话的端到端验收。

Server CI 集成测试通过后上传 `SindreDeskServer-linux-x64-ci`，包含 `SindreDeskServer` 和 `SHA256SUMS`。下载解压后可按上述命令验证并启动；该产物不是正式发行版。

## GitHub Actions

`.github/workflows/client-build.yml` 负责：
- 生成并共享 Flutter Rust Bridge 文件。
- 分别构建 Host 和 Client。
- Linux x64、Windows x64、Android arm64-v8a 编译。
- 检查各平台可执行文件、Rust FFI 库及 APK ABI。

CI APK 使用调试签名，仅用于安装验证，不是生产签名版本。Linux / Windows 当前上传的是应用运行目录，尚未完成正式 AppImage / 安装包签名和发布流程。

## 本地开发

- `bash scripts/checkout-upstream.sh`：获取固定版本 RustDesk 客户端、服务端源码及子模块。
- `python scripts/prepare-client.py host`：生成 Host 源码工作树。
- `python scripts/prepare-client.py client`：生成 Client 源码工作树。
- `bash scripts/build-server-release.sh`：下载并校验固定版本的 Linux x64 hbbs / hbbr，构建服务端运行器。
- `bash scripts/test-server-integration.sh`：运行服务端真实进程集成测试。

详见 [架构及验收要求](docs/architecture.md)。上游 [RustDesk](https://github.com/rustdesk/rustdesk) 和 [RustDesk Server](https://github.com/rustdesk/rustdesk-server) 使用 AGPL-3.0；分发二进制时必须提供对应源码、构建脚本及许可证声明。
