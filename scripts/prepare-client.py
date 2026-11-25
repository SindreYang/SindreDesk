"""从固定上游源码生成独立角色工作树；不直接修改上游仓库。"""
import argparse
import re
import struct
import zlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = "https://github.com/rustdesk/rustdesk.git"
REVISION = "6c578292e8ebbbec708b76986ba8c4bc7c509747"


def git(path, *args):
    subprocess.run(["git", "-C", str(path), *args], check=True)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"上游匹配失败: {old[:100]!r}")
    return text.replace(old, new, 1)


def replace_regex(text, pattern, replacement):
    text, count = re.subn(pattern, lambda _: replacement, text, flags=re.M | re.S)
    if count != 1:
        raise RuntimeError(f"上游函数匹配失败: {pattern!r}, count={count}")
    return text


def patch(path, transform):
    text = path.read_text(encoding="utf-8")
    path.write_text(transform(text), encoding="utf-8")


def patch_config(text, role):
    host = role == "host"
    name = "SindreDesk Host" if host else "SindreDesk Client"
    for function, value in [
        ("is_incoming_only", host),
        ("is_outgoing_only", not host),
        ("is_disable_ab", True),
        ("is_disable_account", True),
    ]:
        text = replace_regex(text, rf"^pub fn {function}\(\) -> bool \{{\n.*?^\}}",
                             f"pub fn {function}() -> bool {{\n    {str(value).lower()}\n}}")
    # Desktop Host native service/process names must match actual executable names.
    app_name = ('''    pub static ref APP_NAME: RwLock<String> = RwLock::new(
        (if cfg!(target_os = "windows") { "SindreDeskHost" }
        else if cfg!(target_os = "linux") { "sindredesk-host" }
        else { "SindreDesk Host" }).to_owned());''' if host else
        f'    pub static ref APP_NAME: RwLock<String> = RwLock::new("{name}".to_owned());')
    text = replace_regex(text,
        r'^    pub static ref APP_NAME: RwLock<String> = [^;]+;', app_name)
    if host:
        text = patch_legacy_host_config(text)
    # 禁止旧配置、EXE 文件名及公共服务器自动回退；空配置仅使用不可用的本地端口。
    text = replace_regex(text,
        r'^    pub fn get_rendezvous_server\(\) -> String \{\n.*?^    \}',
        '''    pub fn get_rendezvous_server() -> String {
        let server = Self::get_option("custom-rendezvous-server");
        let key = Self::get_option("key");
        if server.trim().is_empty() || key.trim().is_empty()
            || server.to_ascii_lowercase().contains("rustdesk.com") {
            return "127.0.0.1:0".to_owned();
        }
        if server.contains(':') { server } else { format!("{server}:{RENDEZVOUS_PORT}") }
    }''')
    text = replace_regex(text,
        r'^    pub fn get_rendezvous_servers\(\) -> Vec<String> \{\n.*?^    \}',
        '''    pub fn get_rendezvous_servers() -> Vec<String> {
        vec![Self::get_rendezvous_server()]
    }''')
    text = replace_regex(text, r'^pub const RENDEZVOUS_SERVERS: &\[&str\] = [^;]+;',
                         'pub const RENDEZVOUS_SERVERS: &[&str] = &["127.0.0.1:0"];')
    text = replace_once(text, "pub struct DiscoveryPeer {",
        'pub struct DiscoveryPeer {\n    #[serde(default, deserialize_with = "deserialize_string")]\n    pub fingerprint: String,')
    return text


