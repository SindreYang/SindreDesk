# Host / Client 源码集成

`python scripts/prepare-client.py host` 与 `python scripts/prepare-client.py client` 分别从固定 RustDesk 提交生成源码工作树，使用编译期角色约束并接入极简 Flutter 首页。Android 应用 ID 独立，限制 arm64-v8a。

该阶段仅为源码集成，不是正式安装包。Android Host 保留原生共享权限和会话授权组件；Desktop Host 复用临时及固定密码；Client 通过连接码和密码调用原生连接入口。暂时禁用上游直接 IP 模式、其他服务器语法和非加密会话。服务器协商的局域网 P2P 与跨网络连接仍需真实验证。安全离线 IP 直连、桌面打包标识、Android 原生角色权限审计、所有平台编译及端到端测试仍未完成。不得发布未经验证的二进制。

源码保留 RustDesk 原有 AGPL-3.0 声明；提供对应的上游源码与本仓库补丁脚本。
