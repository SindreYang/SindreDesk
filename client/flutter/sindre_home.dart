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
import '../models/peer_model.dart';
import '../models/server_model.dart' show kUseTemporaryPassword, kUsePermanentPassword;
import '../mobile/pages/server_page.dart' as mobile;

bool validPublicKey(String value) {
  try {
    return base64Decode(value.trim()).length == 32;
  } catch (_) {
    return false;
  }
}

bool _isPrivateIPv4(String value) {
  final ip = InternetAddress.tryParse(value);
  if (ip == null || ip.type != InternetAddressType.IPv4) return false;
  final parts = value.split('.').map(int.tryParse).toList();
  if (parts.length != 4 || parts.any((part) => part == null)) return false;
  final a = parts[0]!;
  final b = parts[1]!;
  return a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31);
}

bool _isPrivateLanAddress(String value) {
  final parts = value.trim().split(':');
  if (parts.length > 2) return false;
  final port = parts.length == 2 ? int.tryParse(parts[1]) : 21118;
  return port == 21118 && _isPrivateIPv4(parts.first);
}

bool validFingerprint(String value) =>
    RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value.replaceAll(RegExp(r'[:\s]'), ''));

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

Widget _connectionValue(BuildContext context, String title, String value, {VoidCallback? refresh}) {
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

class SindreHome extends StatefulWidget {
  const SindreHome({super.key});

  @override
  State<SindreHome> createState() => _SindreHomeState();
}

class _SindreHomeState extends State<SindreHome> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  final _fingerprint = TextEditingController();
  Timer? _timer;
  Timer? _lanScanTimer;
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
      _scanLan();
      _lanScanTimer = Timer.periodic(const Duration(seconds: 15), (_) => _scanLan());
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
    _fingerprint.dispose();
    _lanScanTimer?.cancel();
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

  void _onIdChanged(String value) {
    final address = value.replaceAll(' ', '').trim();
    if (_isPrivateLanAddress(address)) {
      final saved = bind.mainGetOptionSync(
        key: 'sindre-lan-peer-fingerprint:$address',
      );
      if (saved.isNotEmpty) _fingerprint.text = saved;
    } else {
      _fingerprint.clear();
    }
    setState(() {});
  }

  void _scanLan() {
    if (!mounted || host) return;
    bind.mainLoadLanPeers();
    bind.mainDiscover();
  }

  Future<void> _selectLanPeer(Peer peer) async {
    if (peer.ip.isEmpty || !validFingerprint(peer.fingerprint)) return;
    final address = '${peer.ip}:21118';
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('核对局域网设备'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(peer.hostname.isEmpty ? peer.id : peer.hostname),
            const SizedBox(height: 8),
            SelectableText(address),
            const SizedBox(height: 8),
            const Text('请与被控端屏幕显示的设备指纹逐字符核对。指纹不一致时不要继续。'),
            const SizedBox(height: 8),
            SelectableText(peer.fingerprint),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true),
            child: const Text('已核对，使用此设备')),
        ],
      ),
    );
    if (accepted == true && mounted) {
      setState(() {
        _id.text = address;
        _fingerprint.text = peer.fingerprint;
        _message = '';
      });
    }
  }

  Future<void> _connect() async {
    if (_busy) return;
    final id = _id.text.replaceAll(' ', '').trim();
    final password = _password.text;
    final direct = _isPrivateLanAddress(id);
    if (direct) {
      final fingerprint = _fingerprint.text
          .replaceAll(RegExp(r'[:\s]'), '')
          .trim()
          .toLowerCase();
      if (!validFingerprint(fingerprint)) {
        setState(() => _message = '请填写并核对被控端显示的 64 位设备指纹');
        return;
      }
      await bind.mainSetOption(
        key: 'sindre-lan-peer-fingerprint:${id}',
        value: fingerprint,
      );
    } else {
      if (!RegExp(r'^[0-9]+$').hasMatch(id)) {
        setState(() => _message = '请输入连接码或局域网 IPv4 地址');
        return;
      }
      if (!configured) {
        setState(() => _message = '连接码需要配置私有服务器；局域网可直接使用 IP 地址');
        return;
      }
    }
    if (password.isEmpty) {
      setState(() => _message = '请输入连接密码');
      return;
    }
    setState(() { _busy = true; _message = ''; });
    _password.clear();
    try {
      await connect(context, id, password: password);
    } catch (error) {
      if (mounted) setState(() => _message = '连接失败：${error.toString()}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _lanDiscoveryPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Expanded(child: Text('局域网设备', style: Theme.of(context).textTheme.titleSmall)),
        TextButton.icon(
          onPressed: _scanLan,
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('扫描'),
        ),
      ]),
      AnimatedBuilder(
        animation: gFFI.lanPeersModel,
        builder: (context, _) {
          final peers = gFFI.lanPeersModel.peers
              .where((peer) => peer.ip.isNotEmpty)
              .take(8)
              .toList();
          if (peers.isEmpty) {
            return const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('尚未发现设备。请确认两端处于同一局域网，并允许 UDP 21119。'),
            );
          }
          return Column(children: [
            for (final peer in peers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(peer.hostname.isEmpty ? peer.id : peer.hostname),
                subtitle: Text(
                  "${peer.ip}:21118\n${validFingerprint(peer.fingerprint) ? peer.fingerprint : '此设备不支持安全直连'}",
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  onPressed: validFingerprint(peer.fingerprint)
                      ? () => _selectLanPeer(peer)
                      : null,
                  child: const Text('使用'),
                ),
              ),
          ]);
        },
      ),
      const SizedBox(height: 8),
    ],
  );
  Widget _serverStatus({bool compact = false}) => AnimatedBuilder(
    animation: gFFI.serverModel,
    builder: (context, _) {
      final status = gFFI.serverModel.connectStatus;
      final ready = configured && (host ? status > 0 : _reachable == true);
      final failed = host ? status < 0 : _reachable == false;
      final label = !configured
          ? (host ? '未配置服务器 · 局域网直连' : '未配置服务器 · 可扫描局域网') :
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
          _connectionValue(context, '本机连接码（服务器连接）', model.serverId.text),
          const _LanConnectionInfo(),
          if (DesktopAutostart.supported)
            const _FixedPasswordPanel()
          else
            _connectionValue(context, '连接密码', model.serverPasswd.text,
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
      TextField(
        controller: _id,
        decoration: const InputDecoration(
          labelText: '连接码 / 局域网 IP',
          hintText: '连接码或 192.168.1.20:21118',
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.text,
        onChanged: _onIdChanged,
      ),
      if (_isPrivateLanAddress(_id.text)) ...[
        const SizedBox(height: 12),
        TextField(
          controller: _fingerprint,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F: ]'))],
          decoration: const InputDecoration(
            labelText: '设备指纹（请与被控端核对）',
            hintText: '64 位 SHA-256 指纹',
            border: OutlineInputBorder(),
          ),
        ),
      ],
      const SizedBox(height: 16),
      TextField(
        controller: _password,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(labelText: '连接密码', border: OutlineInputBorder()),
        onSubmitted: (_) => _connect(),
      ),
      const SizedBox(height: 12),
      _lanDiscoveryPanel(),
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
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.:]'))],
          onChanged: _onIdChanged,
          decoration: InputDecoration(
            hintText: '连接码或 192.168.1.20:21118',
            isDense: true,
            prefixIcon: const Icon(Icons.computer_outlined, size: 20),
            border: border,
          ),
        ),
        if (_isPrivateLanAddress(_id.text)) ...[
          const SizedBox(height: 12),
          Text('设备指纹（请与被控端核对）', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          TextField(
            controller: _fingerprint,
            autocorrect: false,
            enableSuggestions: false,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F: ]'))],
            decoration: InputDecoration(
              hintText: '64 位 SHA-256 指纹',
              isDense: true,
              border: border,
            ),
          ),
        ],
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
        const SizedBox(height: 12),
        _lanDiscoveryPanel(),
        const SizedBox(height: 8),
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
          ? const _AndroidHostPanel()
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


class _LanConnectionInfo extends StatefulWidget {
  const _LanConnectionInfo();

  @override
  State<_LanConnectionInfo> createState() => _LanConnectionInfoState();
}

class _LanConnectionInfoState extends State<_LanConnectionInfo> {
  Timer? _timer;
  List<String> _addresses = [];
  String _fingerprint = '';

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = interfaces
          .expand((interface) => interface.addresses)
          .map((address) => address.address)
          .where(_isPrivateIPv4)
          .toSet()
          .toList()
        ..sort();
      final fingerprint = bind.mainGetOptionSync(key: 'sindre-lan-fingerprint');
      if (mounted && (addresses.join(',') != _addresses.join(',') ||
          fingerprint != _fingerprint)) {
        setState(() {
          _addresses = addresses;
          _fingerprint = fingerprint;
        });
      }
    } catch (_) {
      // Network enumeration may be temporarily unavailable while interfaces change.
    }
  }

  Widget _copyable(String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      )),
      IconButton(
        tooltip: '复制',
        onPressed: value.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: value)),
        icon: const Icon(Icons.copy_outlined, size: 18),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final addresses = _addresses.map((address) => '$address:21118').join('\n');
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withOpacity(0.92),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('局域网直连', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          const Text('无需配置服务器。控制端输入以下地址和密码，并核对设备指纹。'),
          const SizedBox(height: 8),
          _copyable('本机局域网地址', addresses.isEmpty ? '未检测到可用的私有 IPv4 地址' : addresses),
          _copyable('设备指纹（SHA-256）',
            _fingerprint.isEmpty ? '共享服务启动后生成' : _fingerprint),
          const Text('首次连接必须核对完整指纹；只在可信的局域网内开放 21118/TCP 和 21119/UDP。'),
        ],
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
    gFFI.serverModel.fetchID();
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
              builder: (context, _) {
                final model = gFFI.serverModel;
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _connectionValue(context, '本机连接码（服务器连接）', model.serverId.text),
                      const _LanConnectionInfo(),
                      _connectionValue(context, '连接密码', model.serverPasswd.text,
                        refresh: model.isStart
                            ? () => bind.mainUpdateTemporaryPassword()
                            : null),
                      if (!model.isStart) mobile.ServiceNotRunningNotification(),
                    ],
                  ),
                );
              },
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
            await bind.mainGetCommon(key: 'permanent-password-set') != 'true') {
          if (mounted) setState(() => _error = '请先设置固定连接密码');
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