def patch_legacy_host_config(text):
    # Migrate only the two native configuration files in the current account.
    # The old files remain untouched, and a new existing config is never overwritten.
    return replace_once(text,
        '        Config::with_extension(Self::path(name))',
        '''        let path = Config::with_extension(Self::path(name));
        #[cfg(any(target_os = "windows", target_os = "linux"))]
        if (suffix.is_empty() || suffix == "2") && !path.exists() {
            if let Some(project) = directories_next::ProjectDirs::from("", "", "SindreDesk Host") {
                let legacy = Config::with_extension(
                    patch(project.config_dir().to_path_buf()).join(format!("SindreDesk Host{suffix}"))
                );
                if legacy != path && std::fs::symlink_metadata(&legacy)
                    .map(|m| m.file_type().is_file()).unwrap_or(false) {
                    if let Some(parent) = path.parent() {
                        let tmp = parent.join(format!(".sindre-migrate-{:016x}", rand::random::<u64>()));
                        let result = (|| -> std::io::Result<()> {
                            std::fs::create_dir_all(parent)?;
                            let mut options = std::fs::OpenOptions::new();
                            options.write(true).create_new(true);
                            #[cfg(unix)]
                            {
                                use std::os::unix::fs::OpenOptionsExt;
                                options.mode(0o600);
                            }
                            let mut output = options.open(&tmp)?;
                            let copied = (|| -> std::io::Result<()> {
                                std::io::copy(&mut std::fs::File::open(&legacy)?, &mut output)?;
                                output.sync_all()?;
                                Ok(())
                            })();
                            drop(output);
                            let linked = copied.and_then(|_| std::fs::hard_link(&tmp, &path));
                            let _ = std::fs::remove_file(&tmp);
                            linked
                        })();
                        if result.is_err() && !path.exists() {
                            // Do not lose the old machine identity when migration fails.
                            log::warn!("SindreDesk Host config migration deferred");
                            return legacy;
                        }
                    }
                }
            }
        }
        path''')


def patch_fixed_password(text):
    text = replace_once(text,
        'pub fn main_set_permanent_password_with_result(password: String) -> bool {\n    ui_interface::set_permanent_password_with_result(password)\n}',
        '''fn sindre_password_state() -> String {
    if !config::is_incoming_only() {
        return "unavailable".to_owned();
    }
    // A failed desktop IPC query is not evidence that the password is unset.
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        match crate::ipc::get_config("permanent-password-set") {
            Ok(Some(value)) if value == "N" => return "missing".to_owned(),
            Ok(Some(value)) if value == "Y" => {},
            _ => return "unavailable".to_owned(),
        }
        if crate::ipc::sync_permanent_password_storage_from_daemon().is_err() {
            return "unavailable".to_owned();
        }
    }
    #[cfg(any(target_os = "android", target_os = "ios"))]
    if !config::Config::has_permanent_password() {
        return "missing".to_owned();
    }
    let cached = LocalConfig::get_option("sindre-fixed-password-encrypted");
    let Ok(cipher) = hbb_common::base64::decode(cached, hbb_common::base64::Variant::Original) else {
        return "legacy".to_owned();
    };
    let Ok(plain) = hbb_common::password_security::symmetric_crypt(&cipher, false) else {
        return "legacy".to_owned();
    };
    let Ok(password) = String::from_utf8(plain) else {
        return "legacy".to_owned();
    };
    let (storage, salt) = config::Config::get_local_permanent_password_storage_and_salt();
    if !salt.is_empty() && config::decode_permanent_password_h1_from_storage(&storage)
        == Some(config::compute_permanent_password_h1(&password, &salt)) {
        return format!("ready:{}", password);
    }
    "legacy".to_owned()
}

pub fn main_set_permanent_password_with_result(password: String) -> bool {
    if !config::is_incoming_only() || password.is_empty() {
        return false;
    }
    // Only the local GUI cache is reversible; native authentication keeps its salted hash.
    // Encryption failure must not silently fall back to plaintext.
    let Ok(cipher) = hbb_common::password_security::symmetric_crypt(password.as_bytes(), true) else {
        return false;
    };
    let encoded = hbb_common::base64::encode(cipher, hbb_common::base64::Variant::Original);
    if !ui_interface::set_permanent_password_with_result(password) {
        return false;
    }
    LocalConfig::set_option("sindre-fixed-password-encrypted".to_owned(), encoded.clone());
    LocalConfig::get_option_from_file("sindre-fixed-password-encrypted") == encoded
}''')
    return replace_once(text, 'pub fn main_get_common(key: String) -> String {',
        '''pub fn main_get_common(key: String) -> String {
    if key == "sindre-fixed-password" {
        return sindre_password_state();
    }''')


