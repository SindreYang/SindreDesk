# SindreDeskLite（开发分支）
独立 Android 老年版的服务端第一阶段。原版文件与发布工作流不变。

## 编译及安装
复用原版固定上游版本的 hbbs/hbbr Linux x64 构建产物：
```bash
bash lite/build-server.sh /path/to/hbbs /path/to/hbbr
sudo ./dist/SindreDeskLiteServer install
sudo systemctl status sindredesk-lite
sudo journalctl -u sindredesk-lite -n 50
sudo env SINDREDESK_DATA_DIR=/var/lib/sindredesk-lite /usr/local/bin/SindreDeskLiteServer key
sudo env SINDREDESK_DATA_DIR=/var/lib/sindredesk-lite /usr/local/bin/SindreDeskLiteServer cert
```
构建需要 Go 1.23、C 编译器、静态 C 库；部署不需要 Go 或独立数据库。服务固定 43.138.240.23，默认 TCP 22115–22117、UDP 22116、HTTPS TCP 22120。上游 hbbs/hbbr 同时使用 22118/22119 WebSocket 监听，不将它们用于设备码 API，无需对外开放。不同公网 IP 需设置 SINDREDESK_RELAY（含端口）及 SINDREDESK_PUBLIC_IP 后重新建立可信 TLS 配置。

首次启动生成 RustDesk 公钥及设备 API TLS 证书。APP 必须预置可信 RustDesk 公钥和 API 证书/信任锚，不得关闭证书验证。当前自签证书与 IP 绑定，迁移需规划证书轮换，不能只改 IP。

## API
- GET /health：数据库与本机远控端口就绪（非端到端验证）。
- POST /v1/register：Bearer 32 字节随机设备令牌（64 hex），JSON {"rustdesk_id":"..."}。返回固定四位 code 与 rustdesk_id。客户端需要安全持久化令牌及 RustDesk 身份。
- POST /v1/lookup：已注册令牌，JSON {"code":"0028"}。只返回路由 ID，不是远控授权。限流且必须通过被控端原生会话确认。
- 设备令牌绑定尚不构成 RustDesk ID 所有权证明，公开部署之前必须完成设备身份绑定及防滥用验收。禁止静默远控、密码自动填充或信任任意发现的服务器。
- last_seen 是注册接口最后成功访问时间，不是实时在线状态。

## 迁移
停止服务后备份整个 /var/lib/sindredesk-lite（含 SQLite WAL/SHM、RustDesk 数据、密钥及 API TLS 证书），安全复制到新服务器，恢复数据目录和权限后启动。不要泄露私钥或设备令牌。安装命令拒绝覆盖现有服务；升级、恢复命令待实现。

## 状态
此提交仅实现服务端初版及测试源码，尚未构建验收或部署。Android 一体化、设备身份绑定、权限引导、本地强制断开及签名配置热更新仍待实现；不提供可用 APK，也不允许以 4 位码作为唯一认证。正式发布前必须真机验收及安全审查。
