"""从固定上游源码生成独立角色工作树；不直接修改上游仓库。"""
import argparse
import re
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


def patch_client(text):
    text = replace_once(text,
        '        if config::is_incoming_only() {\n            bail!("Incoming only mode");\n        }',
        '''        if config::is_incoming_only() {
            bail!("Incoming only mode");
        }
        if hbb_common::is_ip_str(peer) || hbb_common::is_domain_port_str(peer) {
            bail!("Secure offline LAN mode is not available");
        }
        if Config::get_option("custom-rendezvous-server").trim().is_empty()
            || key.is_empty() || get_rs_pk(key).is_none() {
            bail!("Configure the private server and valid public key");
        }''')
    text = replace_once(text,
        '        let other_server = interface.get_lch().read().unwrap().other_server.clone();',
        '''        let other_server = interface.get_lch().read().unwrap().other_server.clone();
        if other_server.is_some() {
            bail!("Alternate rendezvous servers are disabled");
        }''')
    # 上游握手可能退回未加密；禁止把这样的连接交给登录流程。
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
    return text


def patch_desktop_tab(text):
    text = "import '../../sindre/sindre_home.dart';\n" + text
    text = replace_once(text, 'page: DesktopHomePage(', 'page: const SindreHome(')
    text = replace_once(text, 'offstage: bind.isIncomingOnly() || bind.isDisableSettings(),', 'offstage: true,')
    return text


def patch_gradle(text, role):
    text = replace_once(text, 'applicationId "com.carriez.flutter_hbb"',
                        f'applicationId "com.sindre.desk.{role}"\n        ndk {{ abiFilters "arm64-v8a" }}')
    return text


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
    patch(source / "src/rendezvous_mediator.rs", lambda s: replace_once(s,
        '''        let server_cloned = server.clone();
        tokio::spawn(async move {
            direct_server(server_cloned).await;
        });''',
        '''        // 不启动上游未加密直接 IP 监听。'''))
    patch(source / "flutter/lib/main.dart", patch_main)
    patch(source / "flutter/lib/desktop/pages/desktop_tab_page.dart", patch_desktop_tab)
    patch(source / "flutter/android/app/build.gradle", lambda s: patch_gradle(s, role))
    patch_desktop_branding(source, role)
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