def patch_client(text):
    text = replace_once(text, '    net::SocketAddr,', '    net::{IpAddr, SocketAddr},')
    text = replace_once(text,
        '        if config::is_incoming_only() {\n            bail!("Incoming only mode");\n        }\n        // to-do: remember the port for each peer, so that we can retry easier\n        if hbb_common::is_ip_str(peer) {\n            return Ok((\n                (\n                    connect_tcp_local(check_port(peer, RELAY_PORT + 1), None, CONNECT_TIMEOUT)\n                        .await?,\n                    true,\n                    None,\n                    None,\n                    "TCP",\n                ),\n                (0, "".to_owned()),\n                false,\n            ));\n        }\n        // Allow connect to {domain}:{port}\n        if hbb_common::is_domain_port_str(peer) {\n            return Ok((\n                (\n                    connect_tcp_local(peer, None, CONNECT_TIMEOUT).await?,\n                    true,\n                    None,\n                    None,\n                    "TCP",\n                ),\n                (0, "".to_owned()),\n                false,\n            ));\n        }',
        '''        if config::is_incoming_only() {
            bail!("Incoming only mode");
        }
        // Serverless LAN connections are private-IPv4 only. The user must compare
        // the host's SHA-256 signing-key fingerprint before the encrypted handshake.
        if hbb_common::is_ip_str(peer) || peer.parse::<SocketAddr>().is_ok() {
            // Keep the destination as a resolved SocketAddr: the socket API
            // accepts this type directly and SocketAddr::port() returns u16.
            const LAN_DIRECT_PORT: u16 = (RELAY_PORT + 1) as u16;
            let address: SocketAddr = if hbb_common::is_ip_str(peer) {
                let ip: std::net::Ipv4Addr = peer
                    .parse()
                    .map_err(|_| anyhow!("LAN direct access requires IPv4"))?;
                SocketAddr::new(IpAddr::V4(ip), LAN_DIRECT_PORT)
            } else {
                peer.parse()
                    .map_err(|_| anyhow!("LAN direct access requires an IPv4 address and port"))?
            };
            match address.ip() {
                IpAddr::V4(ip) if ip.is_private() && address.port() == LAN_DIRECT_PORT => {}
                _ => bail!("LAN direct access requires private IPv4 and port {}", LAN_DIRECT_PORT),
            }
            let option = format!("sindre-lan-peer-fingerprint:{}", peer);
            let expected_fingerprint = Config::get_option(&option);
            if expected_fingerprint.len() != 64
                || !expected_fingerprint.bytes().all(|b| b.is_ascii_hexdigit())
            {
                bail!("Enter the 64-character device fingerprint shown on the Host");
            }
            let mut conn = connect_tcp_local(address, None, CONNECT_TIMEOUT).await?;
            let bytes = timeout(READ_TIMEOUT, conn.next())
                .await?
                .ok_or_else(|| anyhow!("LAN host closed before identity exchange"))??;
            let identity = Message::parse_from_bytes(&bytes)?;
            let host_sign_pk = match identity.union {
                Some(message::Union::PublicKey(pk))
                    if pk.symmetric_value.is_empty()
                        && pk.asymmetric_value.len() == sign::PUBLICKEYBYTES =>
                {
                    sign::PublicKey(
                        pk.asymmetric_value
                            .as_ref()
                            .try_into()
                            .map_err(|_| anyhow!("Invalid LAN host signing key"))?,
                    )
                }
                _ => bail!("Invalid LAN host identity response"),
            };
            let actual_fingerprint = Sha256::digest(&host_sign_pk.0)
                .iter()
                .map(|byte| format!("{:02x}", byte))
                .collect::<String>();
            if !actual_fingerprint.eq_ignore_ascii_case(&expected_fingerprint) {
                bail!("LAN device fingerprint mismatch; compare it with the Host screen");
            }
            Self::secure_connection(peer, Vec::new(), "", &mut conn, Some(host_sign_pk)).await?;
            if !conn.is_secured() {
                bail!("LAN connection did not establish encryption");
            }
            return Ok(((conn, true, None, None, "TCP"), (0, "".to_owned()), false));
        }
        if Config::get_option("custom-rendezvous-server").trim().is_empty()
            || key.is_empty()
            || get_rs_pk(key).is_none()
        {
            bail!("Configure the private server and valid public key for connection-code access");
        }''')
    text = replace_once(text,
        '        let res = Self::secure_connection(peer_id, signed_id_pk, key, &mut conn).await;',
        '        let res = Self::secure_connection(peer_id, signed_id_pk, key, &mut conn, None).await;')
    text = replace_once(text,
        '                            Self::secure_connection(&peer, signed_id_pk, &key, &mut conn).await?;',
        '                            Self::secure_connection(&peer, signed_id_pk, &key, &mut conn, None).await?;')
    text = replace_once(text,
        '''        key: &str,
        conn: &mut Stream,
    ) -> ResultType<Option<Vec<u8>>> {
        let rs_pk''',
        '''        key: &str,
        conn: &mut Stream,
        trusted_peer_pk: Option<sign::PublicKey>,
    ) -> ResultType<Option<Vec<u8>>> {
        let rs_pk''')
    text = replace_once(text, '        let mut sign_pk = None;\n        let mut option_pk = None;\n        if !signed_id_pk.is_empty() {',
        '        let mut sign_pk = trusted_peer_pk;\n        let mut option_pk = None;\n        if sign_pk.is_none() && !signed_id_pk.is_empty() {')
    text = replace_once(text,
        '''                        if let Ok((id, their_pk_b)) = decode_id_pk(&si.id, &sign_pk) {
                            if id == peer_id {''',
        '''                        if let Ok((id, their_pk_b)) = decode_id_pk(&si.id, &sign_pk) {
                            if id == peer_id
                                || hbb_common::is_ip_str(peer_id)
                                || peer_id.parse::<SocketAddr>().is_ok()
                            {''')
    text = replace_once(text,
        '        let other_server = interface.get_lch().read().unwrap().other_server.clone();',
        '''        let other_server = interface.get_lch().read().unwrap().other_server.clone();
        if other_server.is_some() {
            bail!("Alternate rendezvous servers are disabled");
        }''')
    text = replace_once(text, '        Ok(option_pk)\n    }',
        '''        if !conn.is_secured() {
            bail!("Encrypted peer handshake is required");
        }
        Ok(option_pk)
    }''')
    text = replace_once(text,
        '''                // send an empty message out in case server is setting up secure and waiting for first message
                conn.send(&Message::new()).await?;
                return Ok(option_pk);''',
        '''                bail!("Invalid or missing peer identity signature");''')
    return text

