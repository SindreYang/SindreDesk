import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'desktop_autostart.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../common.dart';
import '../models/platform_model.dart';
import '../models/server_model.dart' show kUseTemporaryPassword, kUsePermanentPassword;
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
  final parts = host.split('.');
  if (host.isEmpty || host.length > 253 ||
      !parts.every((p) => p.length <= 63 &&
          RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$').hasMatch(p))) {
    return false;
  }
  if (RegExp(r'^[0-9.]+$').hasMatch(host) &&
      (parts.length != 4 || parts.any((p) => (int.tryParse(p) ?? 256) > 255))) {
    return false;
  }
  return !RegExp(r'(^|\.)rustdesk\.com$', caseSensitive: false).hasMatch(host);
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
  bool _showPassword = false;
  String _message = '';
  bool? _reachable;
  int _probeGeneration = 0;
  bool _probing = false;

  bool get host => bind.isIncomingOnly();
  bool get configured =>
      validServer(bind.mainGetOptionSync(key: 'custom-rendezvous-server')) &&
      validPublicKey(bind.mainGetOptionSync(key: 'key'));

  @override
  void initState() {
    super.initState();
    if (host) {
      // 保留原生连接管理窗口，确保桌面被控者可断开会话。
      gFFI.serverModel.hideCm = false;
      unawaited(gFFI.serverModel.setApproveMode('password'));
      unawaited(gFFI.serverModel.setVerificationMethod(
          DesktopAutostart.supported ? kUsePermanentPassword : kUseTemporaryPassword));
    }
    if (!host) {
      unawaited(_probeServer());
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        unawaited(_probeServer());
      });
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

  // 控制端不注册为被控设备；仅探测私服 TCP 可达性。
  Future<void> _probeServer() async {
    if (_probing || !mounted || host) return;
    if (!configured) {
      if (_reachable != null) setState(() => _reachable = null);
      return;
    }
    final address = bind.mainGetOptionSync(key: 'custom-rendezvous-server').trim();
    final generation = _probeGeneration;
    _probing = true;
    bool reachable = false;
    Socket? socket;
    try {
      socket = await Socket.connect(address, 21116,
          timeout: const Duration(seconds: 3));
      reachable = true;
    } catch (_) {
      reachable = false;
    } finally {
      socket?.destroy();
      _probing = false;
      if (mounted && generation == _probeGeneration &&
          address == bind.mainGetOptionSync(key: 'custom-rendezvous-server').trim()) {
        setState(() => _reachable = reachable);
      }
    }
  }

  Future<void> _settings() async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ServerSettings(),
    );
    if (mounted) {
      _probeGeneration++;
      setState(() {
        _reachable = null;
        if (saved == true) _message = '';
      });
      if (!host) unawaited(_probeServer());
    }
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

  Widget _serverStatus({bool compact = false}) => AnimatedBuilder(
    animation: gFFI.serverModel,
    builder: (context, _) {
      final status = gFFI.serverModel.connectStatus;
      final ready = configured && (host ? status > 0 : _reachable == true);
      final failed = host ? status < 0 : _reachable == false;
      final label = !configured ? '未配置服务器' :
          ready ? (host ? '服务器已连接' : '服务器可达') :
          failed ? (host ? '服务器未就绪' : '服务器不可达') :
          host ? '正在连接服务器' : '正在检测服务器';
      final color = ready ? Colors.green :
          !configured ? Theme.of(context).colorScheme.outline :
          failed ? Theme.of(context).colorScheme.error : Colors.orange;
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 20, vertical: compact ? 6 : 10),
        child: Row(children: [
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
        ]),
      );
    },
  );

  Widget _hostDesktop() {
    final model = gFFI.serverModel;
    return AnimatedBuilder(
      animation: model,
      builder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _value('本机连接码', model.serverId.text),
          if (DesktopAutostart.supported)
            const _FixedPasswordPanel()
          else
            _value('连接密码', model.serverPasswd.text,
              refresh: () => bind.mainUpdateTemporaryPassword()),
          const Text('远程会话可在连接管理窗口中断开。'),
          if (DesktopAutostart.supported) const _DesktopAutostartSwitch(),
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

  Widget _desktopClient() {
    final colors = Theme.of(context).colorScheme;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(8));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('连接码', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextField(
          controller: _id,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '输入对方设备连接码',
            isDense: true,
            prefixIcon: const Icon(Icons.computer_outlined, size: 20),
            border: border,
          ),
        ),
        const SizedBox(height: 14),
        Text('连接密码', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextField(
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _connect(),
          decoration: InputDecoration(
            hintText: '输入对方设备密码',
            isDense: true,
            prefixIcon: const Icon(Icons.lock_outline, size: 20),
            suffixIcon: IconButton(
              tooltip: _showPassword ? '隐藏密码' : '显示密码',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20),
            ),
            border: border,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1769D2),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(42),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: _busy ? null : _connect,
          child: Text(_busy ? '连接中…' : '连接'),
        ),
        if (_message.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 10),
            child: Text(_message, style: TextStyle(color: colors.error))),
      ],
    );
  }

  Widget _desktopHome(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = theme.brightness == Brightness.dark
        ? const Color(0xFF17191D) : const Color(0xFFF4F6F9);
    final surface = theme.brightness == Brightness.dark
        ? const Color(0xFF21242A) : Colors.white;
    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(host ? '本机设备' : '远程连接',
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(host ? '允许其他设备连接本机' : '输入被控设备的连接信息',
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                      ],
                    )),
                    IconButton(
                      tooltip: '服务器设置',
                      onPressed: _settings,
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: host ? _hostDesktop() : _desktopClient(),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(child: _serverStatus(compact: true)),
                    if (!configured)
                      TextButton(onPressed: _settings, child: const Text('配置服务器')),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktop) return _desktopHome(context);
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
      bottomNavigationBar: SafeArea(child: _serverStatus()),
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
    mobile.checkService();
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
            AnimatedBuilder(
              animation: gFFI.serverModel,
              builder: (_, __) => Column(children: [
                for (final client in gFFI.serverModel.clients.where(
                    (c) => !c.disconnected))
                  ListTile(
                    title: Text('会话 ${client.peerId}'),
                    trailing: TextButton(
                      onPressed: () => bind.cmCloseConnection(connId: client.id),
                      child: const Text('断开连接'),
                    ),
                  ),
                if (gFFI.serverModel.isStart)
                  OutlinedButton(
                    onPressed: () => gFFI.serverModel.stopService(),
                    child: const Text('停止共享'),
                  ),
              ]),
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
    final oldServer = bind.mainGetOptionSync(key: 'custom-rendezvous-server');
    final oldKey = bind.mainGetOptionSync(key: 'key');
    final oldRelay = bind.mainGetOptionSync(key: 'relay-server');
    final oldApi = bind.mainGetOptionSync(key: 'api-server');
    Future<void> restore() async {
      await bind.mainSetOption(key: 'key', value: '');
      await bind.mainSetOption(key: 'custom-rendezvous-server', value: oldServer);
      await bind.mainSetOption(key: 'relay-server', value: oldRelay);
      await bind.mainSetOption(key: 'api-server', value: oldApi);
      await bind.mainSetOption(key: 'key', value: oldKey);
      if (bind.mainGetOptionSync(key: 'custom-rendezvous-server') != oldServer ||
          bind.mainGetOptionSync(key: 'key') != oldKey ||
          bind.mainGetOptionSync(key: 'relay-server') != oldRelay ||
          bind.mainGetOptionSync(key: 'api-server') != oldApi) {
        throw StateError('恢复配置未生效');
      }
    }
    try {
      // 先清空旧公钥，切换地址期间禁止新连接。
      await bind.mainSetOption(key: 'key', value: '');
      final ok = await setServerConfig(null, null,
        ServerConfig(idServer: server, key: key));
      if (!ok || bind.mainGetOptionSync(key: 'custom-rendezvous-server') != server ||
          bind.mainGetOptionSync(key: 'key') != key) {
        throw StateError('配置未完整保存');
      }
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _error = '保存失败');
      }
    } catch (_) {
      try {
        await restore();
        if (mounted) setState(() => _error = '保存失败，已恢复原配置');
      } catch (_) {
        if (mounted) setState(() => _error = '保存及恢复失败，请重新配置');
      }
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


/// 原生永久密码只保存验证数据，不在 Flutter 中另存明文。
class _FixedPasswordPanel extends StatefulWidget {
  const _FixedPasswordPanel();

  @override
  State<_FixedPasswordPanel> createState() => _FixedPasswordPanelState();
}

class _FixedPasswordPanelState extends State<_FixedPasswordPanel> {
  bool _busy = false;
  bool? _ready;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
  }

  Future<void> _read() async {
    try {
      final ready = await bind.mainGetCommon(key: 'permanent-password-set') == 'true';
      if (mounted) setState(() => _ready = ready);
    } catch (_) {
      if (mounted) setState(() => _ready = null);
    }
  }

  Future<void> _generate() async {
    if (_busy || !bind.isIncomingOnly()) return;
    setState(() => _busy = true);
    try {
      final random = Random.secure();
      const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
      final password = List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
      if (!mounted) return;
      final confirm = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: Text(_ready == true ? '重新生成连接密码' : '设置连接密码'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('固定密码仅在此处显示，请先保存。确认后旧密码失效。'),
            SelectableText(password, style: Theme.of(context).textTheme.headlineSmall),
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: password)),
              child: const Text('复制密码')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认设置')),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
      final ok = await bind.mainSetPermanentPasswordWithResult(password: password);
      if (!ok) throw StateError('Password update failed');
      await gFFI.serverModel.setVerificationMethod(kUsePermanentPassword);
      if (bind.mainGetOptionSync(key: 'verification-method') != kUsePermanentPassword) {
        throw StateError('Permanent verification mode unavailable');
      }
      await _read();
      if (mounted && _ready != true) throw StateError('Password state unavailable');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('密码设置未确认，请检查被控服务状态')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(_ready == true ? '固定连接密码已设置' :
          _ready == false ? '尚未设置固定连接密码' : '密码状态待确认'),
      TextButton(onPressed: _busy ? null : _generate,
        child: Text(_ready == true ? '重新生成 6 位密码' : '生成 6 位连接密码')),
      const SizedBox(height: 8),
    ],
  );
}

