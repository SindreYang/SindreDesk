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

String _savedFingerprint(String address) {
  final ip = _lanIp(address);
  final saved = bind.mainGetOptionSync(key: 'sindre-lan-peer-fingerprint:$ip');
  return validFingerprint(saved) ? saved : bind.mainGetOptionSync(
      key: 'sindre-lan-peer-fingerprint:$ip:21118');
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
  Timer? _lanScanTimer;
  bool _busy = false;
  bool _showPassword = false;
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
    }
    if (!host) {
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
    _lanScanTimer?.cancel();
    super.dispose();
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
    bind.mainLoadLanPeers();
    bind.mainDiscover();
  }

  Future<bool> _confirmIdentity(String address, {String advertised = ''}) async {
    final ip = _lanIp(address);
    final saved = _savedFingerprint(ip);
    if (validFingerprint(saved) &&
        (advertised.isEmpty || saved.toLowerCase() == advertised.toLowerCase())) {
      await bind.mainSetOption(key: 'sindre-lan-peer-fingerprint:$ip',
          value: saved.toLowerCase());
      return true;
    }
    String entered = '';
    final accepted = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认设备身份'),
        scrollable: true,
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('在被控端点击右下角 IP，复制完整设备指纹并粘贴到这里。'),
          const SizedBox(height: 12),
          TextField(onChanged: (value) => entered = value, autocorrect: false,
            enableSuggestions: false, maxLines: 3,
            decoration: const InputDecoration(labelText: '设备指纹',
              border: OutlineInputBorder())),
          if (advertised.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('发现的设备指纹（必须与被控端一致）'),
            SelectableText(advertised),
          ],
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () {
            final value = entered.replaceAll(RegExp(r'[:\s]'), '').toLowerCase();
            if (validFingerprint(value) &&
                (advertised.isEmpty || value == advertised.toLowerCase())) {
              Navigator.pop(context, value);
            } else {
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(content: Text('指纹无效或不一致，请重新核对')));
            }
          }, child: const Text('确认')),
        ],
      ),
    );
    if (accepted == null || !mounted) return false;
    await bind.mainSetOption(key: 'sindre-lan-peer-fingerprint:$ip', value: accepted);
    return true;
  }

  Future<void> _selectLanPeer(Peer peer) async {
    if (_busy || !_isPrivateIPv4(peer.ip) || !validFingerprint(peer.fingerprint)) return;
    setState(() => _busy = true);
    try {
      if (!await _confirmIdentity(peer.ip, advertised: peer.fingerprint) || !mounted) return;
      setState(() { _id.text = peer.ip; _message = ''; });
    } catch (_) {
      if (mounted) setState(() => _message = '无法保存设备身份，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgetIdentity() async {
    if (_busy || !_isPrivateLanAddress(_id.text)) return;
    final ip = _lanIp(_id.text);
    final confirm = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(title: const Text('重新核对设备身份？'),
        content: const Text('下次连接时需要重新核对被控端设备指纹。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新核对')),
        ]));
    if (confirm != true || !mounted) return;
    await bind.mainSetOption(key: 'sindre-lan-peer-fingerprint:$ip', value: '');
    await bind.mainSetOption(key: 'sindre-lan-peer-fingerprint:$ip:21118', value: '');
    if (mounted) setState(() {});
  }

  Future<void> _connect() async {
    if (_busy) return;
    final id = _id.text.replaceAll(' ', '').trim();
    final password = _password.text;
    final direct = _isPrivateLanAddress(id);
    if (!direct && !RegExp(r'^[0-9]+$').hasMatch(id)) {
      setState(() => _message = '请输入连接码或局域网 IP 地址');
      return;
    }
    if (!direct && !configured) {
      setState(() => _message = '使用连接码前请在右上角配置服务器');
      return;
    }
    if (password.isEmpty) {
      setState(() => _message = '请输入连接密码');
      return;
    }
    setState(() { _busy = true; _message = ''; });
    try {
      if (direct) {
        final ip = _lanIp(id);
        final matches = gFFI.lanPeersModel.peers.where((peer) =>
            peer.ip == ip && validFingerprint(peer.fingerprint)).toList();
        final advertised = matches.isEmpty ? '' : matches.first.fingerprint;
        if (!await _confirmIdentity(id, advertised: advertised) || !mounted) return;
      }
      _password.clear();
      await connect(context, direct ? _lanIp(id) : id, password: password);
    } catch (_) {
      if (mounted) setState(() => _message = '连接失败，请检查对方设备及连接信息');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
              _isPrivateIPv4(peer.ip) && validFingerprint(peer.fingerprint)).take(8).toList();
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
            isDense: true, border: border,
            suffixIcon: _isPrivateLanAddress(_id.text) ? IconButton(
              tooltip: '重新核对设备身份', onPressed: _forgetIdentity,
              icon: const Icon(Icons.verified_user_outlined, size: 20)) : null)),
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
            final status = stopped ? '未启动共享' : connected ? '连接中' : '等待连接';
            return Row(children: [
              Icon(Icons.circle, size: 8, color: stopped ? colors.outline : Colors.green),
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
                Text(host ? '本机设备' : '远程控制',
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
  String _fingerprint = '';

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
      final fingerprint = bind.mainGetOptionSync(key: 'sindre-lan-fingerprint');
      if (mounted && (addresses.join(',') != _addresses.join(',') ||
          fingerprint != _fingerprint)) {
        setState(() { _addresses = addresses; _fingerprint = fingerprint; });
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
        const SizedBox(height: 12),
        if (_fingerprint.isEmpty) const Text('设备指纹将在共享服务启动后显示')
        else _copyable('设备指纹', _fingerprint),
        const SizedBox(height: 8),
        const Text('首次连接请与控制端核对完整指纹。'),
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
        if (widget.host && DesktopAutostart.supported) ...[
          const Divider(height: 24),
          const _DesktopAutostartSwitch(),
        ],
      ],
    )),
    actions: [
      TextButton(onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        child: const Text('取消')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('保存')),
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