def patch_rendezvous_mediator(text):
    text = replace_once(text, '    net::SocketAddr,', '    net::{IpAddr, SocketAddr},')
    text = replace_once(text,
        '''        if config::is_outgoing_only() {
            loop {
                sleep(1.).await;
            }
        }''',
        '''        if config::is_outgoing_only() {
            loop {
                sleep(1.).await;
            }
        }
        // Host-only: publish a stable device-key fingerprint and enable local discovery.
        use hbb_common::sha2::Digest;
        let (_, host_signing_pk) = Config::get_key_pair();
        let fingerprint = hbb_common::sha2::Sha256::digest(&host_signing_pk)
            .iter()
            .map(|byte| format!("{:02x}", byte))
            .collect::<String>();
        Config::set_option("sindre-lan-fingerprint".to_owned(), fingerprint);
        Config::set_option("enable-lan-discovery".to_owned(), "Y".to_owned());
        Config::set_option(OPTION_DIRECT_SERVER.to_owned(), "Y".to_owned());
        Config::set_option("direct-access-port".to_owned(), (RENDEZVOUS_PORT + 2).to_string());''')
    text = replace_once(text,
        '''        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let start_lan_listening = crate::platform::is_installed();''',
        '''        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let start_lan_listening = true;''')
    text = replace_once(text,
        '''            if let Ok(Ok((stream, addr))) = hbb_common::timeout(1000, l.accept()).await {
                stream.set_nodelay(true).ok();''',
        '''            if let Ok(Ok((stream, addr))) = hbb_common::timeout(1000, l.accept()).await {
                if !matches!(addr.ip(), IpAddr::V4(ip) if ip.is_private()) {
                    log::warn!("Reject non-private direct connection from {}", addr);
                    continue;
                }
                stream.set_nodelay(true).ok();''')
    text = replace_once(text,
        '''                tokio::spawn(async move {
                    allow_err!(
                        crate::server::create_tcp_connection(
                            server,
                            hbb_common::Stream::from(stream, local_addr),
                            addr,
                            false,
                            ConnectionMeta::default(), // Direct connections don't have server-side user context.
                        )
                        .await
                    );
                });''',
        '''                tokio::spawn(async move {
                    let mut stream = hbb_common::Stream::from(stream, local_addr);
                    let (_, host_signing_pk) = Config::get_key_pair();
                    let mut identity = hbb_common::message_proto::Message::new();
                    identity.set_public_key(hbb_common::message_proto::PublicKey {
                        asymmetric_value: host_signing_pk.into(),
                        ..Default::default()
                    });
                    allow_err!(async {
                        // Send the host signing key first so the client can verify its fingerprint.
                        stream.send(&identity).await?;
                        crate::server::create_tcp_connection(
                            server,
                            stream,
                            addr,
                            true,
                            ConnectionMeta::default(), // Direct connections don't have server-side user context.
                        )
                        .await
                    }.await);
                });''')
    return text


