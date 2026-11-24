import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../common.dart';
import '../models/platform_model.dart';
import '../models/server_model.dart' show kUseTemporaryPassword;
import '../mobile/pages/server_page.dart' as mobile;

bool validPublicKey(String value) {
  try {
    return base64Decode(value.trim()).length == 32;
  } catch (_) {
    return false;
  }
}

bool validServer(String value) {
  final host = value.trim();
  // V1 私服采用标准端口，IPv4 / DNS；暂不接受 URL、其他服务器或端口。
  return host.isNotEmpty &&
      host.length <= 253 &&
      RegExp(r'^[a-zA-Z0-9]+(?:[.-][a-zA-Z0-9]+)*$').hasMatch(host) &&
      !RegExp(r'(^|\.)rustdesk\.com$', caseSensitive: false).hasMatch(host);
}

class SindreHome extends StatefulWidget {
  const SindreHome({super.key});

  @override
  State<SindreHome> createState() => _SindreHomeState();
}

class _SindreHomeState extends State<SindreHome> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  Timer? _timer;
  bool _busy = false;
  String _message = '';

  bool get host => bind.isIncomingOnly();
  bool get configured =>
      validServer(bind.mainGetOptionSync(key: 'custom-rendezvous-server')) &&
      validPublicKey(bind.mainGetOptionSync(key: 'key'));

  @override
  void initState() {
    super.initState();
    if (host) {
      // 使用密码自动验证，避免弹出额外的人工接听窗口。
      unawaited(gFFI.serverModel.setApproveMode('password'));
      unawaited(gFFI.serverModel.setVerificationMethod(kUseTemporaryPassword));
    }
    if (host && isDesktop) {
      gFFI.serverModel.fetchID();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) {
        gFFI.serverModel.fetchID();
      });
    }
  }


  @override
  void dispose() {
    _timer?.cancel();
    _id.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _settings() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _ServerSettings(),
    );
    if (saved == true && mounted) setState(() => _message = '');
  }

  Future<void> _connect() async {
    if (_busy) return;
    final id = _id.text.replaceAll(' ', '').trim();
    final password = _password.text;
    if (!configured) {
      setState(() => _message = '请先配置服务器地址和公钥');
      return;
    }
    // 只开放连接码；安全离线局域网协议尚未完成。
    if (!RegExp(r'^[0-9]+$').hasMatch(id) || password.isEmpty) {
      setState(() => _message = '请输入连接码和密码');
      return;
    }
    setState(() { _busy = true; _message = ''; });
    _password.clear();
    try {
      await connect(context, id, password: password);
    } catch (_) {
      if (mounted) setState(() => _message = '无法发起连接，请检查配置');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _value(String title, String value, {VoidCallback? refresh}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.labelLarge),
      Row(children: [
        Expanded(child: SelectableText(value,
          style: Theme.of(context).textTheme.headlineSmall)),
        IconButton(
          tooltip: '复制',
          onPressed: () => Clipboard.setData(ClipboardData(text: value)),
          icon: const Icon(Icons.copy_outlined),
        ),
        if (refresh != null)
          IconButton(tooltip: '刷新密码', onPressed: refresh,
            icon: const Icon(Icons.refresh)),
      ]),
      const SizedBox(height: 12),
    ]);
  }

  Widget _hostDesktop() {
    final model = gFFI.serverModel;
    return AnimatedBuilder(
      animation: model,
      builder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _value('本机连接码', model.serverId.text),
          _value('连接密码', model.serverPasswd.text,
            refresh: () => bind.mainUpdateTemporaryPassword()),
          Text(!configured ? '请配置服务器' :
            model.connectStatus > 0 ? '服务已连接' : '等待服务器连接'),
        ],
      ),
    );
  }

  Widget _client() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(controller: _id,
        decoration: const InputDecoration(labelText: '连接码', border: OutlineInputBorder()),
        keyboardType: TextInputType.number),
      const SizedBox(height: 16),
      TextField(controller: _password, obscureText: true,
        autocorrect: false, enableSuggestions: false,
        decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
        onSubmitted: (_) => _connect()),
      const SizedBox(height: 16),
      FilledButton(onPressed: _busy ? null : _connect, child: const Text('连接')),
      if (_message.isNotEmpty) Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(_message, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ],
  );

  @override
  Widget build(BuildContext context) {
    // Android 被控复用原生权限检查、共享授权和会话断开组件。
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(host ? 'SindreDesk Host' : 'SindreDesk Client'),
        actions: [
          IconButton(tooltip: '服务器设置', icon: const Icon(Icons.settings_outlined),
            onPressed: _settings),
        ],
      ),
      body: host && isAndroid
          ? configured
              ? const _AndroidHostPanel()
              : const Center(child: Text('请先配置服务器地址和公钥'))
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: host ? _hostDesktop() : _client(),
                ),
              ),
            ),
    );
  }
}

class _AndroidHostPanel extends StatefulWidget {
  const _AndroidHostPanel();

  @override
  State<_AndroidHostPanel> createState() => _AndroidHostPanelState();
}

class _AndroidHostPanelState extends State<_AndroidHostPanel> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    gFFI.serverModel.checkAndroidPermission();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      gFFI.serverModel.fetchID();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    mobile.checkService();
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: SingleChildScrollView(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: gFFI.serverModel,
              builder: (_, __) => gFFI.serverModel.isStart
                  ? mobile.ServerInfo()
                  : mobile.ServiceNotRunningNotification(),
            ),
            ExpansionTile(
              title: const Text('系统权限'),
              children: const [mobile.PermissionChecker()],
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerSettings extends StatefulWidget {
  const _ServerSettings();

  @override
  State<_ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<_ServerSettings> {
  final _server = TextEditingController(
    text: bind.mainGetOptionSync(key: 'custom-rendezvous-server'));
  final _key = TextEditingController(text: bind.mainGetOptionSync(key: 'key'));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final server = _server.text.trim();
    final key = _key.text.trim();
    if (!validServer(server) || !validPublicKey(key)) {
      setState(() => _error = '请输入有效的服务器 IPv4 / 域名及 32 字节 Base64 公钥');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      // 先清空旧公钥，切换地址期间禁止新连接。
      await bind.mainSetOption(key: 'key', value: '');
      final ok = await setServerConfig(null, null,
        ServerConfig(idServer: server, key: key));
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = '保存失败');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('服务器设置'),
    content: SizedBox(width: 380, child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(controller: _server,
          decoration: const InputDecoration(labelText: '服务器 IP / 域名')),
        const SizedBox(height: 12),
        TextField(controller: _key, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: '服务器公钥')),
        if (_error != null) Padding(
          padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
      ],
    )),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('取消')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
    ],
  );
}
