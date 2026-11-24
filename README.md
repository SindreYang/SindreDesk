# SindreDesk

极简、自托管的跨平台远程桌面。当前为开发阶段，不提供已验证的客户端安装包。

| 平台 | Host | Client | Server |
|---|---|---|---|
| Windows x64 | 计划 | 计划 | 不支持 |
| Linux x64 | 计划 | 计划 | 运行器初版 |
| Android arm64-v8a | 计划 | 计划 | 不支持 |

Android 优先验证高通骁龙、联发科天玑/Helio 64 位设备。不支持 32 位、Linux ARM64、iOS、macOS。

## 开发

- `bash scripts/checkout-upstream.sh`：获取固定版本客户端、服务端源码及其子模块。
- Linux x64：`cd server && go test ./...` 检查运行器。
- 使用从固定版本 RustDesk Server 源码构建的 Linux amd64 hbbs、hbbr：`bash scripts/build-server.sh /absolute/path/hbbs /absolute/path/hbbr`。
- 运行 `./dist/SindreDeskServer`，首次启动由 hbbs 生成密钥，数据默认保存在当前用户的配置目录。输出公钥，不输出私钥。
- 如需指定中继地址，设置 `SINDREDESK_RELAY=remote.example.com:21117`。
- 服务端需要 TCP 21115–21117、UDP 21116。上游可能同时监听 WebSocket 端口；不需要网页客户端时不要对外开放这些端口。

运行器当前未进行真实 hbbs/hbbr 集成测试；不得作为已通过安全验收的正式发布。客户端尚未修改上游界面和权限。

详见 [架构及验收要求](docs/architecture.md)。上游 [RustDesk](https://github.com/rustdesk/rustdesk) 与 [RustDesk Server](https://github.com/rustdesk/rustdesk-server) 使用 AGPL-3.0；发布时必须同时满足源码提供和版权声明义务。