def patch_lan(text):
    text = replace_once(text,
        '''                                    platform: whoami::platform().to_string(),
                                    ..Default::default()''',
        '''                                    platform: whoami::platform().to_string(),
                                    misc: Config::get_option("sindre-lan-fingerprint"),
                                    ..Default::default()''')
    return replace_once(text,
        '''                                    platform: p.platform.clone(),
                                    online: true,''',
        '''                                    platform: p.platform.clone(),
                                    fingerprint: p.misc.clone(),
                                    online: true,''')
    

def patch_ui_interface(text):
    return replace_once(text,
        '''                ("platform", peer.platform.clone()),
            ])''',
        '''                ("platform", peer.platform.clone()),
                ("ip", peer.ip_mac.keys().next().cloned().unwrap_or_default()),
                ("fingerprint", peer.fingerprint.clone()),
            ])''')


def patch_peer_model(text):
    text = replace_once(text, '  final String id;\n', '  final String id;\n  final String ip;\n  final String fingerprint;\n')
    text = replace_once(text, "      : id = json['id'] ?? '',\n", "      : id = json['id'] ?? '',\n        ip = json['ip'] ?? '',\n        fingerprint = json['fingerprint'] ?? '',\n")
    text = replace_once(text,
        '''    return <String, dynamic>{
      "id": id,
      "hash": hash,''',
        '''    return <String, dynamic>{
      "id": id,
      "ip": ip,
      "fingerprint": fingerprint,
      "hash": hash,''')
    text = replace_once(text, '    required this.id,\n', "    required this.id,\n    this.ip = '',\n    this.fingerprint = '',\n")
    text = replace_once(text, '    return id == other.id &&\n', '    return id == other.id &&\n        ip == other.ip &&\n        fingerprint == other.fingerprint &&\n')
    return replace_once(text, '        id: other.id,\n', '        id: other.id,\n        ip: other.ip,\n        fingerprint: other.fingerprint,\n')


def patch_common(text):
    text = replace_regex(text, r'^pub fn get_api_server\(api: String, custom: String\) -> String \{\n.*?^\}',
                         'pub fn get_api_server(_api: String, _custom: String) -> String {\n    String::new()\n}')
    # 固定服务端配置，不读取 EXE 文件名中的旧许可证地址。
    text = replace_regex(text, r'^pub fn get_custom_rendezvous_server\(custom: String\) -> String \{\n.*?^\}',
                         'pub fn get_custom_rendezvous_server(custom: String) -> String {\n    custom\n}')
    return text


def patch_main(text):
    text = replace_once(text, 'import \'common.dart\';',
                        'import \'common.dart\';\nimport \'sindre/sindre_home.dart\';')
    text = replace_once(text, '  debugPrint("launch args: $args");\n', '')
    text = text.replace('  checkUpdate();\n', '')
    text = text.replace('  gFFI.userModel.refreshCurrentUser();\n', '')
    text = text.replace('  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);\n', '')
    text = replace_once(text, '  if (startService) {', '  if (startService && !bind.isOutgoingOnly()) {')
    text = replace_once(text, ': HomePage(),', ': const SindreHome(),')
    text = replace_once(text,
        '''  WindowOptions windowOptions = getHiddenTitleBarWindowOptions(
      isMainWindow: true, alwaysOnTop: alwaysOnTop);''',
        '''  final host = bind.isIncomingOnly();
  final windowOptions = WindowOptions(
    size: host ? const Size(420, 480) : const Size(420, 480),
    minimumSize: const Size(360, 320),
    center: true,
    alwaysOnTop: alwaysOnTop,
    titleBarStyle: TitleBarStyle.normal,
    title: host ? 'SindreDesk Host' : 'SindreDesk Client',
  );''')
    text = replace_once(text, '    await restoreWindowPosition(WindowType.Main);',
        '    // Compact main window: do not restore obsolete oversized bounds.\n    await windowManager.center();')
    text = replace_once(text, '    windowManager.setTitle(getWindowName());',
        "    windowManager.setTitle(host ? 'SindreDesk Host' : 'SindreDesk Client');")
    text = replace_once(text, '    setResizable(!bind.isIncomingOnly());', '    setResizable(true);')
    return text


