import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../models/platform_model.dart';
import '../mobile/pages/server_page.dart' as mobile;
import 'lite_config.dart';

/// 只在受信任的 TLS 连接中访问固定设备码服务。
class LiteRegistry {
  HttpClient? _client;
  File? _file;
  String _token = '';
  String code = '';
  String registeredPeer = '';

  Future<void> init() async {
    final dir = await getApplicationSupportDirectory();
    _file = File('${dir.path}/lite_identity.json');
    if (await _file!.exists()) {
      final data = jsonDecode(await _file!.readAsString()) as Map;
      _token = data['token'] as String;
      code = data['code'] as String? ?? '';
      registeredPeer = data['peer'] as String? ?? '';
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(_token)) {
        throw StateError('设备身份损坏');
      }
    } else {
      final random = Random.secure();
      _token = List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await _save();
    }
    final security = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(utf8.encode(liteCertificate));
    _client = HttpClient(context: security)..connectionTimeout = const Duration(seconds: 3);
  }

  Future<void> _save() async {
    final tmp = File('${_file!.path}.tmp');
    await tmp.writeAsString(jsonEncode({'token': _token, 'code': code, 'peer': registeredPeer}), flush: true);
    await tmp.rename(_file!.path);
  }

  Future<Map<String, dynamic>> request(String path, {Map<String, String>? body}) async {
    final uri = Uri.https('$liteServerIp:22120', path);
    final req = await (body == null ? _client!.getUrl(uri) : _client!.postUrl(uri)).timeout(const Duration(seconds: 3));
    req.followRedirects = false;
    if (body != null) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(const Duration(seconds: 3));
    final data = await utf8.decoder.bind(res).join().timeout(const Duration(seconds: 3));
    if (res.statusCode != 200) throw HttpException('设备码服务错误 ${res.statusCode}');
    return jsonDecode(data) as Map<String, dynamic>;
  }

  Future<void> register(String peer) async {
    final result = await request('/v1/register', body: {'rustdesk_id': peer});
    final value = result['code'] as String;
    if (!RegExp(r'^\d{4}$').hasMatch(value) || result['rustdesk_id'] != peer) {
      throw StateError('设备注册响应无效');
    }
    if (code.isNotEmpty && (code != value || registeredPeer != peer)) {
      throw StateError('设备身份发生变化');
    }
    code = value;
    registeredPeer = peer;
    await _save();
  }

  Future<String> lookup(String other) async {
    final res = await request('/v1/lookup', body: {'code': other});
    final peer = res['rustdesk_id'] as String;
    if (res['code'] != other || !RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(peer)) {
      throw StateError('设备查询响应无效');
    }
    return peer;
  }

  void close() => _client?.close(force: true);
}

class LiteHome extends StatefulWidget {
  const LiteHome({super.key});
  @override
  State<LiteHome> createState() => _LiteHomeState();
}

