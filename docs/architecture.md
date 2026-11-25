# V1 架构与验收

## 固定上游

- 客户端 RustDesk 1.4.9：6c578292e8ebbbec708b76986ba8c4bc7c509747
- 服务端 RustDesk Server OSS 1.1.16：73523b31cfd25d77dee862e6fc9f5e1fb5e485ef

## 产品

Host：首页仅显示本机连接码、临时密码、服务器连接状态和配置入口。可停止共享、断开会话。禁止发起连接。

Client：首页仅显示对方数字连接码、密码、连接按钮和配置入口。禁止启动被控服务。连接后保留远程画面、触摸/鼠标键盘、显示器切换、剪贴板与可选文件传输。

两端配置：服务器 IP/域名、公钥。缺少任一字段时禁止连接码模式，且不使用公共服务器。局域网模式必须经认证和加密；上游直接 IP 模式不应被视为安全实现。先验证服务器协商的 LAN P2P；离线 LAN 模式强制签名和加密，首次成功登录后固定设备公钥；首次连接不具备预先认证，限可信局域网使用。仍需实机验证及安全审查。

Server：Linux amd64 单文件运行器，内嵌 hbbs/hbbr，从持久目录启动，严格要求服务端密钥校验，同一目录只允许一个实例，任一子进程退出时停止另一进程；不替代上游协议。启动前检查 TCP/UDP 端口占用；提供可选 systemd 服务单元和状态查询；完整协议就绪探测仍待实现。公钥通过可信渠道交给使用者。

## 平台

Windows x64：普通用户启动；锁屏、UAC、无人值守模式需单独测试系统服务。
Linux x64：优先 X11；Wayland 遵守门户/桌面权限，按支持情况明确限制。
Android arm64-v8a：独立 applicationId；高通和联发科实机验证，遵循 MediaProjection、无障碍、前台服务授权；不得宣称无人值守必然可用。

## 发布目标（尚未产出）

SindreDeskHost.exe、SindreDeskClient.exe、SindreDeskHost.AppImage、SindreDeskClient.AppImage、SindreDeskHost.apk、SindreDeskClient.apk、SindreDeskServer。

## 验收清单

- [ ] 角色隔离：Host 不发起连接，Client 不监听被控服务；检查 UI 以外入口。
- [ ] 不配置私服时不访问 RustDesk 公共服务器。
- [ ] 正确公钥与密码连接成功；错误公钥、密码拒绝；限速和暴力破解防护。
- [ ] Windows / Linux / Android 各作为 Host 和 Client 的九种组合。
- [ ] 局域网无互联网与服务端不可用时的安全 IP 直连；抓包验证无明文会话。
- [ ] 跨网络 P2P、中继、断线重连。
- [ ] Android 授权、旋转、前后台、硬件编解码与回退，骁龙/联发科实机。
- [ ] Windows 锁屏/UAC、Linux X11/Wayland。
- [ ] Linux 服务端实际双进程启动、端口、公钥持久化、退出和重启、错误恢复。
- [ ] 许可证、对应源码与可重复构建。