def patch_desktop_tab(text):
    text = "import '../../sindre/sindre_home.dart';\n" + text
    text = replace_once(text, 'page: DesktopHomePage(', 'page: const SindreHome(')
    text = replace_once(text, 'offstage: bind.isIncomingOnly() || bind.isDisableSettings(),', 'offstage: true,')
    text = replace_once(text, 'windowManager.setSize(getIncomingOnlyHomeSize());\n          setResizable(false);',
        'windowManager.setSize(const Size(420, 480));\n          setResizable(true);')
    return text


def patch_gradle(text, role):
    text = replace_once(text, 'applicationId "com.carriez.flutter_hbb"',
                        f'applicationId "com.sindre.desk.{role}"\n        ndk {{ abiFilters "arm64-v8a" }}')
    return text


def icon_rgba(size):
    """SindreDesk: blue rounded square, white monitor and connection arrow."""
    def sample(x, y):
        # Supersampled geometric drawing; independent of OS fonts and image libraries.
        dx = max(abs(x - 0.5) - 0.32, 0)
        dy = max(abs(y - 0.5) - 0.32, 0)
        if dx * dx + dy * dy > 0.13 ** 2:
            return (0, 0, 0, 0)
        blue = (22, 104, 211, 255)
        white = (255, 255, 255, 255)
        screen = 0.22 <= x <= 0.78 and 0.24 <= y <= 0.65
        edge = screen and (x < 0.29 or x > 0.71 or y < 0.31 or y > 0.58)
        stand = 0.465 <= x <= 0.535 and 0.65 <= y <= 0.76
        base = 0.34 <= x <= 0.66 and 0.74 <= y <= 0.80
        arrow = (0.36 <= x <= 0.63 and 0.415 <= y <= 0.475) or (
            0.50 <= x <= 0.65 and abs(abs(y - 0.445) - (0.65 - x)) <= 0.035)
        return white if edge or stand or base or arrow else blue

    pixels = bytearray()
    for y in range(size):
        for x in range(size):
            samples = [sample((x + (i + 0.5) / 4) / size,
                              (y + (j + 0.5) / 4) / size)
                       for i in range(4) for j in range(4)]
            alpha = sum(p[3] for p in samples)
            if alpha:
                pixels.extend([sum(p[c] * p[3] for p in samples) // alpha
                               for c in range(3)] + [round(alpha / 16)])
            else:
                pixels.extend((0, 0, 0, 0))
    return bytes(pixels)


def icon_png(size, rgba):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data +
                struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    rows = b"".join(b"\0" + rgba[y * size * 4:(y + 1) * size * 4]
                    for y in range(size))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def icon_dib(size, rgba):
    stride = ((size + 31) // 32) * 4
    pixels, mask = bytearray(), bytearray()
    for y in reversed(range(size)):
        row = bytearray(stride)
        for x in range(size):
            r, g, b, a = rgba[(y * size + x) * 4:(y * size + x + 1) * 4]
            pixels.extend((b, g, r, a))
            if a == 0:
                row[x // 8] |= 0x80 >> (x % 8)
        mask.extend(row)
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32,
                         0, len(pixels) + len(mask), 0, 0, 0, 0)
    return header + pixels + mask


def desktop_icon_files():
    sizes = (16, 24, 32, 48, 64, 128, 256)
    data = [(size, icon_rgba(size)) for size in sizes]
    png = icon_png(256, data[-1][1])
    payloads = [icon_dib(size, rgba) if size < 256 else png
                for size, rgba in data]
    offset = 6 + 16 * len(sizes)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(sizes)))
    for size, payload in zip(sizes, payloads):
        directory.extend(struct.pack("<BBBBHHII", size % 256, size % 256,
                                     0, 0, 1, 32, len(payload), offset))
        offset += len(payload)
    return png, bytes(directory) + b"".join(payloads)


