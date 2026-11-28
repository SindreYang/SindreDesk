"""生成独立 Android 双向控制候选源码；只使用固定上游提交。
构建前需提供已安装 Lite 服务端的真实公钥和 API 证书，禁止使用占位密钥。
"""
import base64
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REV = "6c578292e8ebbbec708b76986ba8c4bc7c509747"

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"上游锚点变化: {old[:80]}")
    return text.replace(old, new, 1)

def replace_fn(text, name, body):
    pattern = rf"^([ ]*pub fn {name}\(\) -> [^\n]+ \{{)\n.*?^([ ]*\}})"
    # 函数终止括号缩进必须与声明匹配。
    pattern = rf"^([ ]*)pub fn {name}\(\) -> ([^\n]+) \{{\n.*?^\1\}}"
    text, n = re.subn(pattern, lambda m: f"{m[1]}pub fn {name}() -> {m[2]} {{\n{body}\n{m[1]}}}", text, flags=re.M | re.S)
    if n != 1:
        raise RuntimeError(f"上游函数变化: {name}")
    return text

def patch(path, fn):
    path.write_text(fn(path.read_text(encoding="utf-8")), encoding="utf-8")

def run(*args):
    subprocess.run(args, check=True)

def main():
    if len(sys.argv) != 3:
        raise SystemExit("用法: python lite/prepare-android.py /path/server-public-key.txt /path/api.crt")
    key = Path(sys.argv[1]).read_text().strip()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError("无效 RustDesk 服务端公钥")
    cert = Path(sys.argv[2]).read_text().strip()
    if not cert.startswith("-----BEGIN CERTIFICATE-----") or not cert.endswith("-----END CERTIFICATE-----"):
        raise ValueError("无效 TLS PEM")
    src = ROOT / "upstream"
    if src.exists():
        raise RuntimeError("工作树已存在，请先备份并删除后重新生成")
    run("git", "clone", "--no-checkout", "https://github.com/rustdesk/rustdesk.git", str(src))
    run("git", "-C", str(src), "checkout", "--detach", REV)
    run("git", "-C", str(src), "submodule", "update", "--init", "--recursive")
    def config(text):
        for name, value in (("is_incoming_only", "false"), ("is_outgoing_only", "false"), ("is_disable_ab", "true"), ("is_disable_account", "true")):
            text = replace_fn(text, name, "    " + value)
        text, n = re.subn(r'^    pub static ref APP_NAME: RwLock<String> = [^;]+;', '    pub static ref APP_NAME: RwLock<String> = RwLock::new("SindreDeskLite".to_owned());', text, flags=re.M)
        if n != 1:
            raise RuntimeError("APP_NAME anchor")
        text = replace_fn(text, "get_rendezvous_server", '        "43.138.240.23:22116".to_owned()')
        text = replace_fn(text, "get_rendezvous_servers", '        vec![Self::get_rendezvous_server()]')
        text, n = re.subn(r'^pub const RENDEZVOUS_SERVERS: &\[&str\] = [^;]+;', 'pub const RENDEZVOUS_SERVERS: &[&str] = &["43.138.240.23:22116"];', text, flags=re.M)
        if n != 1:
            raise RuntimeError("RENDEZVOUS_SERVERS anchor")
        return text
    patch(src/"libs/hbb_common/src/config.rs", config)
    def password(text):
        text = replace_fn(text, "approve_mode", "    ApproveMode::Click")
        return replace_fn(text, "hide_cm", "    false")
    patch(src/"libs/hbb_common/src/password_security.rs", password)
    def mobile_main(text):
        text = replace_once(text, "import 'common.dart';", "import 'common.dart';\nimport 'sindre_lite/lite_home.dart';\nimport 'sindre_lite/lite_config.dart';")
        text = replace_once(text, ": HomePage(),", ": const LiteHome(),")
        start = text.index("void runMobileApp() async {")
        end = text.index("\n}", start)
        text = text[:start] + """void runMobileApp() async {
  await initEnv(kAppTypeMain);
  if (isAndroid) androidChannelInit();
  if (isAndroid) platformFFI.syncAndroidServiceAppDirConfigPath();
  await bind.mainSetOption(key: 'key', value: liteServerKey);
  await bind.mainSetOption(key: 'custom-rendezvous-server', value: '$liteServerIp:22116');
  await bind.mainSetOption(key: 'relay-server', value: '$liteServerIp:22117');
  await bind.mainSetOption(key: 'approve-mode', value: 'click');
  await bind.mainSetOption(key: 'enable-file-transfer', value: 'N');
  await bind.mainSetOption(key: 'enable-audio', value: 'N');
  await bind.mainCheckConnectStatus();
  runApp(App());""" + text[end:]
        return text
    patch(src/"flutter/lib/main.dart", mobile_main)
    dest = src/"flutter/lib/sindre_lite"
    dest.mkdir()
    shutil.copy(ROOT/"android/lite_home.dart", dest/"lite_home.dart")
    (dest/"lite_config.dart").write_text(
        "const liteServerIp = '43.138.240.23';\n"
        f"const liteServerKey = {json.dumps(key)};\n"
        f"const liteCertificate = {json.dumps(cert)};\n", encoding="utf-8")
    patch(src/"flutter/android/app/build.gradle", lambda t: replace_once(t, 'applicationId "com.carriez.flutter_hbb"', 'applicationId "com.sindre.desk.lite"\n        ndk { abiFilters "arm64-v8a" }'))
    def manifest(text):
        text = replace_once(text, 'android:label="RustDesk"', 'android:label="远程协助"')
        if 'android:allowBackup="true"' in text:
            text = replace_once(text, 'android:allowBackup="true"', 'android:allowBackup="false"')
        elif 'android:allowBackup=' not in text:
            text = replace_once(text, '<application', '<application android:allowBackup="false"')
        return text
    patch(src/"flutter/android/app/src/main/AndroidManifest.xml", manifest)
    print("Android 候选源码已生成；必须完成 FFI、Rust、Flutter 构建和真机安全验收。")

if __name__ == "__main__":
    main()