class _LiteHomeState extends State<LiteHome> with WidgetsBindingObserver {
  final registry = LiteRegistry();
  final input = TextEditingController();
  Timer? _timer;
  bool _ready = false, _online = false, _polling = false, _registered = false, _busy = false;
  bool _connecting = true;
  int _tab = 0;
  DateTime? _lastRegister;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    gFFI.serverModel.addListener(_changed);
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await registry.init();
      if (!mounted) return;
      _ready = true;
      mobile.checkService();
      await _poll();
      if (!mounted) return;
      _timer = Timer.periodic(const Duration(seconds: 5), (_) => unawaited(_poll()));
    } catch (_) {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _changed() { if (mounted) setState(() {}); }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      mobile.checkService();
      unawaited(_poll());
    }
  }

  Future<void> _poll() async {
    if (!_ready || _polling || !mounted) return;
    _polling = true;
    try {
      final health = await registry.request('/health');
      if (health['status'] != 'online' || health['service'] != 'sindredesk-lite') {
        throw StateError('服务不可用');
      }
      final peer = await bind.mainGetMyId();
      if (!RegExp(r'^[A-Za-z0-9_-]{6,64}$').hasMatch(peer)) {
        throw StateError('设备初始化中');
      }
      final now = DateTime.now();
      if (!_registered || _lastRegister == null || now.difference(_lastRegister!) >= const Duration(minutes: 1)) {
        await registry.register(peer);
        _registered = true;
        _lastRegister = now;
      }
      if (peer != registry.registeredPeer) throw StateError('设备身份发生变化');
      if (mounted) setState(() { _online = true; _connecting = false; });
    } catch (_) {
      _registered = false;
      if (mounted) setState(() { _online = false; _connecting = false; });
    } finally { _polling = false; }
  }

  void _hint(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _share() async {
    final model = gFFI.serverModel;
    if (_busy || !_online) return;
    setState(() => _busy = true);
    try {
      if (!model.isStart) {
        await model.checkRequestNotificationPermission();
        await model.checkFloatingWindowPermission();
        await bind.mainSetOption(key: 'approve-mode', value: 'click');
        await bind.mainSetOption(key: 'enable-file-transfer', value: 'N');
        await bind.mainSetOption(key: 'enable-audio', value: 'N');
        await model.startService();
      }
      if (!model.inputOk) await model.toggleInput();
    } catch (_) { _hint('请检查手机授权'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  Future<void> _end() async {
    // 无二次确认：直接请求原生会话关闭和屏幕共享停止。
    final model = gFFI.serverModel;
    try {
      await model.stopService();
      await model.closeAll();
    } catch (_) { _hint('请从系统通知栏停止屏幕共享'); }
    if (mounted) setState(() => _tab = 0);
  }

  Future<void> _connect() async {
    final code = input.text;
    if (_busy || !_online || !RegExp(r'^\d{4}$').hasMatch(code) || code == registry.code) return;
    setState(() => _busy = true);
    try {
      final peer = await registry.lookup(code);
      if (!mounted) return;
      FocusScope.of(context).unfocus();
      // 四位码只查找目标，不传入远控密码；每次连接由对方点击确认。
      await connect(context, peer);
    } catch (_) { _hint('连接失败，请核对对方验证码'); }
    finally { if (mounted) setState(() => _busy = false); }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    gFFI.serverModel.removeListener(_changed);
    _timer?.cancel();
    registry.close();
    input.dispose();
    super.dispose();
  }

  Widget _button(String label, VoidCallback? onPressed, {bool danger = false}) =>
    FilledButton(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(72),
        backgroundColor: danger ? Colors.red.shade700 : Colors.blue.shade700,
        textStyle: const TextStyle(fontSize: 25, fontWeight: FontWeight.w600)),
      onPressed: onPressed, child: Text(label));

  @override
  Widget build(BuildContext context) {
    final model = gFFI.serverModel;
    final active = model.clients.any((c) => c.authorized && !c.disconnected);
    final pending = model.clients.any((c) => !c.authorized && !c.disconnected);
    final status = _connecting ? '连接中' : _online ? '在线' : '离线';
    final color = _connecting ? Colors.orange : _online ? Colors.green : Colors.red;
    return Scaffold(
      appBar: AppBar(title: const Text('远程协助'), centerTitle: true, automaticallyImplyLeading: false),
      body: SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(
        children: [
          if (!active && !pending)
            Row(children: [
              Expanded(child: _tab == 0 ? FilledButton(onPressed: () {}, child: const Text('被控', style: TextStyle(fontSize: 24))) :
                OutlinedButton(onPressed: () => setState(() => _tab = 0), child: const Text('被控', style: TextStyle(fontSize: 24)))),
              const SizedBox(width: 8),
              Expanded(child: _tab == 1 ? FilledButton(onPressed: () {}, child: const Text('控制', style: TextStyle(fontSize: 24))) :
                OutlinedButton(onPressed: () => setState(() => _tab = 1), child: const Text('控制', style: TextStyle(fontSize: 24)))),
            ]),
          Expanded(child: Center(child: SingleChildScrollView(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (active || pending) ...[
              Text(active ? '正在被远程控制' : '等待您确认连接', style: const TextStyle(fontSize: 28), textAlign: TextAlign.center),
              const SizedBox(height: 32),
              _button('强制结束', () => unawaited(_end()), danger: true),
            ] else if (_tab == 0) ...[
              const Text('我的验证码', style: TextStyle(fontSize: 24)),
              FittedBox(child: Text(registry.code.isEmpty ? '----' : registry.code, style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold, color: Colors.blue))),
              const Text('请将验证码告诉家人', style: TextStyle(fontSize: 20), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              if (!model.isStart || !model.inputOk || !model.mediaOk)
                _button('开启远程协助', _online && !_busy ? () => unawaited(_share()) : null)
              else ...[
                const Text('等待远程协助', style: TextStyle(fontSize: 24, color: Colors.green)),
                const SizedBox(height: 24),
                _button('停止共享', () => unawaited(_end()), danger: true),
              ],
            ] else ...[
              const Text('对方的验证码', style: TextStyle(fontSize: 24)),
              TextField(controller: input, keyboardType: TextInputType.number, maxLength: 4,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly], textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 56, letterSpacing: 8),
                decoration: const InputDecoration(counterText: '', hintText: '----'), onChanged: (_) => setState(() {})),
              const SizedBox(height: 24),
              _button('开始控制', _online && !_busy && input.text.length == 4 && input.text != registry.code ? () => unawaited(_connect()) : null),
            ],
          ])))),
          Align(alignment: Alignment.bottomRight, child: Text('$liteServerIp · $status', style: TextStyle(fontSize: 10, color: color))),
        ],
      ))),
    );
  }
}