def patch_desktop_icons(source, role):
    png, ico = desktop_icon_files()
    assets = source / "flutter/assets"
    (assets / "sindredesk_icon.png").write_bytes(png)
    (assets / "sindredesk_icon.ico").write_bytes(ico)
    # Windows resource icon and runtime icon use the same original artwork.
    (source / "flutter/windows/runner/resources/app_icon.ico").write_bytes(ico)
    windows = source / "flutter/windows/runner/win32_window.cpp"
    patch(windows, lambda s: replace_once(s,
        r'icon_path += L"data\\flutter_assets\\assets\\icon.ico";',
        r'icon_path += L"data\\flutter_assets\\assets\\sindredesk_icon.ico";'))
    patch(source / "src/platform/windows.rs", lambda s: replace_once(s,
        r'const RELATIVE_ICON_PATH: &str = "data\\flutter_assets\\assets\\icon.ico";',
        r'const RELATIVE_ICON_PATH: &str = "data\\flutter_assets\\assets\\sindredesk_icon.ico";'))
    rc = source / "flutter/windows/runner/Runner.rc"
    def resource_metadata(s):
        for key, old, new in [
            ("FileDescription", "RustDesk Remote Desktop", "SindreDesk " + role.title()),
            ("OriginalFilename", "rustdesk.exe", "SindreDesk" + role.title() + ".exe"),
            ("ProductName", "RustDesk", "SindreDesk"),
        ]:
            s = replace_once(s, f'VALUE "{key}", "{old}"', f'VALUE "{key}", "{new}"')
        return s
    patch(rc, resource_metadata)
    linux = source / "flutter/linux/my_application.cc"
    patch(linux, lambda s: replace_regex(s,
        r'  // try setting icon for rustdesk, which uses the system cache\n.*?^  // Use a header bar',
        '''  // Use the bundled SindreDesk icon, not the installed RustDesk icon theme.
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", NULL);
  if (executable != NULL) {
    g_autofree gchar* directory = g_path_get_dirname(executable);
    g_autofree gchar* icon_path = g_build_filename(directory, "data", "flutter_assets",
        "assets", "sindredesk_icon.png", NULL);
    gtk_window_set_icon_from_file(window, icon_path, NULL);
  }
  // Use a header bar'''))
    patch(source / "flutter/lib/common.dart", lambda s: replace_once(s,
        "return Image.asset('assets/icon.png',",
        "return Image.asset(isDesktop ? 'assets/sindredesk_icon.png' : 'assets/icon.png',"))
    patch(source / "flutter/lib/desktop/widgets/tabbar_widget.dart", lambda s: replace_once(s,
        '"RustDesk",\n                              style: TextStyle(fontSize: 13),',
        '"SindreDesk",\n                              style: TextStyle(fontSize: 13),'))


def patch_desktop_branding(source, role):
    suffix = role
    display = "SindreDesk " + role.title()
    linux = source / "flutter/linux/CMakeLists.txt"
    patch(linux, lambda s: replace_once(
        replace_once(s, 'set(BINARY_NAME "rustdesk")',
                     f'set(BINARY_NAME "sindredesk-{suffix}")'),
        'set(APPLICATION_ID "com.carriez.flutter_hbb")',
        f'set(APPLICATION_ID "com.sindre.desk.{suffix}")'))
    windows = source / "flutter/windows/CMakeLists.txt"
    patch(windows, lambda s: replace_once(
        s, 'set(BINARY_NAME "rustdesk")',
        f'set(BINARY_NAME "SindreDesk{role.title()}")'))
    manifest = source / "flutter/android/app/src/main/AndroidManifest.xml"
    patch(manifest, lambda s: s.replace(
        'android:label="RustDesk"', f'android:label="{display}"'
    ).replace('android:label="RustDesk Input"', f'android:label="{display} Input"'))
    kotlin = source / "flutter/android/app/src/main/kotlin"
    for path in kotlin.rglob("*.kt"):
        text = path.read_text(encoding="utf-8")
        text = text.replace('"RustDesk"', f'"{display}"')
        path.write_text(text, encoding="utf-8")
    strings = source / "flutter/android/app/src/main/res/values/strings.xml"
    if strings.exists():
        patch(strings, lambda s: s.replace("RustDesk", display))


def patch_android_native(text):
    """禁止控制端通过 Flutter FFI 或 JNI 启动被控服务。"""
    text = replace_once(text, 'pub fn main_start_service() {',
        'pub fn main_start_service() {\n    if config::is_outgoing_only() { return; }')
    return replace_once(text, '        log::debug!("startService from jvm");',
        '        if config::is_outgoing_only() { return; }\n        log::debug!("startService from jvm");')


