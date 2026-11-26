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
import '../models/server_model.dart' show kUsePermanentPassword;
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

const int _lanDirectPort = 32118;

bool _isPrivateLanAddress(String value) {
  final parts = value.trim().split(':');
  if (parts.length > 2) return false;
  final port = parts.length == 2 ? int.tryParse(parts[1]) : _lanDirectPort;
  return port == _lanDirectPort && _isPrivateIPv4(parts.first);
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

Widget _connectionValue(BuildContext context, String title, String value,
    {VoidCallback? edit, bool copy = true}) {
  final theme = Theme.of(context);
  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: theme.textTheme.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant)),
    const SizedBox(height: 4),
    Row(children: [
      Expanded(child: SelectableText(value, style: theme.textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w500))),
      if (edit != null)
        IconButton(tooltip: '修改密码', onPressed: edit,
          icon: const Icon(Icons.edit_outlined, size: 20)),
      if (copy)
        IconButton(tooltip: '复制', onPressed: value.isEmpty ? null :
          () => Clipboard.setData(ClipboardData(text: value)),
          icon: const Icon(Icons.copy_outlined, size: 20)),
    ]),
  ]);
}

Widget _surfaceCard(BuildContext context, Widget child) => Container(
  padding: const EdgeInsets.all(20),
  decoration: BoxDecoration(
    color: Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF21242A) : Colors.white,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
  ),
  child: child,
);

String _lanIp(String value) => value.trim().split(':').first;

class SindreHome extends StatefulWidget {
  const SindreHome({super.key});

  @override
  State<SindreHome> createState() => _SindreHomeState();
}