class _DesktopAutostartSwitch extends StatefulWidget {
  const _DesktopAutostartSwitch();

  @override
  State<_DesktopAutostartSwitch> createState() => _DesktopAutostartSwitchState();
}

class _DesktopAutostartSwitchState extends State<_DesktopAutostartSwitch> {
  bool? _enabled;
  bool _busy = false;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_busy) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final enabled = await DesktopAutostart.enabled();
      if (mounted) setState(() => _enabled = enabled);
    } catch (_) {
      if (mounted) setState(() => _enabled = null);
    }
  }

  Future<void> _change(bool value) async {
    if (_busy || !bind.isIncomingOnly()) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (value) {
        if (bind.mainGetOptionSync(key: 'verification-method') != kUsePermanentPassword ||
            !validServer(bind.mainGetOptionSync(key: 'custom-rendezvous-server')) ||
            !validPublicKey(bind.mainGetOptionSync(key: 'key')) ||
            await bind.mainGetCommon(key: 'permanent-password-set') != 'true') {
          if (mounted) setState(() => _error = '请先配置私服和固定连接密码');
          return;
        }
        final installed = Platform.isWindows
            ? await bind.mainGetCommon(key: 'sindre-installed-host') == 'true'
            : Platform.resolvedExecutable == '/usr/lib/sindredesk-host/sindredesk-host';
        if (!installed) {
          if (Platform.isWindows) {
            await bind.mainSetOption(key: 'stop-service', value: '');
            bind.mainGotoInstall();
          } else if (mounted) {
            setState(() => _error = '请先按 README 安装 Linux 系统服务，再从已安装目录启动 Host');
          }
          return;
        }
      }
      if (!value) {
        final installed = Platform.isWindows
            ? await bind.mainGetCommon(key: 'sindre-installed-host') == 'true'
            : Platform.resolvedExecutable == '/usr/lib/sindredesk-host/sindredesk-host';
        if (!installed) {
          if (mounted) setState(() => _error = '请从正式安装目录打开 Host 后操作');
          return;
        }
      }
      await DesktopAutostart.requestChange(value);
      // 原生安装器可能关闭并重启当前界面；不将发出请求视为安装成功。
      for (var i = 0; i < 15 && mounted; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        await _read();
        if (_enabled == value) return;
      }
      if (mounted) setState(() => _error = '尚未确认系统服务状态，请检查管理员授权');
    } catch (_) {
      if (mounted) setState(() => _error = '系统服务操作失败，请检查安装及权限');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('系统级开机自启'),
        subtitle: const Text('需要管理员授权；系统服务在登录前启动'),
        value: _enabled ?? false,
        onChanged: _busy || _enabled == null ? null : _change,
      ),
      if (_error != null)
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ],
  );
}