def prepare(source, role):
    patch(source / "libs/hbb_common/src/config.rs", lambda s: patch_config(s, role))
    patch(source / "src/client.rs", patch_client)
    patch(source / "src/common.rs", patch_common)
    if role == "host":
        # Do not discover or reuse a legacy RustDesk installation.
        patch(source / "src/platform/windows.rs", lambda s: replace_regex(s,
            r'^fn get_valid_subkey\(\) -> String \{\n.*?^\}',
            '''fn get_valid_subkey() -> String {
    get_subkey(&crate::get_app_name(), false)
}'''))
        # Resolve the protected Program Files directory from HKLM, not a user environment variable.
        patch(source / "src/platform/windows.rs", lambda s: replace_regex(s,
            r'^fn get_default_install_path\(\) -> String \{\n.*?^\}',
            '''fn get_default_install_path() -> String {
    let pf = get_reg_of(r"HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion", "ProgramFilesDir");
    let pf = if std::path::Path::new(&pf).is_absolute() { pf } else { r"C:\\Program Files".to_owned() };
    format!(r"{}\\{}", pf, crate::get_app_name())
}'''))
        # Restrict the native Windows installer to its normal protected install path.
        patch(source / "src/platform/windows.rs", lambda s: replace_once(s,
            '    let mut path = path.trim_end_matches(\'\\\\\').to_owned();',
            '    let mut path = String::new();'))
        # The upstream Linux service copies both native configuration files to root.
        patch(source / "src/platform/linux.rs", lambda s: replace_once(s,
            'format!("cp -f {} {}; cp -f {} {};", src1, dst, src2, dst)',
            'format!("install -d -m 700 {} && install -m 600 {} {} && install -m 600 {} {} &&", dst, src1, dst, src2, dst)'))

    patch(source / "src/flutter_ffi.rs", patch_android_native)
    if role == "host":
        patch(source / "src/flutter_ffi.rs", patch_fixed_password)
        patch(source / "src/flutter_ffi.rs", lambda s: replace_once(s,
            'pub fn main_get_common(key: String) -> String {',
            '''pub fn main_get_common(key: String) -> String {
    if key == "sindre-installed-host" {
        #[cfg(target_os = "windows")]
        return (config::is_incoming_only() && crate::platform::is_cur_exe_the_installed()).to_string();
        #[cfg(not(target_os = "windows"))]
        return false.to_string();
    }'''))
        patch(source / "src/platform/linux.rs", lambda s: replace_once(s,
            '"{cp} systemctl enable {app_name}; systemctl start {app_name};"',
            '"{cp} systemctl enable {app_name} && systemctl start {app_name};"'))

    patch(source / "src/server.rs", lambda s: replace_once(s,
        '    Connection::start(addr, stream, id, Arc::downgrade(&server), meta).await;',
        '''    if hbb_common::config::is_outgoing_only() || !stream.is_secured() {
        bail!("Incoming connections require Host role and encryption");
    }
    Connection::start(addr, stream, id, Arc::downgrade(&server), meta).await;'''))
    patch(source / "src/rendezvous_mediator.rs", patch_rendezvous_mediator)
    patch(source / "src/lan.rs", patch_lan)
    patch(source / "src/ui_interface.rs", patch_ui_interface)
    patch(source / "flutter/lib/models/peer_model.dart", patch_peer_model)
    patch(source / "flutter/lib/main.dart", patch_main)
    patch(source / "flutter/lib/desktop/pages/desktop_tab_page.dart", patch_desktop_tab)
    # Main window uses the OS title bar; keep native remote/CM tab behavior.
    patch(source / "flutter/lib/desktop/widgets/tabbar_widget.dart", lambda s: replace_once(s,
        'if (stateGlobal.showTabBar.isTrue &&',
        'if (stateGlobal.showTabBar.isTrue &&\n            !(tabType == DesktopTabType.main && isHideSingleItem()) &&'))

    patch(source / "flutter/android/app/build.gradle", lambda s: patch_gradle(s, role))
    patch_desktop_branding(source, role)
    patch_desktop_icons(source, role)
    dest = source / "flutter/lib/sindre"
    dest.mkdir()
    for path in (ROOT / "client/flutter").glob("*.dart"):
        shutil.copy2(path, dest / path.name)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("role", choices=["host", "client"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = (args.output or ROOT / "upstream" / args.role).resolve()
    if output.exists():
        raise SystemExit(f"目标已存在，请选择新目录: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as tmp:
        source = Path(tmp) / "source"
        source.mkdir()
        git(source, "init")
        git(source, "remote", "add", "origin", UPSTREAM)
        git(source, "fetch", "--depth", "1", "origin", REVISION)
        git(source, "checkout", "--detach", REVISION)
        git(source, "submodule", "update", "--init", "--recursive")
        prepare(source, args.role)
        source.rename(output)
    print(output)


if __name__ == "__main__":
    main()
