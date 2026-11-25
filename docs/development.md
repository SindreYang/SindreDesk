# 开发与发布

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
- [ ] 九种跨平台控制组合、错误密码/公钥拒绝、无服务器局域网直连（含已信任设备身份变化拒绝）、局域网及跨网络 P2P/中继。
- [ ] Android 权限、旋转、后台、重连及高通/联发科实机验证。
- [ ] Windows 锁屏/UAC、Linux Wayland、正式签名及发布附件。

详细要求见 [架构与验收](docs/architecture.md)。


### 正式发布配置

0.x 开发版本及预发行版可以使用临时调试签名（即使 GitHub 未勾选 Pre-release）；其他稳定版必须在仓库 Actions Secrets 配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_STORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，并在 Actions Variables 配置 `WINDOWS_ENGINE_SHA256`（可信来源核对的 64 位十六进制 SHA256）。签名配置不完整或引擎校验不一致时构建失败。不要提交证书、密码或私钥。正式签名与调试签名不同，旧测试 APK 可能需要先卸载。签名和哈希配置不是实机验收的替代。

发布前先运行 `python -m unittest discover -s tests -v`。Release 客户端工作流首先检查签名配置和引擎哈希格式，再启动耗时构建，以避免配置缺失导致六个平台重复编译。

0.x 开发版本允许暂缺 Windows Engine 哈希，仅供测试；建议仍勾选 Pre-release。已有但无效或不完整的配置继续拒绝构建。旧 Tag 不会自动包含新代码。


## 密码显示缓存

仅 Host 的本机配置保存以本机私有签名密钥派生密钥、随机 nonce 的 Secretbox 认证加密保存的可恢复密码，服务认证继续使用原生加盐验证值。每次显示前核对原生验证值，旧密码不可逆时不自动覆盖。本地加密并非系统凭据保险库，无法防御已控制本机并读取私有配置的攻击者；需在可信设备上使用。不得记录密码或明文存储。

## Windows 便携版与诊断

Windows 保留原有 ZIP 发布方式，包含完整 EXE、DLL 和 Flutter 运行资源；不使用自解包启动器。系统级安装继续使用原生安装入口。

局域网 TCP 32118、UDP 32119 独立于原版 RustDesk；服务器端口不变。诊断文件按角色记录固定事件、时间、进程号、端口和连接地址，单文件约 5 MiB 轮换。不会写入密码、私钥、指纹或协议正文。

局域网首次连接采用 TOFU（首次成功登录后固定设备公钥），无需人工核对。首次连接无法预先认证设备公钥，不能抵御首次连接中的主动中间人攻击。广播不作为信任来源，后续连接在密码认证前检查已保存公钥，禁止自动覆盖；仅当用户确认设备更换并主动清除信任记录时重新建立信任。