class _SindreHomeState extends State<SindreHome> {
  final _id = TextEditingController();
  final _password = TextEditingController();
  Timer? _timer;
  Timer? _lanScanTimer;
  Timer? _recentTimer;
  bool _busy = false;
  bool _showPassword = false;
  String _lanStatus = 'unavailable';
  bool _checkingLan = false;
  Timer? _lanStatusTimer;
  String _message = '';

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
      unawaited(gFFI.serverModel.setVerificationMethod(kUsePermanentPassword));
      unawaited(_readLanStatus());
      _lanStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) => _readLanStatus());
    }
    if (!host) {
      _scanLan();
      bind.mainLoadRecentPeers();
      _recentTimer = Timer.periodic(const Duration(seconds: 4), (_) => bind.mainLoadRecentPeers());
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
    _lanScanTimer?.cancel();
    _recentTimer?.cancel();
    _lanStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _readLanStatus() async {
    if (!mounted || _checkingLan || !host) return;
    _checkingLan = true;
    try {
      final status = await bind.mainGetCommon(key: 'sindre-lan-status');
      if (mounted && _lanStatus != status) setState(() => _lanStatus = status);
    } catch (_) {
      if (mounted && _lanStatus != 'unavailable') setState(() => _lanStatus = 'unavailable');
    } finally {
      _checkingLan = false;
    }
  }

  Future<void> _settings() async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ServerSettings(host: host),
    );
    if (mounted) {
      setState(() { if (saved == true) _message = ''; });
    }
  }

  void _onIdChanged(String value) => setState(() => _message = '');

  void _scanLan() {
    if (!mounted || host) return;
    bind.mainDiscover();
  }

  void _selectLanPeer(Peer peer) {
    if (_busy || !_isPrivateIPv4(peer.ip)) return;
    unawaited(_connect(target: peer.ip));
  }

  Future<void> _connect({String? target}) async {
    if (_busy) return;
    final id = (target ?? _id.text).replaceAll(' ', '').trim();
    // 点击设备时读取对应设备的原生凭据，不误用其他设备密码。
    final password = target == null ? _password.text : '';
    if (target != null) {
      _id.text = id;
      _password.clear();
    }
    final direct = _isPrivateLanAddress(id);
    if (!direct && !RegExp(r'^[0-9]+$').hasMatch(id)) {
      setState(() => _message = '请输入连接码或局域网 IP 地址');
      return;
    }
    if (!direct && !configured) {
      setState(() => _message = '使用连接码前请在右上角配置服务器');
      return;
    }
    // 留空时由原生会话读取已保存凭据，首次连接则弹出密码输入框。
    setState(() { _busy = true; _message = ''; });
    try {
      _password.clear();
      await connect(context, direct ? _lanIp(id) : id,
        password: password.isEmpty ? null : password);
    } catch (_) {
      if (mounted) setState(() => _message = '连接失败，请检查对方设备及连接信息');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeRecentPeer(Peer peer) async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(title: const Text('删除连接记录？'),
        content: const Text('将同时删除该设备已保存的密码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('删除')),
        ]));
    if (confirmed != true || !mounted) return;
    try {
      await bind.mainRemovePeer(id: peer.id);
      if (mounted) bind.mainLoadRecentPeers();
    } catch (_) {
      if (mounted) setState(() => _message = '删除连接记录失败');
    }
  }

  Widget _recentPanel() => AnimatedBuilder(
    animation: gFFI.recentPeersModel,
    builder: (_, __) {
      final peers = gFFI.recentPeersModel.peers.where((peer) =>
        (peer.hostname.isNotEmpty || peer.platform.isNotEmpty) &&
        (_isPrivateLanAddress(peer.id) || RegExp(r'^[0-9]+ Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Expanded(child: Text('局域网设备', style: Theme.of(context).textTheme.titleSmall)),
        IconButton(tooltip: '刷新设备', onPressed: _scanLan,
          icon: const Icon(Icons.refresh, size: 20)),
      ]),
      AnimatedBuilder(
        animation: gFFI.lanPeersModel,
        builder: (context, _) {
          final peers = gFFI.lanPeersModel.peers.where((peer) =>
              _isPrivateIPv4(peer.ip)).take(8).toList();
          if (peers.isEmpty) return Text('暂未发现设备', style: Theme.of(context).textTheme.bodySmall);
          return Column(children: [
            for (final peer in peers)
              Padding(padding: const EdgeInsets.only(bottom: 6),
                child: _surfaceCard(context, ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(peer.hostname.isEmpty ? peer.id : peer.hostname,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(peer.ip),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _selectLanPeer(peer),
                ))),
          ]);
        },
      ),
    ],
  );

  Widget _hostDesktop() {
    final model = gFFI.serverModel;
    return AnimatedBuilder(
      animation: model,
      builder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _connectionValue(context, '本机连接码', model.serverId.text),
          const Divider(height: 24),
          const _FixedPasswordPanel(),
        ],
      ),
    );
  }

  Widget _client() {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(8));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _surfaceCard(context, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('连接码或 IP 地址', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(controller: _id, enabled: !_busy,
          keyboardType: TextInputType.text, textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.: ]'))],
          onChanged: _onIdChanged,
          decoration: InputDecoration(hintText: '输入连接码或 IP 地址',
            isDense: true, border: border)),
        const SizedBox(height: 16),
        Text('连接密码', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(controller: _password, enabled: !_busy,
          obscureText: !_showPassword, autocorrect: false, enableSuggestions: false,
          textInputAction: TextInputAction.done, onSubmitted: (_) => _connect(),
          decoration: InputDecoration(hintText: '输入密码（已保存可留空）', isDense: true, border: border,
            suffixIcon: IconButton(tooltip: _showPassword ? '隐藏密码' : '显示密码',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20)))),
        const SizedBox(height: 18),
        FilledButton(style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1769D2), foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          onPressed: _busy ? null : _connect,
          child: Text(_busy ? '连接中…' : '连接设备')),
        if (_message.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(_message,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ])),
      const SizedBox(height: 12),
      _recentPanel(),
      _lanDiscoveryPanel(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = theme.brightness == Brightness.dark
        ? const Color(0xFF17191D) : const Color(0xFFF4F6F9);
    return Scaffold(
      backgroundColor: background,
      bottomNavigationBar: host ? SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Row(children: [
          Expanded(child: AnimatedBuilder(animation: gFFI.serverModel, builder: (_, __) {
            final model = gFFI.serverModel;
            final connected = model.clients.any((client) => !client.disconnected);
            final stopped = isAndroid && !model.isStart;
            final bindError = _lanStatus == 'bind-error';
            final ready = _lanStatus == 'ready';
            final status = stopped ? '未启动共享' : connected ? '连接中'
                : bindError ? '局域网端口不可用' : ready ? '等待连接' : '局域网未就绪';
            return Row(children: [
              Icon(Icons.circle, size: 8, color: bindError ? colors.error : ready && !stopped ? Colors.green : colors.outline),
              const SizedBox(width: 6),
              Flexible(child: Text(status, style: theme.textTheme.bodySmall)),
            ]);
          })),
          const _LanConnectionInfo(),
        ]),
      )) : null,
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(host ? '客户端（被控端）' : '控制端',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(host ? '允许其他设备连接本机' : '连接其他设备',
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              ])),
              IconButton(tooltip: '设置', onPressed: _settings, icon: const Icon(Icons.settings_outlined)),
            ]),
            const SizedBox(height: 16),
            if (host) _surfaceCard(context, _hostDesktop()) else _client(),
            if (host && isAndroid) const _AndroidHostPanel(),
          ]),
        )),
      )),
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

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // 优先采用系统默认路由对应的物理网络，不按 IP 网段猜测。
  bool _virtual(String name) => RegExp(
      r'vethernet|hyper-v|wsl|docker|vbox|vmware|virtual|tailscale|zerotier|wireguard|(^|\W)(tun|tap|utun|virbr|veth|br-)',
      caseSensitive: false).hasMatch(name);

  Future<String?> _defaultAddress(List<NetworkInterface> interfaces) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-Command',
          r'''$physical = @(Get-NetAdapter -Physical | Where-Object Status -eq Up | Select-Object -ExpandProperty ifIndex); Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $physical -contains $_.InterfaceIndex } | Sort-Object { $_.NetIPv4Interface.InterfaceMetric } | ForEach-Object { $_.IPv4Address.IPAddress }''',
        ]).timeout(const Duration(seconds: 5));
        if (result.exitCode == 0) {
          for (final ip in result.stdout.toString().split(RegExp(r'\s+'))) {
            if (_isPrivateIPv4(ip)) return ip;
          }
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('ip', ['-4', 'route', 'show', 'default'])
          .timeout(const Duration(seconds: 3));
        if (result.exitCode == 0) {
          for (final line in result.stdout.toString().split('\n')) {
            final name = RegExp(r'\bdev\s+(\S+)').firstMatch(line)?.group(1);
            if (name == null || _virtual(name)) continue;
            for (final interface in interfaces.where((item) => item.name == name)) {
              for (final address in interface.addresses) {
                if (_isPrivateIPv4(address.address)) return address.address;
              }
            }
          }
        }
      }
    } catch (_) {
      // 缺少系统命令或权限时回退到接口名称排序。
    }
    return null;
  }

  bool _refreshing = false;
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final interfaces = (await NetworkInterface.list(type: InternetAddressType.IPv4,
          includeLoopback: false)).toList();
      int priority(NetworkInterface item) {
        if (_virtual(item.name)) return 2;
        if (RegExp(r'eth|en[opsx]|wlan|wi-fi|wifi|ethernet', caseSensitive: false)
            .hasMatch(item.name)) return 0;
        return 1;
      }
      interfaces.sort((a, b) => priority(a).compareTo(priority(b)));
      final addresses = interfaces.expand((item) => item.addresses)
          .map((address) => address.address).where(_isPrivateIPv4).toSet().toList();
      final preferred = await _defaultAddress(interfaces);
      if (preferred != null && addresses.contains(preferred)) {
        addresses.remove(preferred);
        addresses.insert(0, preferred);
      }
      if (mounted && addresses.join(',') != _addresses.join(',')) {
        setState(() => _addresses = addresses);
      }
    } catch (_) {
      // Network enumeration may be temporarily unavailable.
    } finally {
      _refreshing = false;
    }
  }

  Widget _copyable(String label, String value) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      SelectableText(value),
    ])),
    IconButton(tooltip: '复制', onPressed: value.isEmpty ? null :
      () => Clipboard.setData(ClipboardData(text: value)), icon: const Icon(Icons.copy_outlined, size: 18)),
  ]);

  Future<void> _details() async {
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('本机网络信息'), scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final address in _addresses) _copyable('局域网 IP', address),
        if (_addresses.isEmpty) const Text('未检测到局域网地址'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ));
  }

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: _details,
    borderRadius: BorderRadius.circular(4),
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Text(_addresses.isEmpty ? '无局域网' : _addresses.first,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant))),
  );
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
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: gFFI.serverModel,
    child: AnimatedBuilder(animation: gFFI.serverModel, builder: (_, __) {
      final model = gFFI.serverModel;
      return Column(children: [
        if (!model.isStart) mobile.ServiceNotRunningNotification(),
        for (final client in model.clients.where((c) => !c.disconnected))
          ListTile(title: Text('会话 ${client.peerId}'),
            trailing: TextButton(onPressed: () => bind.cmCloseConnection(connId: client.id),
              child: const Text('断开连接'))),
        if (model.isStart)
          OutlinedButton(onPressed: () => model.stopService(), child: const Text('停止共享')),
        ExpansionTile(title: const Text('系统权限'), children: const [mobile.PermissionChecker()]),
      ]);
    }),
  );
}

