# SindreDeskLite（开发分支）
独立 Android 老年版的服务端第一阶段。原版文件与发布工作流不变。

## 编译及安装
复用原版固定上游版本的 hbbs/hbbr Linux x64 构建产物：
```bash
bash lite/build-server.sh /path/to/hbbs /path/to/hbbr
sudo ./dist/SindreDeskLiteServer-linux-x64 install
sudo systemctl status sindredesk-lite
sudo journalctl -u sindredesk-lite -n 50
sudo ./dist/SindreDeskLiteServer-linux-x64 info
```
构建需要 Go 1.23、C 编译器、静态 C 库；部署不需要 Go 或独立数据库。默认公网配置 43.138.240.23，默认 TCP 22115–22117、UDP 22116、HTTPS TCP 22120。上游 hbbs/hbbr 同时使用 22118/22119 WebSocket 监听，不将它们用于设备码 API，无需对外开放。不同公网 IP 需设置 SINDREDESK_RELAY（含端口）及 SINDREDESK_PUBLIC_IP 后重新建立可信 TLS 配置。

首次启动生成 RustDesk 公钥及设备 API TLS 证书。`info` 一次输出 JSON：证书 SAN 中的配置 IP、ID 服务地址、默认中继地址、HTTPS URL、RustDesk 公钥、公开 TLS 证书及 DER SHA256 指纹。它不探测公网 IP，不显示任何私钥；若使用自定义中继环境变量，应以实际服务配置为准。仍可单独使用 `key` 和 `cert`。APP 必须预置可信 RustDesk 公钥和 API 证书/信任锚，不得关闭证书验证。当前自签证书与 IP 绑定，迁移需规划证书轮换，不能只改 IP。

## API
- GET /health：数据库与本机远控端口就绪（非端到端验证）。
- POST /v1/register：Bearer 32 字节随机设备令牌（64 hex），JSON {"rustdesk_id":"..."}。返回固定四位 code 与 rustdesk_id。客户端需要安全持久化令牌及 RustDesk 身份。
- POST /v1/lookup：已注册令牌，JSON {"code":"0028"}。只返回路由 ID，不是远控授权。限流且必须通过被控端原生会话确认。
- 设备令牌绑定尚不构成 RustDesk ID 所有权证明，公开部署之前必须完成设备身份绑定及防滥用验收。禁止静默远控、密码自动填充或信任任意发现的服务器。
- last_seen 是注册接口最后成功访问时间，不是实时在线状态。

## 迁移
停止服务后备份程序同级的整个 SindreDeskLiteData/（含 SQLite WAL/SHM、RustDesk 数据、密钥及 API TLS 证书），安全复制到新服务器，恢复数据目录和权限后启动。不要泄露私钥或设备令牌。安装命令拒绝覆盖现有服务；升级、恢复命令待实现。若已有旧版 /var/lib/sindredesk-lite，须停服后手动迁移，不能同时启动两个实例。

## 状态
已增加 Android 双向控制候选 UI、设备码 API 客户端和上游补丁生成脚本；Linux 与 Android 编译链已通过 CI，仍需真实设备验收。设备身份绑定、权限引导、原生本地强制断开及签名配置热更新仍需完善；不提供正式发布 APK，也不允许以 4 位码作为唯一认证。正式发布前必须真机验收及安全审查。

## Android 候选源码
```bash
python lite/prepare-android.py
```
构建读取 `lite/android/server.json`（服务端 info 输出中的公开 IP、公钥、证书和指纹），先校验 IP 和证书指纹，不需要手工拆分密钥文件。禁止写入任何私钥。生成 `lite/upstream`，独立包名 `com.sindre.desk.lite`。当前实现首页两个 Tab、四位固定码、受信 TLS 健康检查、右下角在线状态、原生连接和停止共享调用。保留 Android 系统授权及原生点击确认。候选源码需要按原版 Android ARM64 编译链构建并验证，尚不能发布；特别需验证服务启动前 RustDesk key 配置、ID 所有权、授权弹窗、后台强制结束入口与远程输入竞态。

## CI 开发验证
现有 Server CI 工作流为 Lite PR 增加两个独立验证任务：Linux x64 编译、真实进程集成及 systemd 安装；Android ARM64 上游补丁、静态分析及 APK 编译。Linux 单文件与连接已配置服务器的 Android ARM64 测试 APK 作为短期 artifact 上传（GitHub artifact 下载本身会带 ZIP 外壳）。不发布正式 Release；APK 使用 CI 调试签名，只允许在本人或明确授权设备上进行测试，不视为生产可用。原版 release 任务只在 release 时运行。通过 CI 不代表完成真机或安全验收。

## 便携部署
程序无须安装即可前台运行，数据目录固定为程序实际路径同级 `SindreDeskLiteData/`，与启动时的工作目录无关。systemd 安装直接使用程序绝对路径，不复制程序。普通用户持有的程序以该用户运行；root 持有的程序使用专用非 root 服务账户，因此不得放在该账户无法访问的 /root 等目录。已有数据目录权限须为 0700，且属于服务账户；安装不会自动覆盖或递归修改旧数据。移动程序前须停服并重新注册 unit。

CI 缓存 Go、固定上游服务端压缩包（每次校验 SHA256）、Rust 编译工具/依赖、Flutter/Pub、Gradle、vcpkg 下载与二进制。仅当同一 PR 的历史成功任务输入完全一致时跳过该任务；无法检查时重新验证。手动 workflow_dispatch 可选 server/android/both。Release 产物复用尚未实现，当前不发布正式 APK。
