"""源码变换的快速回归测试，不替代跨平台构建。"""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_client", ROOT / "scripts/prepare-client.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareClientTests(unittest.TestCase):
    def test_replace_once(self):
        self.assertEqual(module.replace_once("a b", "a", "c"), "c b")
        for source in ("b", "a a"):
            with self.assertRaises(RuntimeError):
                module.replace_once(source, "a", "c")

    def test_regex_literal(self):
        self.assertEqual(module.replace_regex("a", "^a$", r"$&\\1"), r"$&\\1")

    def test_android_roles(self):
        for role in ("host", "client"):
            text = module.patch_gradle('applicationId "com.carriez.flutter_hbb"', role)
            self.assertIn(f'com.sindre.desk.{role}', text)
            self.assertIn('abiFilters "arm64-v8a"', text)

    def test_native_guard(self):
        source = ('pub fn main_start_service() {\n}\n'
                  '        log::debug!("startService from jvm");\n')
        result = module.patch_android_native(source)
        self.assertEqual(result.count("if config::is_outgoing_only()"), 2)
        self.assertNotIn(r"\n", result)
        self.assertIn("main_start_service() {\n    if", result)

    def test_ui_single_declaration(self):
        text = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertEqual(text.count("class SindreHome extends"), 1)
        self.assertEqual(text.count("bool validServer("), 1)

    def test_signing_properties_escape(self):
        signing_spec = importlib.util.spec_from_file_location(
            "write_android_signing", ROOT / "scripts/write-android-signing.py")
        signing = importlib.util.module_from_spec(signing_spec)
        signing_spec.loader.exec_module(signing)
        self.assertEqual(signing.escape("a b:c=d#e!"), r"a\ b\:c\=d\#e\!")
        self.assertEqual(signing.escape("a\\b"), r"a\\b")
        self.assertEqual(signing.escape("中"), r"\u4e2d")
        self.assertEqual(signing.escape("😀"), r"\ud83d\ude00")

    def test_legacy_host_config_patch(self):
        source = "        Config::with_extension(Self::path(name))"
        result = module.patch_legacy_host_config(source)
        self.assertIn('ProjectDirs::from("", "", "SindreDesk Host")', result)
        self.assertIn("create_new(true)", result)
        self.assertIn("std::fs::hard_link(&tmp, &path)", result)
        self.assertIn("return legacy;", result)
        with self.assertRaises(RuntimeError):
            module.patch_legacy_host_config("")

    def test_desktop_service_scope(self):
        source = (ROOT / "client/flutter/desktop_autostart.dart").read_text()
        self.assertIn("--install-service", source)
        self.assertIn("--uninstall-service", source)
        self.assertNotIn("Startup", source)
        self.assertNotIn("autostart/", source)
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("Random.secure()", ui)
        self.assertIn("List.generate(6,", ui)
        self.assertIn("mainSetPermanentPasswordWithResult", ui)
        self.assertIn("setVerificationMethod(kUsePermanentPassword)", ui)
        self.assertNotIn("kUseTemporaryPassword", ui)
        self.assertNotIn("mainUpdateTemporaryPassword", ui)
        unit = (ROOT / "deploy/sindredesk-host.service").read_text()
        self.assertIn("ExecStart=/usr/lib/sindredesk-host/sindredesk-host --service", unit)

    def test_compact_desktop_home(self):
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("Widget build(BuildContext context)", ui)
        self.assertIn("bottomNavigationBar: host ? SafeArea", ui)
        self.assertIn("const _LanConnectionInfo()", ui)
        self.assertIn("FilteringTextInputFormatter.allow(RegExp(r'[0-9.: ]'))", ui)
        source = (ROOT / "scripts/prepare-client.py").read_text()
        self.assertIn("TitleBarStyle.normal", source)
        self.assertIn("const Size(420, 480)", source)

    def test_host_info_independent_of_server(self):
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("if (host && isAndroid) const _AndroidHostPanel()", ui)
        android = ui.split("class _AndroidHostPanelState", 1)[1].split("class _ServerSettings", 1)[0]
        self.assertNotIn("configured", android)
        self.assertIn("gFFI.serverModel.fetchID();", android)
        self.assertIn("'本机连接码', model.serverId.text", ui)
        self.assertIn("const _FixedPasswordPanel()", ui)
        self.assertNotIn("model.serverPasswd.text", ui)
        self.assertIn("if (!model.isStart) mobile.ServiceNotRunningNotification()", android)
        source = (ROOT / "scripts/prepare-client.py").read_text()
        self.assertNotIn('Secure offline LAN mode is not available', source)
        self.assertIn('sindre_trust::check(peer, &host_key)', source)
        self.assertIn('Some(host_sign_pk)', source)
        self.assertIn('is_private()', source)
        self.assertIn('patch_rendezvous_mediator', source)
        self.assertIn('patch_lan', source)
        self.assertIn('mainDiscover', ui)
        self.assertIn('NetworkInterface.list', ui)
        self.assertIn('Incoming connections require Host role and encryption', source)


    def test_fixed_password_native_cache(self):
        source = ('pub fn main_set_permanent_password_with_result(password: String) -> bool {\n'
                  '    ui_interface::set_permanent_password_with_result(password)\n}\n'
                  'pub fn main_get_common(key: String) -> String {\n}')
        result = module.patch_fixed_password(source)
        self.assertIn('sindre_encrypt_password(&password)', result)
        self.assertIn('sindre_decrypt_password(&cipher)', result)
        self.assertIn('secretbox::gen_nonce()', result)
        self.assertIn('secretbox::seal', result)
        self.assertIn('secretbox::open', result)
        self.assertIn('let (secret, _) = config::Config::get_key_pair()', result)
        self.assertIn('decode_permanent_password_h1_from_storage', result)
        self.assertIn('Ok(Some(value)) if value == "N"', result)
        self.assertIn('return "unavailable".to_owned()', result)
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("state == 'missing'", ui)
        self.assertIn("sindre-fixed-password", ui)
        self.assertIn("state.startsWith('ready:')", ui)

    def test_host_password_policy(self):
        source = ('fn verification_method() -> VerificationMethod {\n}\n'
                  'pub fn approve_mode() -> ApproveMode {\n}\n'
                  'pub fn hide_cm() -> bool {\n}')
        result = module.patch_host_password_policy(source)
        self.assertIn('return VerificationMethod::OnlyUsePermanentPassword;', result)
        self.assertIn('return ApproveMode::Password;', result)
        self.assertIn('return false;', result)

    def test_lan_peer_model_patch(self):
        source = '''class Peer {
  final String id;
  Peer.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? '',
        hash = json['hash'] ?? '';
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      "id": id,
      "hash": hash,
    };
  }
  Peer({
    required this.id,
  });
  bool equal(Peer other) {
    return id == other.id &&
        hash == other.hash;
  }
  factory Peer.copy(Peer other) {
    final peer = Peer(
        id: other.id,
        hash: other.hash);
    return peer;
  }
}'''
        result = module.patch_peer_model(source)
        self.assertIn("final String ip;", result)
        self.assertIn("final String fingerprint;", result)
        self.assertIn("ip = json['ip'] ?? ''", result)
        self.assertIn('"fingerprint": fingerprint', result)
        self.assertIn("ip: other.ip", result)
        self.assertIn("fingerprint == other.fingerprint", result)

    def test_native_lan_security_guards(self):
        source = (ROOT / "scripts/prepare-client.py").read_text()
        self.assertIn("sindre_trust::check(peer, &host_key)", source)
        self.assertIn("Some(host_sign_pk)", source)
        self.assertIn("peer.parse::<SocketAddr>().is_ok()", source)
        self.assertIn("const LAN_DIRECT_PORT: u16", source)
        self.assertIn("let address: SocketAddr = if let Ok(ip) = peer.parse::<std::net::Ipv4Addr>()", source)
        self.assertIn("ip.to_ipv4_mapped()", source)
        self.assertIn("address.port() == LAN_DIRECT_PORT", source)
        self.assertIn("connect_tcp_local(address, None, CONNECT_TIMEOUT)", source)
        self.assertNotIn("connect_tcp_local(&address, None, CONNECT_TIMEOUT)", source)
        self.assertIn("peer_id.parse::<SocketAddr>().is_ok()", source)
        self.assertIn("host_signing_pk.into()", source)
        self.assertIn("IpAddr::V4(ip) if ip.is_private()", source)
        self.assertIn("Config::set_option(OPTION_DIRECT_SERVER.to_owned(),", source)
        self.assertIn('Config::set_option("direct-access-port".to_owned()', source)
        self.assertIn("fingerprint: String::new()", source)
        self.assertNotIn("Secure offline LAN mode is not available", source)

    def test_lan_peer_data_patches(self):
        lan = '''                                    platform: whoami::platform().to_string(),
                                    ..Default::default()
                                    platform: p.platform.clone(),
                                    online: true,'''
        result = module.patch_lan(lan)
        self.assertIn("fingerprint: String::new()", result)
        ui = '''                ("platform", peer.platform.clone()),
            ])'''
        result = module.patch_ui_interface(ui)
        self.assertIn('("ip", peer.ip_mac.keys().next().cloned().unwrap_or_default())', result)
        self.assertIn('("fingerprint", peer.fingerprint.clone())', result)

    def test_desktop_icon_format(self):
        import struct
        png, ico = module.desktop_icon_files()
        self.assertEqual(png[:8], bytes.fromhex("89504e470d0a1a0a"))
        self.assertEqual(struct.unpack_from("<HHH", ico), (0, 1, 7))
        for i in range(7):
            width, height, _, _, planes, depth, size, offset = struct.unpack_from(
                "<BBBBHHII", ico, 6 + i * 16)
            self.assertEqual(width, height)
            self.assertEqual((planes, depth), (1, 32))
            self.assertLessEqual(offset + size, len(ico))
        self.assertEqual(ico[-len(png):], png)

    def test_isolated_lan_and_diagnostics(self):
        self.assertEqual(module.LAN_DIRECT_PORT, 32118)
        self.assertEqual(module.LAN_DISCOVERY_PORT, 32119)
        self.assertIn("SINDRE_LAN_DISCOVERY_PORT", module.patch_lan_ports(
            "config::{self, RENDEZVOUS_PORT},\n(RENDEZVOUS_PORT + 3) as _\n    let socket = std::net::UdpSocket::bind(addr)?;"))
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        self.assertIn("const int _lanDirectPort = 32118", ui)
        self.assertIn("局域网端口不可用", ui)
        source = (ROOT / "scripts/prepare-client.py").read_text()
        self.assertIn("sindre_lan_status", source)
        self.assertIn("lan-tcp-bind-failed", source)
        self.assertIn("lan-invalid-host-identity", source)
        log = (ROOT / "client/native/sindre_diag.rs").read_text()
        self.assertIn("OpenOptions", log)
        workflow = (ROOT / ".github/workflows/client-build-verify.yml").read_text()
        self.assertIn("session-login-rejected", source)
        self.assertIn("lan-identity-timeout", source)
        self.assertIn("sha256sum *.apk *.zip *.tar.gz", workflow)
        self.assertIn("--skip-portable-pack", workflow)
        self.assertIn("runner/Release/", workflow)
        self.assertIn("zip -qr", workflow)
        self.assertNotIn("python generate.py", workflow)
        self.assertNotIn("patch_windows_portable", source)
        self.assertIn("std::env::current_exe()", log)
        self.assertIn("Config::log_path()", log)

    def test_password_only_lan(self):
        ui = (ROOT / "client/flutter/sindre_home.dart").read_text()
        for obsolete in ("validFingerprint", "_confirmIdentity", "_forgetIdentity", "设备指纹"):
            self.assertNotIn(obsolete, ui)
        source = (ROOT / "scripts/prepare-client.py").read_text()
        self.assertIn("sindre_trust::check(peer, &host_key)", source)
        self.assertIn("Some(host_key)", source)
        self.assertIn("Some(login_response::Union::PeerInfo(pi))", source)
        self.assertIn("sindre_trust::remember", source)
        self.assertIn("Some(host_sign_pk)", source)
        self.assertIn("if !conn.is_secured()", source)
        trust = (ROOT / "client/native/sindre_trust.rs").read_text()
        self.assertIn("fs::hard_link(&tmp, &target)", trust)
        self.assertIn("create_new(true)", trust)
        self.assertIn("Ok(saved) if saved == key", trust)
        self.assertNotIn("sindre-lan-peer-fingerprint:", ui)

    def test_workflow_release_only(self):
        paths = sorted((ROOT / ".github/workflows").glob("*.yml"))
        self.assertEqual([p.name for p in paths], ["client-build-verify.yml", "server.yml"])
        for path in paths:
            text = path.read_text()
            self.assertIn("on:\n  release:\n    types: [published]", text)

if __name__ == "__main__":
    unittest.main()