class _ServerSettings extends StatefulWidget {
  const _ServerSettings({required this.host});
  final bool host;

  @override
  State<_ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<_ServerSettings> {
  final _server = TextEditingController(
    text: bind.mainGetOptionSync(key: 'custom-rendezvous-server'));
  final _key = TextEditingController(text: bind.mainGetOptionSync(key: 'key'));
  bool _busy = false;
  String? _error;
  bool _lanCompat = bind.mainGetOptionSync(key: 'sindre-lan-compat') == 'Y';

  Future<void> _setLanCompat(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await bind.mainSetOption(key: 'sindre-lan-compat', value: enabled ? 'Y' : '');
      final saved = bind.mainGetOptionSync(key: 'sindre-lan-compat') == 'Y';
      if (mounted) setState(() {
        _lanCompat = saved;
        _error = saved == enabled ? null : '局域网兼容模式保存失败';
      });
    } catch (_) {
      if (mounted) setState(() => _error = '局域网兼容模式保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _clearLanTrust() async {
    if (_busy || widget.host) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(title: const Text('清除局域网信任记录？'),
        content: const Text('仅在确认被控设备更换时使用。下次连接将重新建立信任，请仅在可信网络操作。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
        ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await bind.mainGetCommon(key: 'sindre-clear-lan-trust');
      if (mounted) setState(() => _error = ok == 'true' ? '已清除局域网信任记录' : '清除失败');
    } catch (_) {
      if (mounted) setState(() => _error = '清除失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final server = _server.text.trim();
    final key = _key.text.trim();
    final clear = server.isEmpty && key.isEmpty;
    if (!clear && (!validServer(server) || !validPublicKey(key))) {
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
      bool ok;
      if (clear) {
        await bind.mainSetOption(key: 'custom-rendezvous-server', value: '');
        await bind.mainSetOption(key: 'relay-server', value: '');
        await bind.mainSetOption(key: 'api-server', value: '');
        ok = true;
      } else {
        ok = await setServerConfig(null, null, ServerConfig(idServer: server, key: key));
      }
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
    title: const Text('设置'),
    scrollable: true,
    content: SizedBox(width: 380, child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('服务器配置（跨网络连接）'),
        TextField(controller: _server,
          decoration: const InputDecoration(labelText: '服务器 IP / 域名')),
        const SizedBox(height: 12),
        TextField(controller: _key, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: '服务器公钥')),
        if (_error != null) Padding(
          padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('局域网兼容模式'),
          subtitle: const Text('测试用：加密握手失败后允许非加密直连，两端均需开启'),
          value: _lanCompat,
          onChanged: _busy ? null : _setLanCompat,
        ),
        if (!widget.host) ...[
          const Divider(height: 24),
          TextButton(onPressed: _busy ? null : _clearLanTrust,
            child: const Text('清除局域网信任记录')),
        ],
        if (widget.host && DesktopAutostart.supported) ...[
          const Divider(height: 24),
          const _DesktopAutostartSwitch(),
        ],
      ],
    )),
    actions: [
      Row(children: [
        Expanded(child: Text('基于SindreDesk研发--开源且免费',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.normal,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ))),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消')),
        const SizedBox(width: 8),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
      ]),
    ],
  );
}


/// 永久密码验证仍由原生服务完成；只读取本机加密缓存。
class _FixedPasswordPanel extends StatefulWidget {
  const _FixedPasswordPanel();
  @override
  State<_FixedPasswordPanel> createState() => _FixedPasswordPanelState();
}

class _FixedPasswordPanelState extends State<_FixedPasswordPanel> {
  bool _busy = false;
  String _state = 'unavailable';
  String _password = '';
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _retry = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_busy) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  String _randomPassword() {
    final random = Random.secure();
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  Future<void> _read() async {
    if (_busy || !bind.isIncomingOnly()) return;
    _busy = true;
    try {
      if (bind.mainGetOptionSync(key: 'verification-method') != kUsePermanentPassword) {
        await gFFI.serverModel.setVerificationMethod(kUsePermanentPassword);
      }
      var state = await bind.mainGetCommon(key: 'sindre-fixed-password');
      if (state == 'missing') {
        final ok = await bind.mainSetPermanentPasswordWithResult(password: _randomPassword());
        state = ok ? await bind.mainGetCommon(key: 'sindre-fixed-password') : 'unavailable';
      }
      if (mounted) setState(() {
        _state = state.startsWith('ready:') ? 'ready' : state;
        _password = _state == 'ready' ? state.substring(6) : '';
      });
    } catch (_) {
      if (mounted) setState(() { _state = 'unavailable'; _password = ''; });
    } finally {
      _busy = false;
    }
  }

  Future<void> _change() async {
    if (_busy || !bind.isIncomingOnly()) return;
    _busy = true;
    try {
      final password = _randomPassword();
      final confirm = await showDialog<bool>(context: context, builder: (context) =>
        AlertDialog(title: const Text('更换固定密码？'),
          content: const Text('确认后旧密码失效，新密码将显示在首页。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('更换')),
          ]));
      if (confirm != true || !mounted) return;
      final ok = await bind.mainSetPermanentPasswordWithResult(password: password);
      if (!ok) throw StateError('Password update failed');
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码更换失败，请检查共享服务状态')));
    } finally {
      _busy = false;
      if (mounted) unawaited(_read());
    }
  }

  @override
  Widget build(BuildContext context) => _connectionValue(context, '固定密码',
    _state == 'ready' ? _password : _state == 'legacy' ? '已设置' : '准备中…',
    copy: _state == 'ready', edit: _state == 'ready' || _state == 'legacy' ? _change : null);
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
).hasMatch(peer.id))).toList();
      if (peers.isEmpty) return const SizedBox.shrink();
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 12),
        Text('最近连接', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final peer in peers)
          Padding(padding: const EdgeInsets.only(bottom: 6),
            child: _surfaceCard(context, ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.history),
              title: Text(peer.hostname.isEmpty ? peer.id : peer.hostname,
                maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(peer.id),
              trailing: IconButton(tooltip: '删除记录及密码',
                onPressed: _busy ? null : () => _removeRecentPeer(peer),
                icon: const Icon(Icons.close, size: 18)),
              onTap: _busy ? null : () => _connect(target: peer.id),
            ))),
      ]);
    },
  );

  Widget _lanDiscoveryPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(children: [
        Expanded(child: Text('局域网设备', style: Theme.of(context).textTheme.titleSmall)),
        IconButton(tooltip: '刷新设备', onPressed: _scanLan,
          icon: const Icon(Icons.refresh, size: 20)),
      ]),
      AnimatedBuilder(
        animation: gFFI.lanPeersModel,
        builder: (context, _) {
          final peers = gFFI.lanPeersModel.peers.where((peer) =>
              _isPrivateIPv4(peer.ip)).take(8).toList();
          if (peers.isEmpty) return Text('暂未发现设备', style: Theme.of(context).textTheme.bodySmall);
          return Column(children: [
            for (final peer in peers)
              Padding(padding: const EdgeInsets.only(bottom: 6),
                child: _surfaceCard(context, ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: const Icon(Icons.computer_outlined),
                  title: Text(peer.hostname.isEmpty ? peer.id : peer.hostname,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(peer.ip),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _selectLanPeer(peer),
                ))),
          ]);
        },
      ),
    ],
  );

  Widget _hostDesktop() {
    final model = gFFI.serverModel;
    return AnimatedBuilder(
      animation: model,
      builder: (_, __) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _connectionValue(context, '本机连接码', model.serverId.text),
          const Divider(height: 24),
          const _FixedPasswordPanel(),
        ],
      ),
    );
  }

  Widget _client() {
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(8));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _surfaceCard(context, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('连接码或 IP 地址', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(controller: _id, enabled: !_busy,
          keyboardType: TextInputType.text, textInputAction: TextInputAction.next,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.: ]'))],
          onChanged: _onIdChanged,
          decoration: InputDecoration(hintText: '输入连接码或 IP 地址',
            isDense: true, border: border)),
        const SizedBox(height: 16),
        Text('连接密码', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        TextField(controller: _password, enabled: !_busy,
          obscureText: !_showPassword, autocorrect: false, enableSuggestions: false,
          textInputAction: TextInputAction.done, onSubmitted: (_) => _connect(),
          decoration: InputDecoration(hintText: '输入对方设备密码', isDense: true, border: border,
            suffixIcon: IconButton(tooltip: _showPassword ? '隐藏密码' : '显示密码',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20)))),
        const SizedBox(height: 18),
        FilledButton(style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1769D2), foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(44),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          onPressed: _busy ? null : _connect,
          child: Text(_busy ? '连接中…' : '连接设备')),
        if (_message.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 10), child: Text(_message,
            style: TextStyle(color: Theme.of(context).colorScheme.error))),
      ])),
      const SizedBox(height: 12),
      _recentPanel(),
      _lanDiscoveryPanel(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = theme.brightness == Brightness.dark
        ? const Color(0xFF17191D) : const Color(0xFFF4F6F9);
    return Scaffold(
      backgroundColor: background,
      bottomNavigationBar: host ? SafeArea(child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: Row(children: [
          Expanded(child: AnimatedBuilder(animation: gFFI.serverModel, builder: (_, __) {
            final model = gFFI.serverModel;
            final connected = model.clients.any((client) => !client.disconnected);
            final stopped = isAndroid && !model.isStart;
            final bindError = _lanStatus == 'bind-error';
            final ready = _lanStatus == 'ready';
            final status = stopped ? '未启动共享' : connected ? '连接中'
                : bindError ? '局域网端口不可用' : ready ? '等待连接' : '局域网未就绪';
            return Row(children: [
              Icon(Icons.circle, size: 8, color: bindError ? colors.error : ready && !stopped ? Colors.green : colors.outline),
              const SizedBox(width: 6),
              Flexible(child: Text(status, style: theme.textTheme.bodySmall)),
            ]);
          })),
          const _LanConnectionInfo(),
        ]),
      )) : null,
      body: SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(host ? '客户端（被控端）' : '控制端',
                  style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(host ? '允许其他设备连接本机' : '连接其他设备',
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
              ])),
              IconButton(tooltip: '设置', onPressed: _settings, icon: const Icon(Icons.settings_outlined)),
            ]),
            const SizedBox(height: 16),
            if (host) _surfaceCard(context, _hostDesktop()) else _client(),
            if (host && isAndroid) const _AndroidHostPanel(),
          ]),
        )),
      )),
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

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // 优先采用系统默认路由对应的物理网络，不按 IP 网段猜测。
  bool _virtual(String name) => RegExp(
      r'vethernet|hyper-v|wsl|docker|vbox|vmware|virtual|tailscale|zerotier|wireguard|(^|\W)(tun|tap|utun|virbr|veth|br-)',
      caseSensitive: false).hasMatch(name);

  Future<String?> _defaultAddress(List<NetworkInterface> interfaces) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-Command',
          r'''$physical = @(Get-NetAdapter -Physical | Where-Object Status -eq Up | Select-Object -ExpandProperty ifIndex); Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $physical -contains $_.InterfaceIndex } | Sort-Object { $_.NetIPv4Interface.InterfaceMetric } | ForEach-Object { $_.IPv4Address.IPAddress }''',
        ]).timeout(const Duration(seconds: 5));
        if (result.exitCode == 0) {
          for (final ip in result.stdout.toString().split(RegExp(r'\s+'))) {
            if (_isPrivateIPv4(ip)) return ip;
          }
        }
      } else if (Platform.isLinux) {
        final result = await Process.run('ip', ['-4', 'route', 'show', 'default'])
          .timeout(const Duration(seconds: 3));
        if (result.exitCode == 0) {
          for (final line in result.stdout.toString().split('\n')) {
            final name = RegExp(r'\bdev\s+(\S+)').firstMatch(line)?.group(1);
            if (name == null || _virtual(name)) continue;
            for (final interface in interfaces.where((item) => item.name == name)) {
              for (final address in interface.addresses) {
                if (_isPrivateIPv4(address.address)) return address.address;
              }
            }
          }
        }
      }
    } catch (_) {
      // 缺少系统命令或权限时回退到接口名称排序。
    }
    return null;
  }

  bool _refreshing = false;
  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final interfaces = (await NetworkInterface.list(type: InternetAddressType.IPv4,
          includeLoopback: false)).toList();
      int priority(NetworkInterface item) {
        if (_virtual(item.name)) return 2;
        if (RegExp(r'eth|en[opsx]|wlan|wi-fi|wifi|ethernet', caseSensitive: false)
            .hasMatch(item.name)) return 0;
        return 1;
      }
      interfaces.sort((a, b) => priority(a).compareTo(priority(b)));
      final addresses = interfaces.expand((item) => item.addresses)
          .map((address) => address.address).where(_isPrivateIPv4).toSet().toList();
      final preferred = await _defaultAddress(interfaces);
      if (preferred != null && addresses.contains(preferred)) {
        addresses.remove(preferred);
        addresses.insert(0, preferred);
      }
      if (mounted && addresses.join(',') != _addresses.join(',')) {
        setState(() => _addresses = addresses);
      }
    } catch (_) {
      // Network enumeration may be temporarily unavailable.
    } finally {
      _refreshing = false;
    }
  }

  Widget _copyable(String label, String value) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelMedium),
      SelectableText(value),
    ])),
    IconButton(tooltip: '复制', onPressed: value.isEmpty ? null :
      () => Clipboard.setData(ClipboardData(text: value)), icon: const Icon(Icons.copy_outlined, size: 18)),
  ]);

  Future<void> _details() async {
    await showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('本机网络信息'), scrollable: true,
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final address in _addresses) _copyable('局域网 IP', address),
        if (_addresses.isEmpty) const Text('未检测到局域网地址'),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
    ));
  }

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: _details,
    borderRadius: BorderRadius.circular(4),
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Text(_addresses.isEmpty ? '无局域网' : _addresses.first,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant))),
  );
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
  Widget build(BuildContext context) => ChangeNotifierProvider.value(
    value: gFFI.serverModel,
    child: AnimatedBuilder(animation: gFFI.serverModel, builder: (_, __) {
      final model = gFFI.serverModel;
      return Column(children: [
        if (!model.isStart) mobile.ServiceNotRunningNotification(),
        for (final client in model.clients.where((c) => !c.disconnected))
          ListTile(title: Text('会话 ${client.peerId}'),
            trailing: TextButton(onPressed: () => bind.cmCloseConnection(connId: client.id),
              child: const Text('断开连接'))),
        if (model.isStart)
          OutlinedButton(onPressed: () => model.stopService(), child: const Text('停止共享')),
        ExpansionTile(title: const Text('系统权限'), children: const [mobile.PermissionChecker()]),
      ]);
    }),
  );
}

