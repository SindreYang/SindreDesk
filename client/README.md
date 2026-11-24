# Host / Client 源码集成

使用固定上游版本和 scripts/prepare-client.py 生成独立角色源码。Android 包名独立且仅 ARM64；桌面保留原生连接管理窗口。两端首页显示原生服务器状态，Android Host 支持断开会话和停止共享。私服地址及公钥必须配置，禁止不安全的直接 IP 模式。构建通过不等于真机连接通过；九种跨平台会话、安全协议和原生入口仍需实测。详见根目录 README。