class _ServerSettings extends StatefulWidget {
  const _ServerSettings({required this.host});
  final bool host;

  @override
  State<_ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<_ServerSettings> {
  final _server = TextEditingController(
    text: bind.mainGetOptionSync(key: 'custom-rendezvous-server'));
  final _key = TextEditingController(text: bind.mainGetOptionSync(key: 'key'));
  bool _busy = false;
  String? _error;
  bool _lanCompat = bind.mainGetOptionSync(key: 'sindre-lan-compat') == 'Y';

  Future<void> _setLanCompat(bool enabled) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await bind.mainSetOption(key: 'sindre-lan-compat', value: enabled ? 'Y' : '');
      final saved = bind.mainGetOptionSync(key: 'sindre-lan-compat') == 'Y';
      if (mounted) setState(() {
        _lanCompat = saved;
        _error = saved == enabled ? null : '局域网兼容模式保存失败';
      });
    } catch (_) {
      if (mounted) setState(() => _error = '局域网兼容模式保存失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _clearLanTrust() async {
    if (_busy || widget.host) return;
    final confirmed = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(title: const Text('清除局域网信任记录？'),
        content: const Text('仅在确认被控设备更换时使用。下次连接将重新建立信任，请仅在可信网络操作。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('清除')),
        ]));
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final ok = await bind.mainGetCommon(key: 'sindre-clear-lan-trust');
      if (mounted) setState(() => _error = ok == 'true' ? '已清除局域网信任记录' : '清除失败');
    } catch (_) {
      if (mounted) setState(() => _error = '清除失败');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final server = _server.text.trim();
    final key = _key.text.trim();
    final clear = server.isEmpty && key.isEmpty;
    if (!clear && (!validServer(server) || !validPublicKey(key))) {
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
      bool ok;
      if (clear) {
        await bind.mainSetOption(key: 'custom-rendezvous-server', value: '');
        await bind.mainSetOption(key: 'relay-server', value: '');
        await bind.mainSetOption(key: 'api-server', value: '');
        ok = true;
      } else {
        ok = await setServerConfig(null, null, ServerConfig(idServer: server, key: key));
      }
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
    title: const Text('设置'),
    scrollable: true,
    content: SizedBox(width: 380, child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('服务器配置（跨网络连接）'),
        TextField(controller: _server,
          decoration: const InputDecoration(labelText: '服务器 IP / 域名')),
        const SizedBox(height: 12),
        TextField(controller: _key, autocorrect: false, enableSuggestions: false,
          decoration: const InputDecoration(labelText: '服务器公钥')),
        if (_error != null) Padding(
          padding: const EdgeInsets.only(top: 12), child: Text(_error!)),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('局域网兼容模式'),
          subtitle: const Text('测试用：加密握手失败后允许非加密直连，两端均需开启'),
          value: _lanCompat,
          onChanged: _busy ? null : _setLanCompat,
        ),
        if (!widget.host) ...[
          const Divider(height: 24),
          TextButton(onPressed: _busy ? null : _clearLanTrust,
            child: const Text('清除局域网信任记录')),
        ],
        if (widget.host && DesktopAutostart.supported) ...[
          const Divider(height: 24),
          const _DesktopAutostartSwitch(),
        ],
      ],
    )),
    actions: [
      Row(children: [
        Expanded(child: Text('基于SindreDesk研发--开源且免费',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.normal,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ))),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消')),
        const SizedBox(width: 8),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
      ]),
    ],
  );
}


/// 永久密码验证仍由原生服务完成；只读取本机加密缓存。
class _FixedPasswordPanel extends StatefulWidget {
  const _FixedPasswordPanel();
  @override
  State<_FixedPasswordPanel> createState() => _FixedPasswordPanelState();
}

class _FixedPasswordPanelState extends State<_FixedPasswordPanel> {
  bool _busy = false;
  String _state = 'unavailable';
  String _password = '';
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    unawaited(_read());
    _retry = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_busy) unawaited(_read());
    });
  }

  @override
  void dispose() {
    _retry?.cancel();
    super.dispose();
  }

  String _randomPassword() {
    final random = Random.secure();
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    return List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }

  Future<void> _read() async {
    if (_busy || !bind.isIncomingOnly()) return;
    _busy = true;
    try {
      if (bind.mainGetOptionSync(key: 'verification-method') != kUsePermanentPassword) {
        await gFFI.serverModel.setVerificationMethod(kUsePermanentPassword);
      }
      var state = await bind.mainGetCommon(key: 'sindre-fixed-password');
      if (state == 'missing') {
        final ok = await bind.mainSetPermanentPasswordWithResult(password: _randomPassword());
        state = ok ? await bind.mainGetCommon(key: 'sindre-fixed-password') : 'unavailable';
      }
      if (mounted) setState(() {
        _state = state.startsWith('ready:') ? 'ready' : state;
        _password = _state == 'ready' ? state.substring(6) : '';
      });
    } catch (_) {
      if (mounted) setState(() { _state = 'unavailable'; _password = ''; });
    } finally {
      _busy = false;
    }
  }

  Future<void> _change() async {
    if (_busy || !bind.isIncomingOnly()) return;
    _busy = true;
    try {
      final password = _randomPassword();
      final confirm = await showDialog<bool>(context: context, builder: (context) =>
        AlertDialog(title: const Text('更换固定密码？'),
          content: const Text('确认后旧密码失效，新密码将显示在首页。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('更换')),
          ]));
      if (confirm != true || !mounted) return;
      final ok = await bind.mainSetPermanentPasswordWithResult(password: password);
      if (!ok) throw StateError('Password update failed');
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密码更换失败，请检查共享服务状态')));
    } finally {
      _busy = false;
      if (mounted) unawaited(_read());
    }
  }

  @override
  Widget build(BuildContext context) => _connectionValue(context, '固定密码',
    _state == 'ready' ? _password : _state == 'legacy' ? '已设置' : '准备中…',
    copy: _state == 'ready', edit: _state == 'ready' || _state == 'legacy' ? _change : null);
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
